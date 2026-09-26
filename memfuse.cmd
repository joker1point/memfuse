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
echo memfuse - last line of defense before the machine freezes
echo.
echo Nothing was started: no arguments were given.
echo.
echo First steps - a dry run kills nothing:
echo    memfuse.cmd -Once -DryRun          list the verdict right now
echo    memfuse.cmd -ListWindowed          who may hold unsaved work
echo    memfuse.cmd -AddProtect node,code  whitelist a process
echo    memfuse.cmd -ListProtected         show the effective whitelist
echo    memfuse.cmd -InstallTask           register the self-healing task
echo    memfuse.cmd -UninstallTask         remove it again
echo.
echo Full parameter list: see README.md or the comment header of memory-guard.ps1
endlocal
exit /b 0
