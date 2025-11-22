
# Controlled Admin Command Executor

This project provides a **controlled way to execute Windows commands with elevated (administrator) privileges** without requiring the user to run everything as admin.  
It is useful in scenarios where a tool *claims* it needs admin rights for certain operations, but the underlying action can actually be performed safely by a dedicated privileged service running in the background.

A real-world example is **usbipd-win**:  
Binding and unbinding USB devices doesn't always need interactive elevation.  
Instead, a daemon running as admin can perform the privileged operation on behalf of the user — safely and predictably.

----------

## 🔧 How It Works

The system is split into two components:

### **Client/**
- `ControlledAdminCommand.ps1`  
  Executed by the non-admin user.  
  Sends a command request to the daemon via named pipes.

### **Daemon/**
- `ControlledAdminCommandDaemon.ps1`  
  Runs with administrator privileges.  
  Listens for client commands and executes approved scripts.

- `Scripts/`  
  Contains allowed scripts that the daemon can execute.

- `Scripts.json`  
  A whitelist mapping command names → allowed script paths.  
  This prevents arbitrary command execution and ensures strict control.

----------

## 🛠️ Running the Daemon as a Windows Service

The daemon can be installed and run as a Windows service using tools like **WinSW**:  
https://github.com/winsw/winsw

This allows the elevated daemon to run continuously in the background, with automatic startup, logging, and recovery options — without requiring elevation prompts for end users.
