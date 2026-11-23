# Nexmem Web 网关本地一键启动（P6-10，Windows）
#
#   powershell -ExecutionPolicy Bypass -File deploy/web/start.ps1
#   powershell -ExecutionPolicy Bypass -File deploy/web/start.ps1 -Addr :8443 `
#       -TlsCert deploy/web/data/dev-cert.pem -TlsKey deploy/web/data/dev-key.pem
#
# 脚本会：确保令牌文件存在 -> 编译 nexmem-webd -> 按需构建 Flutter Web -> 前台启动。

param(
    [string]$Addr = ":8082",
    [string]$TokenFile = "",
    [string]$StaticDir = "",
    [string]$TlsCert = "",
    [string]$TlsKey = "",
    [string]$Origins = "",
    [switch]$RebuildWeb,
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $TokenFile) { $TokenFile = Join-Path $PSScriptRoot "data\token" }
if (-not $StaticDir) { $StaticDir = Join-Path $repoRoot "app\build\web" }

$goExe = Join-Path $repoRoot ".toolchain\go\bin\go.exe"
if (-not (Test-Path $goExe)) { $goExe = "go" }

$flutterExe = Join-Path $repoRoot ".toolchain\flutter\bin\flutter.bat"
if (-not (Test-Path $flutterExe)) { $flutterExe = "flutter" }

# 1. 令牌文件：不存在则生成 48 位十六进制随机令牌（0600 语义由目录权限保证）
$tokenDir = Split-Path -Parent $TokenFile
if (-not (Test-Path $tokenDir)) { New-Item -ItemType Directory -Path $tokenDir | Out-Null }
if (-not (Test-Path $TokenFile)) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ($bytes | ForEach-Object { $_.ToString("x2") }) -join "" | Set-Content -Path $TokenFile -NoNewline -Encoding ASCII
    Write-Host "已生成访问令牌: $TokenFile"
}
Write-Host "访问令牌: $(Get-Content -Raw $TokenFile)"

# 2. 编译网关
$binDir = Join-Path $repoRoot "bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$exe = Join-Path $binDir "nexmem-webd.exe"
if (-not $NoBuild) {
    Write-Host "编译 nexmem-webd ..."
    & $goExe -C (Join-Path $repoRoot "core") build -o $exe ./cmd/nexmem-webd
    if ($LASTEXITCODE -ne 0) { throw "编译 nexmem-webd 失败" }
}
if (-not (Test-Path $exe)) { throw "未找到 $exe，请去掉 -NoBuild 重新执行" }

# 3. Flutter Web 产物
if ($RebuildWeb -or -not (Test-Path (Join-Path $StaticDir "index.html"))) {
    Write-Host "构建 Flutter Web 产物 ..."
    $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
    & $flutterExe build web --release --project-directory (Join-Path $repoRoot "app")
    if ($LASTEXITCODE -ne 0) { throw "flutter build web 失败" }
}

# 4. 前台启动
$runArgs = @("-addr", $Addr, "-token-file", $TokenFile, "-static", $StaticDir)
if ($Origins) { $runArgs += @("-origins", $Origins) }
if ($TlsCert) { $runArgs += @("-tls-cert", $TlsCert) }
if ($TlsKey) { $runArgs += @("-tls-key", $TlsKey) }

Write-Host "启动: $exe $($runArgs -join ' ')"
& $exe @runArgs
