param(
    [string]$RequestingUser,
    [string[]]$CommandArgs
)

# --- Validate minimal args ---
if (-not $CommandArgs -or $CommandArgs.Count -lt 3) {
    return [pscustomobject]@{
        StdOut   = ""
        StdErr   = "Insufficient commands. Expected: <bind|unbind> <bus|hardware> <id> [force]"
        ExitCode = 1
    }
}

# --- Parse structured arguments ---
$action = $CommandArgs[0].ToLower()      # bind / unbind
$type = $CommandArgs[1].ToLower()      # bus / hardware
$id = $CommandArgs[2]                # bus id or VID:PID

# Detect "force" argument
$forceSupplied = ($CommandArgs.Count -gt 3 -and $CommandArgs[3].ToLower() -eq "force")

# Validate force only for 'bind'
if ($forceSupplied -and $action -ne "bind") {
    return [pscustomobject]@{
        StdOut   = ""
        StdErr   = "'force' is only valid with the 'bind' action."
        ExitCode = 1
    }
}

# Build usbipd argument list
$usbArgs = @($action)

switch ($type) {
    "bus" { $usbArgs += @("-b", $id) }
    "hardware" { $usbArgs += @("-i", $id) }
    default {
        return [pscustomobject]@{
            StdOut   = ""
            StdErr   = "Unknown type '$type'. Expected 'bus' or 'hardware'."
            ExitCode = 1
        }
    }
}

# Append force if allowed
if ($forceSupplied) {
    $usbArgs += "-f"
}

# --- Execute usbipd.exe ---
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

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    $exitCode = $proc.ExitCode
}
catch {
    return [pscustomobject]@{
        StdOut   = ""
        StdErr   = $_.Exception.Message
        ExitCode = 1
    }
}

# --- Return unified result object ---
return [pscustomobject]@{
    StdOut   = $stdout
    StdErr   = $stderr
    ExitCode = $exitCode
}
