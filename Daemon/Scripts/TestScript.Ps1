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

    if ($Content) {
        $Content |
        ForEach-Object { "$Prefix $_" } |
        Out-File -FilePath $Path -Encoding UTF8 -Force
    }
    else {
        "$Prefix" | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
}

# Add username to the beginning of the content
$user = $env:USERNAME
$stdoutContent = @("User: $user") + $CommandArgs
$stderrContent = @("User: $user") + $CommandArgs

# Write STDOUT
Write-ToFile -Path $CommandSTDOutputPath -Prefix "STDOUT:" -Content $stdoutContent

# Write STDERR
Write-ToFile -Path $CommandSTDErrPath -Prefix "STDERR:" -Content $stderrContent

# Write exit status
if ($CommandExitStatusPath) {
    Write-DirIfNotExist $CommandExitStatusPath
    $exitCode = 999
    Set-Content -Path $CommandExitStatusPath -Value $exitCode -Force
}
