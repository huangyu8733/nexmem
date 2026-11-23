# 汇总 P0 测量 CSV，输出门禁所需指标（直连率、兜底可达率、P95）。
# 用法：pwsh -File tools/p0/summarize.ps1 -Paths data\p0\home.csv,data\p0\lte.csv
param(
    [Parameter(Mandatory = $true)]
    [string]$Paths,

    [string]$Out = ""
)

$ErrorActionPreference = "Stop"

function Get-P95 {
    param([double[]]$Values)
    $v = @($Values | Where-Object { $_ -ge 0 } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $idx = [Math]::Ceiling(0.95 * $v.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return $v[$idx]
}

$all = @()
foreach ($path in ($Paths -split ',')) {
    $path = $path.Trim().Trim("'").Trim('"')
    if (-not $path) { continue }
    $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
    if (-not $resolved) { Write-Warning "跳过不存在的文件: $path"; continue }

    foreach ($row in (Import-Csv $resolved.Path)) {
        $all += [pscustomobject]@{
            Scenario  = $row.scenario
            Success   = $row.success -eq "true"
            Direct    = $row.direct -eq "true"
            Relayed   = $row.relayed -eq "true"
            ConnectMS = [double]$row.connect_ms
            RTTMS     = [double]$row.rtt_ms
            Error     = $row.error
        }
    }
}

if ($all.Count -eq 0) { throw "没有可用样本" }

$rows = @()
$groups = $all | Group-Object Scenario | Sort-Object Name
foreach ($g in $groups) {
    $n = $g.Count
    $ok = @($g.Group | Where-Object Success).Count
    $direct = @($g.Group | Where-Object { $_.Success -and $_.Direct }).Count
    $relayed = @($g.Group | Where-Object { $_.Success -and $_.Relayed }).Count
    $reachable = $direct + $relayed
    $rows += [pscustomobject]@{
        场景         = $g.Name
        样本         = $n
        成功         = $ok
        直连率       = "{0:P1}" -f ($direct / $n)
        兜底可达率   = "{0:P1}" -f ($reachable / $n)
        中继占比     = "{0:P1}" -f ($relayed / [Math]::Max($ok, 1))
        直连P95ms    = (Get-P95 @($g.Group | Where-Object { $_.Success -and $_.Direct } | ForEach-Object ConnectMS))
        中继P95ms    = (Get-P95 @($g.Group | Where-Object { $_.Success -and $_.Relayed } | ForEach-Object ConnectMS))
        RTT_P95ms    = (Get-P95 @($g.Group | Where-Object { $_.Success } | ForEach-Object RTTMS))
    }
}

$rows | Format-Table -AutoSize

$total = $all.Count
$okAll = @($all | Where-Object Success).Count
$directAll = @($all | Where-Object { $_.Success -and $_.Direct }).Count
$relayAll = @($all | Where-Object { $_.Success -and $_.Relayed }).Count
Write-Host ""
Write-Host ("总计: {0} 样本, 成功 {1}, 直连率 {2:P1}, 兜底可达率 {3:P1}" -f `
    $total, $okAll, ($directAll / $total), (($directAll + $relayAll) / $total))

Write-Host "门禁阈值: 直连率 >=60%, 兜底可达率 >=95%, 直连 P95 <3000ms, 中继 P95 <6000ms"

if ($Out) {
    $lines = @("# P0 汇总", "", ($rows | Format-Table -AutoSize | Out-String))
    Set-Content -Path $Out -Value ($lines -join "`n") -Encoding UTF8
    Write-Host "已写入: $Out"
}
