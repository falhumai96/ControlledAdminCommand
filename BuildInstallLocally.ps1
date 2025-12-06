<#
.SYNOPSIS
    Build & install ControlledAdminCommand locally.

.DESCRIPTION
    - Publishes ServiceSrv.csproj to ProgramFiles\ControlledAdminCommand\Daemon via a temporary directory
    - Copies Scripts and Scripts.json
    - Installs & configures the Windows service "ControlledAdminCommand"
    - Installs client module under C:\Program Files\WindowsPowerShell\Modules\Invoke-ControlledAdminCommand
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------------
# Paths
# -------------------------------

$Root           = Split-Path -Parent $PSCommandPath
$DaemonSrc      = Join-Path $Root "Daemon"
$ClientSrc      = Join-Path $Root "Client"
$ScriptsSrc     = Join-Path $DaemonSrc "Scripts"
$ScriptsJsonSrc = Join-Path $DaemonSrc "Scripts.json"

$InstallRoot    = "$Env:ProgramFiles\ControlledAdminCommand"
$DaemonDst      = Join-Path $InstallRoot "Daemon"

$ServiceName    = "ControlledAdminCommand"
$ServiceExe     = Join-Path $DaemonDst "ServiceSrv.exe"   # Final executable location

# System-wide module folder
$PSModulesRoot = Join-Path $Env:ProgramFiles "WindowsPowerShell\Modules"
$ClientDst = Join-Path $PSModulesRoot "Invoke-ControlledAdminCommand"

# -------------------------------
# Ensure directories
# -------------------------------

Write-Host "Creating installation directories..."
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DaemonDst  | Out-Null
New-Item -ItemType Directory -Force -Path $PSModulesRoot | Out-Null

# -------------------------------
# Create temporary publish directory
# -------------------------------

do {
    $tmpDir = Join-Path $Env:TEMP ([guid]::NewGuid().ToString())
} while (Test-Path $tmpDir)

New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

try {

    # -------------------------------
    # Build and publish daemon
    # -------------------------------

    Write-Host "Publishing daemon ServiceSrv.csproj (Release) to temporary directory..."

    $ProjectFile = Join-Path $DaemonSrc "ServiceSrv.csproj"
    $ArtifactsPath = Join-Path $tmpDir "artifacts"

    dotnet publish `
        $ProjectFile `
        -c Release `
        --nologo `
        --artifacts-path $ArtifactsPath

    # Determine the published exe location
    $PublishedExeDir = Join-Path $ArtifactsPath "publish\ServiceSrv\release"

    if (-not (Test-Path $PublishedExeDir)) {
        throw "Published exe directory not found: $PublishedExeDir"
    }

    # Copy all published files to the daemon destination
    Write-Host "Copying published files to: $DaemonDst"
    Copy-Item -Recurse -Force "$PublishedExeDir\*" $DaemonDst

    # -------------------------------
    # Copy Scripts + Scripts.json
    # -------------------------------

    Write-Host "Copying scripts..."
    Copy-Item -Recurse -Force $ScriptsSrc $DaemonDst
    Copy-Item -Force $ScriptsJsonSrc $DaemonDst

    # -------------------------------
    # Install Windows Service
    # -------------------------------

    Write-Host "Installing Windows service '$ServiceName'..."

    # Remove existing service if exists
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "Service exists — stopping & removing..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Remove-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Start-Sleep 1
    }

    # Create service
    New-Service -Name $ServiceName `
                -BinaryPathName "`"$ServiceExe`"" `
                -DisplayName "Controlled Admin Command Daemon" `
                -StartupType Automatic

    Write-Host "Starting service..."
    Start-Service $ServiceName

    Write-Host "Service installed & started."

    # -------------------------------
    # Install client module
    # -------------------------------

    Write-Host "Installing client module..."
    New-Item -ItemType Directory -Force -Path $ClientDst | Out-Null
    Copy-Item -Recurse -Force $ClientSrc\* $ClientDst

    Write-Host "`n✔ Installation complete."
    Write-Host "Restart PowerShell to load the module: Import-Module Invoke-ControlledAdminCommand"

}
finally {
    Write-Host "Cleaning up temporary publish directory..."
    Remove-Item -Recurse -Force $tmpDir
}
