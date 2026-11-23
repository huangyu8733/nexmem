# Nexmem Windows 桌面端安装脚本（P6-03）
#
# 将发布目录复制到用户目录并注册开始菜单快捷方式与卸载项，无需管理员权限。
# 用法：
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -InstallDir 'D:\Apps\Nexmem'
param(
    [string]$Source = $PSScriptRoot,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Nexmem'),
    [switch]$NoShortcut
)

$ErrorActionPreference = 'Stop'

$exeName = 'nexmem_app.exe'
$sourceExe = Join-Path $Source $exeName
if (-not (Test-Path $sourceExe)) {
    throw "安装源缺少 $exeName：$Source"
}

# 覆盖安装前先停止同目录下的旧进程
Get-Process -Name 'nexmem_app' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        if ($_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
    } catch { }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $Source '*') -Destination $InstallDir -Recurse -Force

$installedExe = Join-Path $InstallDir $exeName
$uninstallScript = Join-Path $InstallDir 'uninstall.ps1'

# 注册 HKCU 卸载项（设置 → 应用 可见）
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Nexmem'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name 'DisplayName' -Value 'Nexmem'
Set-ItemProperty -Path $uninstallKey -Name 'DisplayVersion' -Value '1.0.0'
Set-ItemProperty -Path $uninstallKey -Name 'Publisher' -Value 'Nexmem'
Set-ItemProperty -Path $uninstallKey -Name 'DisplayIcon' -Value $installedExe
Set-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $InstallDir
Set-ItemProperty -Path $uninstallKey -Name 'NoModify' -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name 'NoRepair' -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name 'UninstallString' `
    -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""

# 开始菜单快捷方式
if (-not $NoShortcut) {
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $startMenu 'Nexmem.lnk'))
    $shortcut.TargetPath = $installedExe
    $shortcut.WorkingDirectory = $InstallDir
    $shortcut.IconLocation = "$installedExe,0"
    $shortcut.Description = 'Nexmem 去中心化即时通讯'
    $shortcut.Save()
    Write-Output "SHORTCUT=$(Join-Path $startMenu 'Nexmem.lnk')"
}

Write-Output "INSTALL_DIR=$InstallDir"
Write-Output "INSTALL_EXE=$installedExe"
Write-Output 'RESULT=PASS'
