@echo off
rem ---------------------------------------------------------------------------
rem  memfuse launcher
rem
rem  Why this file exists: a .ps1 downloaded from the internet carries the
rem  Mark-of-the-Web, and a default Windows box - Restricted or RemoteSigned -
rem  refuses to run it: "not digitally signed" or "running scripts is disabled".
rem  This launcher always passes -ExecutionPolicy Bypass, so the tool works
rem  without changing any machine-wide policy.
rem
rem  No arguments - prints a hint instead of starting anything.
rem ---------------------------------------------------------------------------
setlocal

if "%~1"=="" goto usage

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" %*
endlocal
exit /b %ERRORLEVEL%

:usage
rem No arguments: nothing is started. The usage screen is printed by the
rem PowerShell side (Chinese renders correctly there; .cmd text stays ASCII).
set "INTERACTIVE="
echo %CMDCMDLINE% | find /i "%~nx0" >nul && set "INTERACTIVE=1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" -Help
if defined INTERACTIVE (echo. & echo Press any key to close this window... & pause >nul)
endlocal
exit /b 0
