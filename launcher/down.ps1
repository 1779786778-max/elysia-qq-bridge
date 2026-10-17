# QQ机器人 下线：停桥接 + 停 SnowLuma。**不动 QQ**（小号保持登录，下次上线不用扫码）。
# 顺序要紧（三条）：
#   1) 先请桥接**自己**优雅下线 —— 它会先给白名单私聊用户发「已下线」再退出；直接 Stop-Process -Force
#      不执行任何 JS，播报就永远发不出去；
#   2) 播报要发得出去，SnowLuma 必须还活着 → 所以 SnowLuma 放最后停；
#   3) 桥接的 start.bat 里有个 :loop，先杀 node 会被 5 秒后自动拉起来，所以先杀 cmd 包装。
# 加 -DryRun 只看它会做什么。
param([switch]$DryRun)
$ErrorActionPreference = 'Continue'
$dry = [bool]$DryRun
# SnowLuma（QQ 网关门）装在哪就改这一行；默认 C:\SnowLuma。
$snowluma = 'C:\SnowLuma'
# 桥接目录 = 本脚本上一级（launcher\down.ps1 -> 仓库根）。
$bridgeDir = Split-Path -Parent $PSScriptRoot
$bad = @()

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

function Stop-Match {
  param([string]$Label, [scriptblock]$Filter)
  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object $Filter
  if (-not $procs) { Write-Host ('[=] ' + $Label + ' 没在跑') -ForegroundColor DarkGray; return }
  foreach ($p in $procs) {
    if ($dry) {
      Write-Host ('[i] 会结束 ' + $Label + ' pid ' + $p.ProcessId) -ForegroundColor Yellow
    } else {
      Write-Host ('[-] 结束 ' + $Label + ' pid ' + $p.ProcessId) -ForegroundColor Cyan
      Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host '=== QQ机器人 下线 ===' -ForegroundColor Cyan

# 0) 优雅下线：桥接自己播报「已下线」后以 exit 2 退出（:loop 不会再拉起）
if (Test-Port 3100) {
  if ($dry) {
    Write-Host '[i] 会先 POST http://127.0.0.1:3100/api/shutdown，让桥接播报「已下线」再退出' -ForegroundColor Yellow
  } else {
    $tokenFile = Join-Path $bridgeDir 'state\console-token'
    $token = if (Test-Path $tokenFile) { (Get-Content $tokenFile -Raw).Trim() } else { '' }
    Write-Host '[+] 请桥接优雅下线（会给白名单私聊用户发「已下线」）…' -ForegroundColor Cyan
    try {
      # 控制台要求 POST 带 application/json，否则 415（bridge.js:3136）。
      $r = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:3100/api/shutdown' `
             -Headers @{ 'x-console-token' = $token } -ContentType 'application/json' -Body '{}' -TimeoutSec 15
      Write-Host ('    桥接回答：' + $r.message) -ForegroundColor DarkGray
    } catch {
      Write-Host ('    [!] 请求没成功（' + $_.Exception.Message + '），下面按强制结束处理') -ForegroundColor Yellow
    }
    for ($i = 0; $i -lt 55; $i++) { if (-not (Test-Port 3100)) { break }; Start-Sleep -Seconds 1 }
    if (Test-Port 3100) { Write-Host '    [!] 55 秒还没退出（在线播报可能在重试），下面强制结束' -ForegroundColor Yellow; $bad += '桥接没自己退出' }
    else { Write-Host '    桥接已退出（已下线播报走完）' -ForegroundColor Green }
  }
} else {
  Write-Host '[=] 桥接没在跑，跳过「已下线」播报' -ForegroundColor DarkGray
}

Stop-Match '桥接窗口(cmd)'      { $_.Name -eq 'cmd.exe'  -and $_.CommandLine -like '*qq-bridge\start.bat*' }
Stop-Match '桥接进程(node)'     { $_.Name -eq 'node.exe' -and $_.CommandLine -like '*bridge.js*' }
Stop-Match 'SnowLuma窗口(cmd)'  { $_.Name -eq 'cmd.exe'  -and $_.CommandLine -like '*SnowLuma\start.bat*' }
Stop-Match 'SnowLuma进程(node)' { $_.Name -eq 'node.exe' -and $_.ExecutablePath -like ($snowluma + '\*') }

if (-not $dry) {
  Start-Sleep -Seconds 6
  $left = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
          Where-Object { $_.LocalPort -in 3100, 3000, 3001, 5099 }
  if ($left) {
    Write-Host '[!] 这些端口还有人在听：' -ForegroundColor Yellow
    $left | ForEach-Object { Write-Host ('    ' + $_.LocalAddress + ':' + $_.LocalPort + ' pid=' + $_.OwningProcess) }
    $bad += '端口没释放'
  } else {
    Write-Host '[=] 3100 / 3000 / 3001 / 5099 都已释放' -ForegroundColor Green
  }
  foreach ($p in 3100, 3000, 3001, 5099) { if (Test-Port $p) { $bad += ('端口 ' + $p + ' 仍在听') } }
  $q = @(Get-Process QQ -ErrorAction SilentlyContinue).Count
  Write-Host ('[=] QQ 进程仍在：' + $q + ' 个（没有动它）') -ForegroundColor DarkGray
}

Write-Host ''
if ($bad.Count -gt 0) {
  Write-Host ('有没处理干净的：' + ($bad -join '、')) -ForegroundColor Yellow
  Write-Host '可以再点一次下线；还不行就把这个窗口发我。' -ForegroundColor Yellow
  Read-Host '按回车关闭'
} else {
  Write-Host 'QQ 没动：小号还登着，hook 也还在 QQ 进程里。' -ForegroundColor DarkGray
  Write-Host '想让 QQ 彻底干净（去掉 hook），重启一次 QQ 即可。' -ForegroundColor DarkGray
  Write-Host '（本窗口 8 秒后自动关闭）' -ForegroundColor DarkGray
  Start-Sleep -Seconds 8
}
