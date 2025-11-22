# ControlledAdminCommandDaemon.ps1

[Console]::TreatControlCAsInput = $true

$pipeName = "ControlledAdminCommand"
$jobName = "ControlledAdminCommandDaemonScriptJob"

$daemonDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$scriptsJsonPath = Join-Path $daemonDir "Scripts.JSON"
$scriptsFolder = Join-Path $daemonDir "Scripts"

# Load scripts mapping
if (-not (Test-Path $scriptsJsonPath)) {
    Write-Error "Scripts.JSON not found at $scriptsJsonPath"
    exit 1
}

$scriptsMap = Get-Content $scriptsJsonPath -Raw | ConvertFrom-Json

# ---- Pipe ACL: restrict to Authenticated Users (safer than Everyone) ----
$security = New-Object System.IO.Pipes.PipeSecurity
$authUsers = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
    $null
)
$accessRule = New-Object System.IO.Pipes.PipeAccessRule(
    $authUsers,
    [System.IO.Pipes.PipeAccessRights]::ReadWrite,
    [System.Security.AccessControl.AccessControlType]::Allow
)
$security.AddAccessRule($accessRule)

Write-Host "ControlledAdminCommandDaemon running on pipe '$pipeName'..."

# Mutex to prevent races when launching jobs
$jobMutex = New-Object System.Threading.Mutex($false, "Global\ControlledAdminCommandDaemon")

$pipe = $null
$reader = $null

try {
    while ($true) {

        # Create pipe with ACL, handle inherit disabled
        $pipe = [System.IO.Pipes.NamedPipeServerStreamAcl]::Create(
            $pipeName,
            [System.IO.Pipes.PipeDirection]::In,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous,
            1024,
            1024,
            $security,
            [System.IO.HandleInheritability]::None
        )

        Write-Host "Waiting for client... (CTRL-C to exit)"

        # Async wait
        $waitTask = $pipe.WaitForConnectionAsync()

        # Loop until client connects OR CTRL-C
        while (-not $waitTask.IsCompleted) {
            Start-Sleep -Milliseconds 100

            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('AllowCtrlC,IncludeKeyUp,NoEcho')
                if ([int]$key.Character -eq 3) {
                    Write-Host "`nCTRL-C detected, stopping daemon..."
                    exit 0
                }
            }
        }

        # Connect (handle failure)
        try {
            $waitTask.GetAwaiter().GetResult()
        }
        catch {
            if ($pipe) {
                $pipe.Dispose()
                $pipe = $null
            }
            continue
        }

        # UTF-8 reader, prevents JSON corruption
        $reader = New-Object System.IO.StreamReader(
            $pipe,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Read full JSON payload, not line-based
        $json = $reader.ReadToEnd()

        if ($json) {
            Write-Host "`nReceived JSON:"
            Write-Host $json

            try {
                $obj = $json | ConvertFrom-Json

                $cmdName = $obj.Command
                $cmdArgs = $obj.CommandArgs
                $stdIn = $obj.CommandSTDInPath
                $stdOut = $obj.CommandSTDOutputPath
                $stdErr = $obj.CommandSTDErrPath
                $exit = $obj.CommandExitStatusPath

                # Lookup using safe property access
                if ($scriptsMap.PSObject.Properties.Name -contains $cmdName) {

                    $scriptName = $scriptsMap.PSObject.Properties[$cmdName].Value
                    $scriptPath = Join-Path $scriptsFolder $scriptName

                    if (-not (Test-Path $scriptPath)) {
                        Write-Host "Script not found: $scriptPath"
                    }
                    else {
                        # Build argument hash
                        $argsList = @{}

                        if ($cmdArgs) { $argsList["CommandArgs"] = $cmdArgs }
                        if ($stdIn) { $argsList["CommandSTDInPath"] = $stdIn }
                        if ($stdOut) { $argsList["CommandSTDOutputPath"] = $stdOut }
                        if ($stdErr) { $argsList["CommandSTDErrPath"] = $stdErr }
                        if ($exit) { $argsList["CommandExitStatusPath"] = $exit }

                        # Protect against two clients racing
                        $jobMutex.WaitOne() | Out-Null
                        try {
                            Remove-Job -Name $jobName -ErrorAction SilentlyContinue

                            $scriptBlock = {
                                param($scriptPath, $argsList)
                                try {
                                    & $scriptPath @argsList
                                }
                                catch {
                                    Write-Error "Script threw exception: $_"
                                }
                            }

                            Start-ThreadJob -Name $jobName -ScriptBlock $scriptBlock -ArgumentList $scriptPath, $argsList | Out-Null
                            Write-Host "Started job '$jobName' for script '$scriptName'"
                        }
                        finally {
                            $jobMutex.ReleaseMutex()
                        }
                    }
                }
                else {
                    Write-Host "Unknown command '$cmdName'"
                }
            }
            catch {
                Write-Host "Failed to parse JSON or process command: $_"
            }
        }

        # Cleanup for next loop
        if ($reader) {
            $reader.Dispose()
            $reader = $null
        }
        if ($pipe) {
            $pipe.Dispose()
            $pipe = $null
        }
    }
}
finally {
    if ($reader) { $reader.Dispose() }
    if ($pipe) { $pipe.Dispose() }
    Write-Host "Daemon stopped."
}
