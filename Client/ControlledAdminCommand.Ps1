# ControlledAdminCommand.ps1

param(
    [Parameter(Mandatory = $true)]
    [string] $Command,

    [Parameter(Mandatory = $false)]
    [string[]] $CommandArgs,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDInPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDOutputPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandSTDErrPath,

    [Parameter(Mandatory = $false)]
    [string] $CommandExitStatusPath,

    [Parameter(Mandatory = $false)]
    [int] $TimeoutMs = 3000   # default 3 seconds
)

$pipeName = "ControlledAdminCommand"

function Get-AbsPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $combined = [System.IO.Path]::Combine((Get-Location).Path, $Path)
        return [System.IO.Path]::GetFullPath($combined)
    }

    return [System.IO.Path]::GetFullPath($Path)
}

# Normalize paths (no existence checks)
if ($CommandSTDInPath) { $CommandSTDInPath = Get-AbsPath $CommandSTDInPath }
if ($CommandSTDOutputPath) { $CommandSTDOutputPath = Get-AbsPath $CommandSTDOutputPath }
if ($CommandSTDErrPath) { $CommandSTDErrPath = Get-AbsPath $CommandSTDErrPath }
if ($CommandExitStatusPath) { $CommandExitStatusPath = Get-AbsPath $CommandExitStatusPath }

# Build JSON
$payload = [pscustomobject]@{
    Command               = $Command
    CommandArgs           = $CommandArgs
    CommandSTDInPath      = $CommandSTDInPath
    CommandSTDOutputPath  = $CommandSTDOutputPath
    CommandSTDErrPath     = $CommandSTDErrPath
    CommandExitStatusPath = $CommandExitStatusPath
} | ConvertTo-Json -Compress -Depth 5

$pipe = $null
$writer = $null

try {
    # Create pipe client
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
        ".", 
        $pipeName,
        [System.IO.Pipes.PipeDirection]::Out
    )

    # Connect with timeout
    try {
        $pipe.Connect($TimeoutMs)
    }
    catch {
        throw "Failed to connect to pipe '$pipeName' within $TimeoutMs ms. $_"
    }

    # Write UTF-8 (daemon reads UTF-8)
    $writer = New-Object System.IO.StreamWriter(
        $pipe,
        [System.Text.UTF8Encoding]::new($false)
    )
    $writer.AutoFlush = $true

    # Add newline terminator so daemon's ReadToEnd() is clean
    $writer.WriteLine($payload)
}
catch {
    Write-Error $_
    exit 1
}
finally {
    if ($writer) { $writer.Dispose() }
    if ($pipe) { $pipe.Dispose() }
}
