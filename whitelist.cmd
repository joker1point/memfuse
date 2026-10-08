@echo off
rem ---------------------------------------------------------------------------
rem  memfuse whitelist helper
rem
rem  Double-click me: it lists the programs that own a window (numbered), and
rem  writes the ones you pick into protect-list.txt. Takes effect immediately,
rem  no restart needed.
rem
rem  Text stays ASCII here on purpose - Chinese output comes from the
rem  PowerShell side, which renders it correctly in a console.
rem ---------------------------------------------------------------------------
setlocal

if not "%~1"=="" goto forward

rem Launched by double-click? Then keep the window open at the end.
set "INTERACTIVE="
echo %CMDCMDLINE% | find /i "%~nx0" >nul && set "INTERACTIVE=1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" -Pick
if defined INTERACTIVE (echo. & echo Press any key to close this window... & pause >nul)
endlocal
exit /b 0

:forward
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" %*
endlocal
exit /b %ERRORLEVEL%
