@echo off
rem memfuse tray launcher.
rem
rem Double-click: the tool moves into the notification area and this window
rem goes away. Right-click the tray icon for the menu, the protected list, the
rem protect-list.txt file, today's log and the folder.
rem
rem If the scheduled task (MemoryGuard) is installed, that guard keeps doing the
rem actual killing - the tray is just an always-there entry point. Nothing is
rem started in the foreground, so there is no window to leave open.
rem
rem ASCII-only on purpose: .cmd files are read as ANSI, so Chinese here would
rem come out garbled. All Chinese text comes from the PowerShell side.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
start "" "%PS%" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" -Tray
endlocal
exit /b 0
