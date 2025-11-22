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

# Helpers
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
        [string[]] $Content
    )
    if (-not $Path) { return }
    Write-DirIfNotExist $Path
    if ($Content) {
        $Content | Out-File -FilePath $Path -Encoding UTF8 -Force
    } else {
        "" | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
}

function Run-Step {
    param(
        [string] $Command,
        [string[]] $Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    $psi.Arguments = $Arguments -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.Start() | Out-Null

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()

    $proc.WaitForExit()
    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
    }
}

# 1) Stop service
$step1 = Run-Step -Command "net.exe" -Arguments @("stop", "wuauserv")

# stdout
if ($CommandSTDOutputPath) {
    Write-ToFile $CommandSTDOutputPath $step1.Stdout
} else {
    $step1.Stdout | Out-Null
}

# stderr
if ($CommandSTDErrPath) {
    Write-ToFile $CommandSTDErrPath $step1.Stderr
} else {
    $step1.Stderr | Out-Null
}

if ($step1.ExitCode -ne 0) {
    if ($CommandExitStatusPath) { Set-Content $CommandExitStatusPath -Value $step1.ExitCode -Force }
    exit $step1.ExitCode
}

# 2) Remove directory
try {
    Remove-Item -Path "C:\Windows\SoftwareDistribution" -Recurse -Force -ErrorAction Stop
}
catch {
    if ($CommandSTDErrPath) {
        Write-ToFile $CommandSTDErrPath $_.Exception.Message
    } else {
        $_.Exception.Message | Out-Null
    }

    if ($CommandExitStatusPath) { Set-Content $CommandExitStatusPath -Value 1 -Force }
    exit 1
}

# 3) Start service
$step3 = Run-Step -Command "net.exe" -Arguments @("start", "wuauserv")

# stdout
if ($CommandSTDOutputPath) {
    Write-ToFile $CommandSTDOutputPath $step3.Stdout
} else {
    $step3.Stdout | Out-Null
}

# stderr
if ($CommandSTDErrPath) {
    Write-ToFile $CommandSTDErrPath $step3.Stderr
} else {
    $step3.Stderr | Out-Null
}

$final = $step3.ExitCode

if ($CommandExitStatusPath) {
    Set-Content -Path $CommandExitStatusPath -Value $final -Force
}

exit $final
