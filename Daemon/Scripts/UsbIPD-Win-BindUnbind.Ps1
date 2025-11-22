param(
    [Parameter(Mandatory = $false)]
    [string[]] $CommandArgs,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDInPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDOutputPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDErrPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandExitStatusPath
)

# Helper functions
function Write-DirIfNotExist {
    param([string] $Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-ToFile {
    param(
        [string] $Path,
        [string] $Prefix,
        [string[]] $Content
    )
    if (-not $Path) { return }
    Write-DirIfNotExist $Path
    if ($Prefix) {
        if ($Content) {
            $Content | ForEach-Object { "$Prefix $_" } | Out-File -FilePath $Path -Encoding UTF8 -Force
        }
        else {
            "$Prefix" | Out-File -FilePath $Path -Encoding UTF8 -Force
        }
    }
    else {
        if ($Content) {
            $Content | ForEach-Object { "$_" } | Out-File -FilePath $Path -Encoding UTF8 -Force
        }
        else {
            "" | Out-File -FilePath $Path -Encoding UTF8 -Force
        }
    }
}

# Validate minimal args
if ($CommandArgs.Count -lt 3) {
    Write-ToFile -Path $CommandSTDErrPath -Content "Insufficient commands."
    if ($CommandExitStatusPath) { Set-Content -Path $CommandExitStatusPath -Value 1 -Force }
    Exit 1
}

# Parse structured arguments
$action = $CommandArgs[0].ToLower()          # bind or unbind
$type = $CommandArgs[1].ToLower()          # bus or hardware
$id = $CommandArgs[2]                    # bus id or VID:PID
$force = ($CommandArgs.Count -gt 3 -and $CommandArgs[3].ToLower() -eq "force")

# Build usbipd argument list
$usbArgs = @($action)
switch ($type) {
    "bus" { $usbArgs += @("-b", $id) }
    "hardware" { $usbArgs += @("-i", $id) }
    default {
        Write-ToFile -Path $CommandSTDErrPath -Content "Unknown type '$type'."
        if ($CommandExitStatusPath) { Set-Content -Path $CommandExitStatusPath -Value 1 -Force }
        Exit 1
    }
}
if ($force -and $action -eq "bind") {
    $usbArgs += "-f"
}

# Run usbipd.exe
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "usbipd.exe"
    $psi.Arguments = $usbArgs -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    # Capture or suppress stdout
    if ($CommandSTDOutputPath) {
        Write-DirIfNotExist $CommandSTDOutputPath
        $proc.StandardOutput.ReadToEnd() | Out-File -FilePath $CommandSTDOutputPath -Encoding UTF8 -Force
    }
    else {
        $proc.StandardOutput.ReadToEnd() | Out-Null
    }

    # Capture or suppress stderr
    if ($CommandSTDErrPath) {
        Write-DirIfNotExist $CommandSTDErrPath
        $proc.StandardError.ReadToEnd() | Out-File -FilePath $CommandSTDErrPath -Encoding UTF8 -Force
    }
    else {
        $proc.StandardError.ReadToEnd() | Out-Null
    }

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
}
catch {
    Write-ToFile -Path $CommandSTDErrPath -Content $_.Exception.Message
    $exitCode = 1
}

# Write exit code
if ($CommandExitStatusPath) {
    Write-DirIfNotExist $CommandExitStatusPath
    Set-Content -Path $CommandExitStatusPath -Value $exitCode -Force
}
