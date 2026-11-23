# 本地冒烟测量：bootstrap（可选兼作 relay）+ echo + dial 全在一台机器上跑。
# 用途是验证链路打通与指标采集，不代表真实 NAT 打洞率。
#
# 用法：
#   pwsh -File tools/p0/run-local.ps1 -Iter 5
#   pwsh -File tools/p0/run-local.ps1 -Iter 5 -Relay     # 额外验证 circuit 中继链路
param(
    [int]$Iter = 5,
    [string]$Out = "",
    [switch]$Relay
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bin = Join-Path $root "bin"
$dataDir = Join-Path $root "data\p0"
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$bootPort = 14001
$scenario = "local"
if ($Relay) { $scenario = "local-relay" }
if (-not $Out) { $Out = Join-Path $dataDir "$scenario.csv" }

$bootOut = Join-Path $dataDir "bootstrap.out"
$bootErr = Join-Path $dataDir "bootstrap.err"
$echoOut = Join-Path $dataDir "echo.out"
$echoErr = Join-Path $dataDir "echo.err"

foreach ($f in @($bootOut, $bootErr, $echoOut, $echoErr)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

function Wait-Line {
    param([string]$Path, [string]$Pattern, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $Path) {
            $hit = Get-Content $Path -ErrorAction SilentlyContinue |
                Where-Object { $_ -match $Pattern } | Select-Object -First 1
            if ($hit) { return $hit }
        }
        Start-Sleep -Milliseconds 200
    }
    throw "等待 $Pattern 超时，请检查 $Path"
}

$boot = $null
$echo = $null
try {
    $bootArgs = @("-listen", "/ip4/127.0.0.1/tcp/$bootPort,/ip4/127.0.0.1/udp/$bootPort/quic-v1",
                  "-id", (Join-Path $dataDir "bootstrap.key"))
    if ($Relay) { $bootArgs += @("-relay", "-allow-private") }

    $boot = Start-Process -FilePath (Join-Path $bin "nexmem-bootstrap.exe") `
        -ArgumentList $bootArgs `
        -RedirectStandardOutput $bootOut -RedirectStandardError $bootErr -PassThru -NoNewWindow

    $json = Wait-Line -Path $bootOut -Pattern '"peer_id"'
    $info = $json | ConvertFrom-Json
    $bootAddr = $info.addrs | Where-Object { $_ -match "/tcp/$bootPort/" } | Select-Object -First 1
    if (-not $bootAddr) { $bootAddr = $info.addrs[0] }
    Write-Host "bootstrap: $bootAddr (relay=$Relay)"

    $echoArgs = @("-role", "echo", "-bootstrap", $bootAddr,
                  "-listen", "/ip4/127.0.0.1/tcp/0,/ip4/127.0.0.1/udp/0/quic-v1",
                  "-id", (Join-Path $dataDir "echo.key"))
    if ($Relay) { $echoArgs += @("-relay", $bootAddr) }

    $echo = Start-Process -FilePath (Join-Path $bin "spike-nat.exe") `
        -ArgumentList $echoArgs `
        -RedirectStandardOutput $echoOut -RedirectStandardError $echoErr -PassThru -NoNewWindow

    $echoLine = Wait-Line -Path $echoOut -Pattern "ECHO_READY"
    $echoId = ($echoLine -split "peer_id=")[1].Trim()
    Write-Host "echo peer: $echoId"

    if ($Relay) {
        Wait-Line -Path $echoOut -Pattern "ECHO_RELAY_READY" -TimeoutSec 30 | Out-Null
        $circuit = Get-Content $echoOut | Where-Object { $_ -match "ECHO_CIRCUIT" } | Select-Object -First 1
        Write-Host "circuit: $circuit"
    }

    # 给 DHT 一点时间完成路由表填充
    Start-Sleep -Seconds 2

    $dialArgs = @("-role", "dial", "-bootstrap", $bootAddr, "-peer", $echoId,
                  "-scenario", $scenario, "-iter", $Iter, "-csv", $Out)
    if ($Relay) {
        $dialArgs += @("-via", "circuit", "-relay", $bootAddr, "-upgrade-wait", "0s")
    } else {
        $dialArgs += @("-via", "dht")
    }

    & (Join-Path $bin "spike-nat.exe") @dialArgs
    if ($LASTEXITCODE -ne 0) { throw "dial 失败，退出码 $LASTEXITCODE" }

    Write-Host "结果已写入: $Out"
}
finally {
    if ($echo -and -not $echo.HasExited) { Stop-Process -Id $echo.Id -Force -ErrorAction SilentlyContinue }
    if ($boot -and -not $boot.HasExited) { Stop-Process -Id $boot.Id -Force -ErrorAction SilentlyContinue }
}
