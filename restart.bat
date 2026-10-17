@echo off
chcp 65001 >nul
cd /d "%~dp0"
rem Node may not be on PATH on this machine: fall back to DSH's bundled Node runtime (>=22.13).
where node >nul 2>nul || set "PATH=%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin;%PATH%"
rem KEEP THIS FILE PURE ASCII. Non-ASCII bytes make cmd.exe mis-read this very file on a
rem GBK (936) console and chop the start of the following lines. start.bat is ASCII for
rem the same reason.
echo Stopping old guard windows...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='cmd.exe'\" | Where-Object { $_.CommandLine -like '*start.bat*' -and $_.CommandLine -notlike '*restart.bat*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
echo Stopping old bridge processes...
rem start.bat launches with a RELATIVE path (node src/bridge.js), so the process CommandLine
rem never contains the repo path -- matching on '*%~dp0src\bridge.js*' silently matched
rem nothing and "restart" merely added a second instance while the old one kept running
rem (state/bridge.log once showed two instances joining the DSH stream at the same minute;
rem only the console-port conflict kept one out, and it overwrote social-v2.json with a
rem stale snapshot). Kill by PID (from the lock file) plus a '*bridge.js*' fallback.
powershell -NoProfile -Command "$lock = Join-Path '%~dp0' 'state\bridge.lock'; $pids = @(); if (Test-Path $lock) { $raw = (Get-Content $lock -Raw).Trim(); if ($raw -match '^\d+$') { $pids += [int]$raw } }; Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*bridge.js*' -and $_.CommandLine -notlike '*mcp-*' -and $_.CommandLine -notlike '*node_modules*' } | ForEach-Object { $pids += $_.ProcessId }; $pids | Sort-Object -Unique | ForEach-Object { Write-Host ('  kill PID ' + $_); Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"
rem Wait until the old instance really exited (and released the console port) before
rem deleting the lock: "lock gone but process alive" is exactly the two-instance case.
ping -n 4 127.0.0.1 >nul
powershell -NoProfile -Command "$live = Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*bridge.js*' -and $_.CommandLine -notlike '*mcp-*' -and $_.CommandLine -notlike '*node_modules*' }; if ($live) { Write-Host 'bridge processes still alive:'; $live | ForEach-Object { Write-Host ('  PID ' + $_.ProcessId + '  ' + $_.CommandLine) }; exit 1 } else { exit 0 }"
if errorlevel 1 (
    echo.
    echo Restart aborted: two instances would fight over messages and overwrite state.
    echo End the PIDs listed above, then run this again.
    pause
    exit /b 1
)
del state\bridge.lock 2>nul
start "" cmd /c start.bat
echo Guard window started.
