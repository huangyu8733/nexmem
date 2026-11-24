# Nexmem 服务端原生一键启动（Windows）
#
#   powershell -ExecutionPolicy Bypass -File deploy/server/start.ps1 -PublicIp 1.2.3.4
#   powershell -ExecutionPolicy Bypass -File deploy/server/start.ps1 -Component directory
#
# 参数：
#   -Component   all（默认）/ directory / bootstrap / relay / build
#   -PublicIp    服务器真实公网 IP（bootstrap/relay 必填）
#   -DataDir     数据目录，默认 <repo>\data\server
#   -Ports       对外端口，默认 14001 / 14002 / 8081
#   -Bandwidth   中继每窗口限额字节数，默认 1 GiB
#   -Window      中继限额窗口，默认 1h

param(
    [ValidateSet("all", "directory", "bootstrap", "relay", "build")]
    [string]$Component = "all",
    [string]$PublicIp = $env:NEXMEM_PUBLIC_IP,
    [string]$DataDir = "",
    [int]$BootstrapPort = 14001,
    [int]$RelayPort = 14002,
    [int]$DirectoryPort = 8081,
    [long]$Bandwidth = 1073741824,
    [string]$Window = "1h",
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $DataDir) { $DataDir = if ($env:NEXMEM_DATA_DIR) { $env:NEXMEM_DATA_DIR } else { Join-Path $repoRoot "data\server" } }
$binDir = Join-Path $repoRoot "bin"
$binDirectory = Join-Path $binDir "nexmem-directory.exe"
$binBootstrap = Join-Path $binDir "nexmem-bootstrap.exe"
$binRelay = Join-Path $binDir "nexmem-relay.exe"

$goExe = Join-Path $repoRoot ".toolchain\go\bin\go.exe"
if (-not (Test-Path $goExe)) { $goExe = "go" }

function Build-All {
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Write-Host "编译服务端二进制到 $binDir ..."
    & $goExe -C (Join-Path $repoRoot "core") build -o $binDirectory ./cmd/nexmem-directory
    if ($LASTEXITCODE -ne 0) { throw "编译 nexmem-directory 失败" }
    & $goExe -C (Join-Path $repoRoot "core") build -o $binBootstrap ./cmd/nexmem-bootstrap
    if ($LASTEXITCODE -ne 0) { throw "编译 nexmem-bootstrap 失败" }
    & $goExe -C (Join-Path $repoRoot "core") build -o $binRelay ./cmd/nexmem-relay
    if ($LASTEXITCODE -ne 0) { throw "编译 nexmem-relay 失败" }
}

function Ensure-Built {
    if ($NoBuild) { return }
    if (-not (Test-Path $binDirectory) -or -not (Test-Path $binBootstrap) -or -not (Test-Path $binRelay)) {
        Build-All
    }
}

function Require-PublicIp {
    if (-not $PublicIp) { throw "请通过 -PublicIp 或环境变量 NEXMEM_PUBLIC_IP 指定服务器公网 IP" }
}

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

switch ($Component) {
    "build" { Build-All; return }
    "all" {
        Ensure-Built
        Require-PublicIp
        # PowerShell 不允许 stdout 与 stderr 重定向到同一文件，这里分开两个日志。
        $dirOut = Join-Path $DataDir "directory.out.log"
        $dirErr = Join-Path $DataDir "directory.err.log"
        $relayOut = Join-Path $DataDir "relay.out.log"
        $relayErr = Join-Path $DataDir "relay.err.log"
        $dirProc = Start-Process -FilePath $binDirectory -ArgumentList @("-addr", ":$DirectoryPort", "-db", (Join-Path $DataDir "directory.db")) -RedirectStandardOutput $dirOut -RedirectStandardError $dirErr -PassThru
        $relayProc = Start-Process -FilePath $binRelay -ArgumentList @(
            "-listen", "/ip4/0.0.0.0/tcp/$RelayPort,/ip4/0.0.0.0/udp/$RelayPort/quic-v1",
            "-announce", "/ip4/$PublicIp/tcp/$RelayPort,/ip4/$PublicIp/udp/$RelayPort/quic-v1",
            "-id", (Join-Path $DataDir "relay.key"),
            "-bandwidth", "$Bandwidth", "-window", $Window
        ) -RedirectStandardOutput $relayOut -RedirectStandardError $relayErr -PassThru
        Write-Host "directory pid=$($dirProc.Id), relay pid=$($relayProc.Id)；日志在 $DataDir"
        Write-Host "bootstrap 在前台运行，Ctrl+C 后请手动停止上述进程"
        try {
            & $binBootstrap -listen "/ip4/0.0.0.0/tcp/$BootstrapPort,/ip4/0.0.0.0/udp/$BootstrapPort/quic-v1" -announce "/ip4/$PublicIp/tcp/$BootstrapPort,/ip4/$PublicIp/udp/$BootstrapPort/quic-v1" -id (Join-Path $DataDir "bootstrap.key")
        } finally {
            Stop-Process -Id $dirProc.Id -Force -ErrorAction SilentlyContinue
            Stop-Process -Id $relayProc.Id -Force -ErrorAction SilentlyContinue
        }
        return
    }
    "directory" {
        Ensure-Built
        & $binDirectory -addr ":$DirectoryPort" -db (Join-Path $DataDir "directory.db")
        return
    }
    "bootstrap" {
        Ensure-Built
        Require-PublicIp
        & $binBootstrap -listen "/ip4/0.0.0.0/tcp/$BootstrapPort,/ip4/0.0.0.0/udp/$BootstrapPort/quic-v1" -announce "/ip4/$PublicIp/tcp/$BootstrapPort,/ip4/$PublicIp/udp/$BootstrapPort/quic-v1" -id (Join-Path $DataDir "bootstrap.key")
        return
    }
    "relay" {
        Ensure-Built
        Require-PublicIp
        & $binRelay -listen "/ip4/0.0.0.0/tcp/$RelayPort,/ip4/0.0.0.0/udp/$RelayPort/quic-v1" -announce "/ip4/$PublicIp/tcp/$RelayPort,/ip4/$PublicIp/udp/$RelayPort/quic-v1" -id (Join-Path $DataDir "relay.key") -bandwidth $Bandwidth -window $Window
        return
    }
}
