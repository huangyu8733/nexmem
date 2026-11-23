# 真实网络场景执行脚本：两台机器分别跑 echo / dial。
#
# 示例（家宽作 echo，4G 作 dial）：
#   pwsh -File tools/p0/run-scenario.ps1 -Role echo -Bootstrap /ip4/1.2.3.4/tcp/14001/p2p/12D3Koo...
#   pwsh -File tools/p0/run-scenario.ps1 -Role dial -Bootstrap /ip4/1.2.3.4/tcp/14001/p2p/12D3Koo... `
#        -Peer 12D3KooW... -Scenario home -Iter 50
#
# 中继回退：
#   dial 侧加 -Via circuit -Relay /ip4/1.2.3.4/tcp/14002/p2p/12D3Koo... -UpgradeWait 0s
param(
    [Parameter(Mandatory = $true)]
    [string]$Bootstrap,

    [Parameter(Mandatory = $true)]
    [ValidateSet("echo", "dial")]
    [string]$Role,

    [string]$Peer = "",
    [string]$Scenario = "home",
    [int]$Iter = 50,
    [ValidateSet("dht", "circuit")]
    [string]$Via = "dht",
    [string]$Relay = "",
    [string]$UpgradeWait = "10s",
    [string]$Listen = "/ip4/0.0.0.0/tcp/0,/ip4/0.0.0.0/udp/0/quic-v1",
    [string]$DataDir = "",
    [string]$IdPath = ""
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$bin = Join-Path $root "bin"
if (-not $DataDir) { $DataDir = Join-Path $root "data\p0" }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
if (-not $IdPath) { $IdPath = Join-Path $DataDir "$Role.key" }

$exe = Join-Path $bin "spike-nat.exe"

if ($Role -eq "echo") {
    Write-Host "echo 模式：保持前台运行，记录 ECHO_READY 中的 PeerID 供 dial 侧使用"
    & $exe -role echo -bootstrap $Bootstrap -listen $Listen -id $IdPath
    exit $LASTEXITCODE
}

if (-not $Peer) { throw "dial 角色必须提供 -Peer" }

$csv = Join-Path $DataDir "$Scenario.csv"
$dialArgs = @(
    "-role", "dial",
    "-bootstrap", $Bootstrap,
    "-peer", $Peer,
    "-listen", $Listen,
    "-id", $IdPath,
    "-scenario", $Scenario,
    "-iter", $Iter,
    "-via", $Via,
    "-upgrade-wait", $UpgradeWait,
    "-csv", $csv
)
if ($Relay) { $dialArgs += @("-relay", $Relay) }

& $exe @dialArgs
if ($LASTEXITCODE -ne 0) { throw "dial 失败，退出码 $LASTEXITCODE" }
Write-Host "结果: $csv"
