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
rem No arguments: open the numbered menu. Nothing is started by itself, and
rem the menu text comes from the PowerShell side (Chinese renders correctly
rem there; .cmd text stays ASCII). In a shell without a console -Menu prints
rem the usage text instead of waiting for input, so it can never hang.
set "INTERACTIVE="
echo %CMDCMDLINE% | find /i "%~nx0" >nul && set "INTERACTIVE=1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memory-guard.ps1" -Menu
if defined INTERACTIVE (echo. & echo Press any key to close this window... & pause >nul)
endlocal
exit /b 0
