# Nexmem Windows 桌面端卸载脚本（P6-03）
#
# 删除安装目录、开始菜单快捷方式与卸载注册项，默认保留用户数据目录。
# 用法：
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeData
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Nexmem'),
    [switch]$PurgeData,
    [switch]$FromTemp
)

$ErrorActionPreference = 'Stop'

# 脚本自身位于待删除目录内时，先复制到临时目录再执行，避免文件占用导致删除失败
if (-not $FromTemp -and $PSScriptRoot.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
    $temp = Join-Path $env:TEMP 'nexmem-uninstall.ps1'
    Copy-Item -Path $PSCommandPath -Destination $temp -Force
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$temp`"",
        '-InstallDir', "`"$InstallDir`"", '-FromTemp')
    if ($PurgeData) { $argsList += '-PurgeData' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Wait
    exit 0
}

Get-Process -Name 'nexmem_app' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
    } catch { }
}

$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Nexmem.lnk'
if (Test-Path $shortcut) { Remove-Item $shortcut -Force }

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Nexmem'
if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force }

if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Write-Output "UNINSTALL_DIR=$InstallDir"

if ($PurgeData) {
    $dataDir = Join-Path $env:APPDATA 'io.nexmem\nexmem_app'
    if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force }
    Write-Output "PURGED_DATA=$dataDir"
} else {
    Write-Output 'DATA_PRESERVED=true'
}

Write-Output 'RESULT=PASS'
