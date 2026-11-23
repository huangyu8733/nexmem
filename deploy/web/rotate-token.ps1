# 轮换 Nexmem Web 访问令牌（P6-10）
#
#   powershell -ExecutionPolicy Bypass -File deploy/web/rotate-token.ps1
#
# 覆盖令牌文件后，nexmem-webd 在 2s 内自动重新加载并断开全部旧连接；
# 浏览器需要用新令牌重新握手（旧令牌立即失效）。

param(
    [string]$TokenFile = ""
)

$ErrorActionPreference = "Stop"

if (-not $TokenFile) { $TokenFile = Join-Path $PSScriptRoot "data\token" }
$tokenDir = Split-Path -Parent $TokenFile
if (-not (Test-Path $tokenDir)) { New-Item -ItemType Directory -Path $tokenDir | Out-Null }

$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$token = ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""

# 先写临时文件再替换，避免网关读到半个令牌
$tmp = "$TokenFile.new"
Set-Content -Path $tmp -Value $token -NoNewline -Encoding ASCII
Move-Item -Force -Path $tmp -Destination $TokenFile

Write-Host "新访问令牌: $token"
Write-Host "已写入 $TokenFile，网关将在 2s 内生效并断开旧连接。"
