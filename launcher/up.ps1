# QQ机器人 上线：确保 SnowLuma（QQ 网关门）与 qq-bridge（桥接）都在跑。
# 双击桌面「QQ机器人-上线」即可；加 -DryRun 只看它会做什么，不动任何进程。
# 已在跑的一侧会跳过，所以重复双击是安全的。
param([switch]$DryRun)
$ErrorActionPreference = 'Continue'

$snowluma = 'C:\SnowLuma'
# 桥接目录 = 本脚本上一级（launcher\up.ps1 -> 仓库根），整个仓库可以放在任意路径。
$bridge   = (Split-Path -Parent $PSScriptRoot)
$dry = [bool]$DryRun
$bad = @()
$startedSnow = $false

# 端口是否真的在听：先用 Get-NetTCPConnection（比解析 netstat 文本可靠），
# 拿不到这个命令就退回真连一次 127.0.0.1:$Port。
function Test-Port {
  param([int]$Port)
  try { if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop) { return $true } } catch { }
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $Port)
    $c.Close()
    return $true
  } catch { return $false }
}

# 光「端口在听」不等于服务活着（僵尸进程：socket 还在、进程已经废了）。
# 这里真发一次 HTTP：有回应（哪怕 401/404）才算活着。
function Test-Http {
  param([int]$Port, [string]$Path = '/', [int]$TimeoutSec = 5)
  try {
    Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + $Path) -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
    return $true
  } catch {
    if ($_.Exception.Response) { return $true }
    return $false
  }
}

function Wait-Port {
  param([int]$Port, [int]$Seconds = 60)
  for ($i = 0; $i -lt $Seconds; $i++) {
    if (Test-Port $Port) { return $true }
    Start-Sleep -Seconds 1
  }
  return (Test-Port $Port)
}

function Start-Window {
  param([string]$Bat, [string]$Dir)
  Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $Bat -WorkingDirectory $Dir
}

function Show-Tail {
  param([string]$Path, [int]$Lines = 15)
  if (-not $Path -or -not (Test-Path $Path)) { Write-Host ('    （没有日志文件：' + $Path + '）') -ForegroundColor DarkGray; return }
  Write-Host ('    —— ' + $Path + ' 末尾 ——') -ForegroundColor DarkGray
  Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('    ' + $_) -ForegroundColor DarkGray }
}

function Newest-Log {
  param([string]$Dir)
  $f = Get-ChildItem -Path $Dir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f) { return $f.FullName }
  return ''
}

# 端口在听但页面打不开 = 僵尸残留。清掉它，否则新实例抢不到端口，看起来就是「点了没用」。
function Stop-SnowLumaLeftover {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -eq 'cmd.exe'  -and $_.CommandLine -like '*SnowLuma\start.bat*') -or
    ($_.Name -eq 'node.exe' -and $_.ExecutablePath -like ($snowluma + '\*'))
  } | ForEach-Object {
    Write-Host ('    [-] 清掉没响应的 SnowLuma 残留 pid ' + $_.ProcessId) -ForegroundColor Yellow
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 2
}

Write-Host '=== QQ机器人 上线 ===' -ForegroundColor Cyan

# 1) SnowLuma：QQ 的网关门（WebUI 5099 / OneBot HTTP 3000 / WS 3001）
$slPort = Test-Port 5099
$slAlive = $slPort -and (Test-Http 5099 '/')
if ($slAlive) {
  Write-Host '[=] SnowLuma 已在运行（面板 http://127.0.0.1:5099）' -ForegroundColor DarkGray
} elseif ($dry) {
  Write-Host ('[i] 会启动 SnowLuma: cmd /c ' + $snowluma + '\start.bat') -ForegroundColor Yellow
} else {
  if ($slPort) {
    Write-Host '[!] 5099 在听但页面打不开（僵尸残留），先清掉再启动' -ForegroundColor Yellow
    Stop-SnowLumaLeftover
  }
  Write-Host '[+] 启动 SnowLuma …（约 10 秒，QQ 会被重新注入 hook 并自己重启一次）' -ForegroundColor Cyan
  Start-Window ($snowluma + '\start.bat') $snowluma
  if (Wait-Port 5099) {
    Write-Host '    就绪：面板 http://127.0.0.1:5099' -ForegroundColor Green
    $startedSnow = $true
  } else {
    Write-Host '    [x] 60 秒没起来' -ForegroundColor Red
    $bad += 'SnowLuma'
    Show-Tail (Newest-Log ($snowluma + '\logs')) 15
    Show-Tail ($snowluma + '\logs\console-start.err.log') 15
  }
}

# 2) 桥接：QQ <-> DSH 的翻译层（控制台 3100）
$brPort = Test-Port 3100
$brAlive = $brPort -and (Test-Http 3100 '/api/status')
if ($brAlive) {
  Write-Host '[=] 桥接已在运行（控制台 http://127.0.0.1:3100）' -ForegroundColor DarkGray
} elseif ($dry) {
  Write-Host ('[i] 会启动桥接: cmd /c ' + $bridge + '\start.bat') -ForegroundColor Yellow
} else {
  Write-Host '[+] 启动桥接 …' -ForegroundColor Cyan
  Start-Window ($bridge + '\start.bat') $bridge
  if (Wait-Port 3100) {
    Write-Host '    就绪：控制台 http://127.0.0.1:3100' -ForegroundColor Green
  } else {
    Write-Host '    [x] 60 秒没起来' -ForegroundColor Red
    $bad += '桥接'
    Show-Tail ($bridge + '\state\bridge.log') 20
  }
}

# 3) OneBot 端口：这两个不在听 = 小号没登录（桥接会一直 1006 重连，不会崩）
if (-not $dry) {
  if ((Test-Port 3000) -and (Test-Port 3001)) {
    Write-Host '[=] OneBot 3000/3001 在听' -ForegroundColor DarkGray
  } else {
    Write-Host '[!] 3000/3001 没在听：小号可能没登录（打开 QQ 登录小号即可）' -ForegroundColor Yellow
  }
}

Write-Host ''
if ($bad.Count -gt 0) {
  Write-Host ('有没起来的：' + ($bad -join '、')) -ForegroundColor Red
  Write-Host '窗口先别关 —— 上面的日志末尾就是原因；把它截图发我也行。' -ForegroundColor Yellow
  Read-Host '按回车关闭'
} elseif ($dry) {
  Write-Host '（-DryRun：什么都没启动）' -ForegroundColor Yellow
} else {
  Write-Host '已上线。两个服务各有自己的黑窗口，别关它们。' -ForegroundColor Green
  if ($startedSnow) {
    Write-Host '顺手把面板打开：http://127.0.0.1:5099' -ForegroundColor DarkGray
    Start-Process 'http://127.0.0.1:5099'
  }
  Write-Host '（本窗口 8 秒后自动关闭）' -ForegroundColor DarkGray
  Start-Sleep -Seconds 8
}
