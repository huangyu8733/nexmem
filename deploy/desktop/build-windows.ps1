# Nexmem Windows 桌面端打包脚本（P6-03）
#
# 产物：
#   dist\nexmem-windows-x64\                     可直接运行的目录
#   dist\Nexmem-<version>-windows-x64.zip        免安装分发包（解压后运行 install.ps1 安装）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File deploy\desktop\build-windows.ps1
#   powershell -ExecutionPolicy Bypass -File deploy\desktop\build-windows.ps1 -SkipFlutterBuild
param(
    [string]$Version = '',
    [switch]$SkipFlutterBuild,
    [switch]$SkipCoreBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$appDir = Join-Path $repoRoot 'app'
$coreDir = Join-Path $repoRoot 'core'
$flutter = Join-Path $repoRoot '.toolchain\flutter\flutter\bin\flutter.bat'
$go = Join-Path $repoRoot '.toolchain\go\bin\go.exe'
$releaseDir = Join-Path $appDir 'build\windows\x64\runner\Release'
$distDir = Join-Path $repoRoot 'dist'
$stageDir = Join-Path $distDir 'nexmem-windows-x64'
$coreDll = Join-Path $repoRoot 'bin\nexmem.dll'

if (-not $Version) {
    $line = Select-String -Path (Join-Path $appDir 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' |
        Select-Object -First 1
    if ($line) { $Version = $line.Matches[0].Groups[1].Value } else { $Version = '0.1.0' }
}

if (-not (Test-Path $go)) { $go = 'go' }
if (-not (Test-Path $flutter)) { throw "未找到 Flutter：$flutter" }

# 1. 构建内核 c-shared DLL（dart:ffi 加载）
if (-not $SkipCoreBuild) {
    Write-Output '[1/4] 构建 nexmem.dll (go build -buildmode=c-shared)'
    Push-Location $coreDir
    try {
        & $go build -buildmode=c-shared -o $coreDll ./ffi/capi
        if ($LASTEXITCODE -ne 0) { throw "go build 失败，退出码 $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# 2. 构建 Flutter Windows 产物
if (-not $SkipFlutterBuild) {
    Write-Output '[2/4] 构建 Flutter Windows 产物 (flutter build windows --release)'
    Push-Location $appDir
    try {
        & $flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败，退出码 $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path (Join-Path $releaseDir 'nexmem_app.exe'))) {
    throw "缺少构建产物：$releaseDir\nexmem_app.exe"
}

# 3. 暂存目录：Flutter 产物 + 内核 DLL + 安装脚本
Write-Output '[3/4] 组装发布目录'
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse -Force
Copy-Item -Path $coreDll -Destination (Join-Path $stageDir 'nexmem.dll') -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'install.ps1') -Destination $stageDir -Force
Copy-Item -Path (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination $stageDir -Force

# 4. 打 zip
Write-Output '[4/4] 生成免安装压缩包'
$zipPath = Join-Path $distDir "Nexmem-$Version-windows-x64.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Output "DIST_DIR=$stageDir"
Write-Output "DIST_ZIP=$zipPath"
Write-Output "DIST_VERSION=$Version"
Write-Output "DIST_ZIP_MB=$size"
Write-Output 'RESULT=PASS'
