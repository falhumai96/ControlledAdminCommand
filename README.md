# ControlledAdminCommand

**Project Overview**

ControlledAdminCommand provides a small IPC-based daemon (Windows) and a PowerShell client module to run a tightly-scoped set of administrator-level PowerShell scripts from an unprivileged context. It exposes a named pipe (`ControlledAdminCommand`) where a client can request a named command to be executed by the daemon. The daemon maps command names to script files using `Scripts.json` and executes them inside a PowerShell runspace with `ExecutionPolicy` set to `Bypass` (process scope).

This repository contains:

- `Client/Invoke-ControlledAdminCommand.psm1` — PowerShell client function to call the daemon using a framed named-pipe protocol.
- `Daemon/` — C# implementation of the daemon, including a Windows Service wrapper (`ServerSrv.cs`) and a standalone console host (`ServerStandAlone.cs`). Common server logic is in `ServerCommon.cs`.
- `Daemon/Scripts.json` and `Daemon/Scripts/` — Mapping and actual PowerShell scripts the daemon can execute (example: `UsbIpDCommand.ps1`).
- `LICENSE` — MIT license.

**Intended Use**

Use this project when an application or user running without elevated privileges needs to trigger specific, controlled administrative actions implemented as PowerShell scripts. The design keeps a strict mapping of allowed command names to specific script files to reduce the attack surface.

**How It Works (protocol)**

- The client connects to the named pipe `ControlledAdminCommand` on the local machine.
- Frames are sent as: ASCII decimal length (bytes) followed by `!` then the JSON payload. Example header: `123!` then 123 bytes of UTF-8 JSON.
- Request JSON schema:
	- `Command` : string — the name of the command as defined in `Scripts.json`.
	- `Args` : string[] — optional command-specific arguments.
- Response JSON: the executed PowerShell script must output JSON and the daemon will add:
	- `CommandError` : boolean
	- `CommandErrorMessage` : string
- The script JSON output must be of the format: `{ StdOut = "..."; StdErr = "..."; ExitCode = <uint> }`

If there is a server-level or framing error, the daemon will return a JSON object with `CommandError=true` and an appropriate message.

**Client: `Invoke-ControlledAdminCommand`**

Location: `Client/Invoke-ControlledAdminCommand.psm1`

Usage:

Import the module (example):

```
Import-Module .\Client\Invoke-ControlledAdminCommand.psm1
```

Invoke a command:

```
$resp = Invoke-ControlledAdminCommand -Command UsbIPDDeviceControl -CommandArgs @('bind','bus','1','force') -Timeout 10000
$resp
```

Parameters:
- `-Command` (string, mandatory): Command name (must match a key in `Daemon/Scripts.json`).
- `-CommandArgs` (string[], optional): Arguments passed to the script (the daemon passes these as `CommandArgs` parameter to the script).
- `-Timeout`, `-ReadTimeout`, `-WriteTimeout` (int, ms): Control named pipe connect/read/write timeouts. Defaults in the client file are `10000` ms (10s).

Return value: The cmdlet returns the deserialized JSON response from the daemon, or writes an error on failure.

Implementation notes / tunables:
- The client implements framed read/write with async tasks and explicit timeout handling. You can adjust `-Timeout`, `-ReadTimeout`, and `-WriteTimeout` per invocation.

**Daemon: components and configuration**

Location: `Daemon/` — the important files are:

- `ServerCommon.cs` — core logic: named pipe listener, framing, script loading, execution.
- `ServerStandAlone.cs` — small console host for interactive runs.
- `ServerSrv.cs` — Windows Service wrapper to run as a service.
- `Scripts.json` — mapping from command name -> script filename under `Scripts/`.

Environment variables (tunables used by `ServerCommon.Start()`):
- `CONTROLLED_ADMIN_COMMAND_DAEMON_DIR` — base directory where `Scripts.json` and `Scripts/` are located. Defaults to the process base directory.
- `CONTROLLED_ADMIN_COMMAND_READ_TIMEOUT` — read timeout in milliseconds. Default: `10000`.
- `CONTROLLED_ADMIN_COMMAND_WRITE_TIMEOUT` — write timeout in milliseconds. Default: `10000`.
- `CONTROLLED_ADMIN_COMMAND_MAX_CLIENTS` — maximum concurrent pipe client connections the daemon accepts. Default: `10` (minimum enforced is 1).

Security & permissions:
- The server currently creates the named pipe with a `WorldSid` full-control access rule (see `ServerCommon.cs`). That means any local user can connect to the pipe and request commands. This is by design. Scripts inside `Daemon\Scripts`
  will have a `RegisteredUser` argument. Use it when writing a restricted Admin script to restrict the command to a certain, e.g., group(s).

Script execution model:
- When a request arrives, the server identifies the script filename via `Scripts.json`, combines it with `Scripts/` and executes it inside a `PowerShell` runspace.
- Before running, it invokes `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` to avoid execution policy issues.
- The script is executed with two parameters injected by the daemon:
	- `RequestingUser` (string) — the Windows identity reported by the server.
	- `CommandArgs` (string[]) — the arguments passed from the client.
- The script must output a PowerShell object that can be converted to JSON (for example a PSCustomObject containing `StdOut`, `StdErr`, `ExitCode`, etc.). The daemon converts the first output item to JSON and injects `CommandError=false` when successful.
- The script must never hang. No timeouts have been implemented by the daemon scripts.

Example `Scripts.json` (existing):

```json
{
		"UsbIPDDeviceControl": "UsbIpDCommand.ps1"
}
```

Example script contract (see `Daemon/Scripts/UsbIpDCommand.ps1`):
- Accepts `RequestingUser` and `CommandArgs` parameters.
- Validates inputs and runs the underlying administrative command (`usbipd.exe` in the example).
- Returns a PSCustomObject such as `{ StdOut = "..."; StdErr = "..."; ExitCode = 0 }` which the daemon forwards as JSON.

**Building & Publishing the Daemon**

This project is a .NET project. Typical build/publish commands (PowerShell / `pwsh`):

```
cd Daemon
dotnet build -c Release
dotnet publish -c Release -r win-x64 --self-contained false -o ../ControlledAdminCommandDaemoneOutput/publish/ServiceStandAlone/release
```

Running the server standalone:

```
cd <publish-folder>
.\ServiceStandAlone.exe
```

When running as a service, use `sc.exe create` or a service installer to register the published service executable, or rely on `ServerSrv` build target to install via your preferred tool.

**Examples**

1) Call `UsbIPDDeviceControl` from an unprivileged PowerShell prompt (client):

```
Import-Module C:\path\to\ControlledAdminCommand\Client\Invoke-ControlledAdminCommand.psm1
$r = Invoke-ControlledAdminCommand -Command UsbIPDDeviceControl -CommandArgs @('bind','bus','1','force')
if ($r.CommandError) { Write-Error $r.CommandErrorMessage } else { $r }
```

2) Run server as console (helpful for debugging):

```
cd C:\path\to\publish\ServiceStandAlone\release
.\ServiceStandAlone.exe
```

Press `CTRL-C` in that window to stop the server cleanly.

**Troubleshooting**

- If the client times out connecting to the pipe, check the server is running and that `ControlledAdminCommand` pipe exists.
- If a command returns `CommandError` with message `Command 'X' not found`, verify `Scripts.json` maps the requested command and the script file exists in `Daemon/Scripts/`.
- If scripts fail with execution policy errors, the daemon sets `ExecutionPolicy` for the process to `Bypass`, but you may still need to unblock scripts or verify script file encoding.
- To collect diagnostic logs: run `ServiceStandAlone.exe` in a console and observe stdout/stderr.

**Extending the project**

- Add new commands: place a script in `Daemon/Scripts/` and add a `"CommandName":"ScriptFile.ps1"` entry to `Daemon/Scripts.json`.
- If scripts require additional parameters, accept them via `CommandArgs` and document the ordering.
- To restrict which users may call commands, make use of the `RequestingUser` argument of the script.

**Contribution & License**

- Contributions welcome — open an issue or PR describing the change.
- This project is released under the MIT License. See `LICENSE`.

**Files of interest**

- `Client/Invoke-ControlledAdminCommand.psm1` — client function and timeouts.
- `Daemon/ServerCommon.cs` — server logic, env vars, and pipe security.
- `Daemon/Scripts.json` — command -> script map.
- `Daemon/Scripts/UsbIpDCommand.ps1` — example script calling `usbipd.exe`.
