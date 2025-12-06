<#
.SYNOPSIS
    Uninstall ControlledAdminCommand locally.

.DESCRIPTION
    - Stops and removes the Windows service "ControlledAdminCommand"
    - Deletes daemon installation directory
    - Deletes client module under C:\Program Files\WindowsPowerShell\Modules\Invoke-ControlledAdminCommand
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------------
# Paths
# -------------------------------

$InstallRoot    = "$Env:ProgramFiles\ControlledAdminCommand"
$DaemonDst      = Join-Path $InstallRoot "Daemon"
$ServiceName    = "ControlledAdminCommand"

$PSModulesRoot  = Join-Path $Env:ProgramFiles "WindowsPowerShell\Modules"
$ClientDst      = Join-Path $PSModulesRoot "Invoke-ControlledAdminCommand"

# -------------------------------
# Stop and remove service
# -------------------------------

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "Stopping service '$ServiceName'..."
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Removing service '$ServiceName'..."
    Remove-Service -Name $ServiceName -ErrorAction SilentlyContinue
} else {
    Write-Host "Service '$ServiceName' not found, skipping."
}

# -------------------------------
# Remove daemon directory
# -------------------------------

if (Test-Path $DaemonDst) {
    Write-Host "Deleting daemon folder: $DaemonDst"
    Remove-Item -Recurse -Force $DaemonDst
} else {
    Write-Host "Daemon folder not found, skipping."
}

if (Test-Path $InstallRoot) {
    Write-Host "Deleting install root folder: $InstallRoot"
    Remove-Item -Recurse -Force $InstallRoot
} else {
    Write-Host "Install root folder not found, skipping."
}

# -------------------------------
# Remove client module
# -------------------------------

if (Test-Path $ClientDst) {
    Write-Host "Deleting client module folder: $ClientDst"
    Remove-Item -Recurse -Force $ClientDst
} else {
    Write-Host "Client module folder not found, skipping."
}

Write-Host "`n✔ ControlledAdminCommand uninstalled successfully."
