@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem Node may not be on PATH on this machine: fall back to DSH's bundled Node runtime (>=22.13).
where node >nul 2>nul || set "PATH=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin;%PATH%"
rem Harden state/ ACLs (Windows needs WRITE_DAC; the directory owner normally has it,
rem so no UAC prompt in the usual case). This NEVER blocks startup: if it cannot get
rem permission it prints a copy-pasteable command and exits 0.
rem See docs/guides/SECURITY_BASELINE.md ("secrets at rest").
node scripts\harden-state-acl.mjs --quiet
:loop
node src/bridge.js
set code=%errorlevel%
rem KEEP THIS FILE PURE ASCII. Non-ASCII bytes make cmd.exe mis-read the file and chop
rem the start of the following lines (seen: 'arden-state-acl.mjs', 'em' ... not recognized).
rem exit code 2 = do NOT restart: either another instance is already running, or we were
rem asked to stop gracefully (console POST /api/shutdown, or Ctrl+C in this window);
rem that path announces "offline" to the whitelist before exiting.
if "%code%"=="2" (
    echo [%date% %time%] bridge stopped, exit code 2 - graceful shutdown installed. Not restarting.
    ping -n 6 127.0.0.1 >nul
    exit /b 2
)
echo [%date% %time%] bridge exited with code %code%, restarting in 5 seconds...
ping -n 6 127.0.0.1 >nul
goto loop
