<#
.SYNOPSIS
    分片恢复 Android super 分区（绕过 fastbootd 的 ~70 秒写入会话超时）。

.DESCRIPTION
    fastbootd 单次 flash 会话约 70 秒后会返回 Invalid argument，
    10 GiB 的 super 无法一次写完。本脚本用 Android sparse 的
    DONT_CARE 块跳过已写区间，每次会话只搬运 WindowMB 数据，
    分多次把整个 super 写回。

    设备入口支持：
      - adb device / recovery  → adb reboot fastboot
      - bootloader fastboot    → fastboot reboot fastboot
      - 已在 fastbootd         → 直接开始

.PARAMETER Backup
    包含 super.bin / vbmeta_a.bin / vbmeta_system_a.bin 的目录。

.PARAMETER WindowMB
    每次会话写入的兆字节数。默认 1200。失败会自动缩窗重试。

.PARAMETER From
    从指定字节偏移开始（续写用）。默认 0。

.PARAMETER MaxSlices
    最多写几片（0 = 写完）。测试用。

.PARAMETER SkipVbmeta
    跳过 vbmeta 还原（默认会先还原原厂 vbmeta）。

.PARAMETER DryRun
    只检查环境、生成首片、不刷写。

.EXAMPLE
    .\restore-super.ps1 -Backup C:\backup

.EXAMPLE
    .\restore-super.ps1 -DryRun

.NOTES
    实测于 MEIZU Note 16 (M521Q / UMS9621S)，Flyme 12 / Android 15。
#>
[CmdletBinding()]
param(
    [string]$Backup = 'C:\Users\DINGJINJIN\Downloads\Compressed\_backup',
    [string]$Bin    = 'C:\Users\DINGJINJIN\Downloads\Compressed\展讯公钥签名解锁BL_by酷安@某贼_2025.1.20-1\bin',
    [string]$Work   = 'C:\Users\DINGJINJIN\Downloads\Compressed\_restore_work',
    [int]$WindowMB  = 1200,
    [int64]$From    = 0,
    [int]$MaxSlices = 0,
    [int]$WaitSeconds = 300,
    [switch]$SkipVbmeta,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$BLK = 4096
$SPARSE_MAGIC = [Convert]::ToUInt32('ED26FF3A', 16)   # 不能写成 0xED26FF3A，PowerShell 会解析成负的 Int32
$CHUNK_RAW = 0xCAC1
$CHUNK_DONTCARE = 0xCAC3
$MAX_CHUNK_BLKS = 256          # 每块 1 MiB

$fb  = Join-Path $Bin 'fastboot.exe'
$adb = Join-Path $Bin 'adb.exe'
$superImg = Join-Path $Backup 'super.bin'
$logFile  = Join-Path $Work 'restore-super.log'

New-Item -ItemType Directory -Force -Path $Work | Out-Null
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding utf8
}

# ---------- 前置检查 ----------
if (-not (Test-Path $fb))  { throw "找不到 fastboot: $fb" }
if (-not (Test-Path $superImg)) { throw "找不到 super.bin: $superImg" }
$TOTAL = (Get-Item $superImg).Length
if ($TOTAL % $BLK -ne 0) { throw "super.bin 大小未按 4096 对齐: $TOTAL" }
Log ("super.bin: {0:N0} 字节 ({1:N2} GiB)" -f $TOTAL, ($TOTAL / 1GB))
Set-Content -Path $logFile -Value "=== restore-super 启动 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -Encoding utf8

# ---------- sparse 分片生成 ----------
function New-SparseSlice {
    param([string]$SourcePath, [string]$DestPath, [int64]$Start, [int64]$End, [int64]$Total)
    $startBlk = [int64]($Start / $BLK)
    $endBlk   = [int64]($End / $BLK)
    $totalBlk = [int64]($Total / $BLK)

    $chunks = New-Object System.Collections.ArrayList
    if ($startBlk -gt 0) { [void]$chunks.Add(@($CHUNK_DONTCARE, $startBlk)) }
    $n = $endBlk - $startBlk
    while ($n -gt 0) {
        $c = [Math]::Min([int64]$MAX_CHUNK_BLKS, $n)
        [void]$chunks.Add(@($CHUNK_RAW, $c))
        $n -= $c
    }
    if ($endBlk -lt $totalBlk) { [void]$chunks.Add(@($CHUNK_DONTCARE, $totalBlk - $endBlk)) }

    $src = [System.IO.File]::OpenRead($SourcePath)
    $dst = [System.IO.File]::Create($DestPath)
    $bw  = New-Object System.IO.BinaryWriter($dst)
    try {
        $bw.Write([uint32]$SPARSE_MAGIC)
        $bw.Write([uint16]1)      # major
        $bw.Write([uint16]0)      # minor
        $bw.Write([uint16]28)     # file_hdr_sz
        $bw.Write([uint16]12)     # chunk_hdr_sz
        $bw.Write([uint32]$BLK)
        $bw.Write([uint32]$totalBlk)
        $bw.Write([uint32]$chunks.Count)
        $bw.Write([uint32]0)      # checksum

        $src.Seek($startBlk * $BLK, 'Begin') | Out-Null
        $buf = New-Object byte[] ($MAX_CHUNK_BLKS * $BLK)
        foreach ($ch in $chunks) {
            $type = $ch[0]; $sz = [int64]$ch[1]
            if ($type -eq $CHUNK_DONTCARE) {
                $bw.Write([uint16]$CHUNK_DONTCARE); $bw.Write([uint16]0)
                $bw.Write([uint32]$sz); $bw.Write([uint32]12)
            } else {
                $bytes = $sz * $BLK
                $bw.Write([uint16]$CHUNK_RAW); $bw.Write([uint16]0)
                $bw.Write([uint32]$sz); $bw.Write([uint32](12 + $bytes))
                $remain = $bytes
                while ($remain -gt 0) {
                    $want = [Math]::Min([int64]$buf.Length, $remain)
                    $read = $src.Read($buf, 0, [int]$want)
                    if ($read -le 0) { throw '源文件读取不足' }
                    $bw.Write($buf, 0, $read)
                    $remain -= $read
                }
            }
        }
    } finally {
        $bw.Flush(); $bw.Dispose(); $dst.Dispose(); $src.Dispose()
    }
    return (Get-Item $DestPath).Length
}

# ---------- 设备发现 ----------
function Get-DeviceMode {
    $f = & $fb devices 2>&1 | Out-String
    if ($f -match 'fastboot') {
        $u = & $fb getvar is-userspace 2>&1 | Out-String
        if ($u -match 'yes') { return 'fastbootd' } else { return 'bootloader' }
    }
    $a = & $adb devices 2>&1 | Out-String
    if ($a -match 'recovery')    { return 'recovery' }
    if ($a -match '\sdevice\s')  { return 'android' }
    return $null
}

function Wait-Fastbootd {
    param([int]$Seconds = 120)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $m = Get-DeviceMode
        if ($m -eq 'fastbootd') { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------- 1. 找设备并进入 fastbootd ----------
Log "等待设备（最多 $WaitSeconds 秒）…"
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$mode = $null
while ((Get-Date) -lt $deadline) {
    $mode = Get-DeviceMode
    if ($mode) { break }
    Start-Sleep -Milliseconds 800
}
if (-not $mode) { throw '未检测到设备。请检查数据线并进入 fastboot / recovery。' }
Log "检测到设备，模式 = $mode"

switch ($mode) {
    'android'  { Log 'adb → 重启到 fastbootd'; & $adb reboot fastboot 2>&1 | Out-Null }
    'recovery' { Log 'recovery adb → 重启到 fastbootd'; & $adb reboot fastboot 2>&1 | Out-Null }
    'bootloader' { Log 'bootloader → 重启到 fastbootd'; & $fb reboot fastboot 2>&1 | Out-Null }
    'fastbootd' { Log '已处于 fastbootd' }
}

if ($mode -ne 'fastbootd') {
    if (-not (Wait-Fastbootd -Seconds 120)) {
        throw '未能进入 fastbootd。请尝试：先还原原厂 vbmeta，再从 recovery 执行 adb reboot fastboot。'
    }
}
Log 'fastbootd 就绪'

$psz = (& $fb getvar partition-size:super 2>&1 | Out-String)
Log ("分区: " + ($psz -replace "`r?`n", ' ').Trim())
if ($psz -match '0x([0-9a-fA-F]+)') {
    $partSize = [Convert]::ToInt64($Matches[1], 16)
    if ($partSize -ne $TOTAL) {
        throw "分区大小 0x$($Matches[1]) ($partSize) 与备份 $TOTAL 不一致"
    }
    Log '分区大小与备份一致'
}

# ---------- 2. 还原 vbmeta ----------
if (-not $SkipVbmeta) {
    foreach ($p in @('vbmeta_a', 'vbmeta_system_a')) {
        $img = Join-Path $Backup "$p.bin"
        if (-not (Test-Path $img)) { Log "跳过 $p（备份不存在）"; continue }
        if ($DryRun) { Log "[dry-run] 将还原 $p"; continue }
        $ok = $false
        for ($t = 1; $t -le 3; $t++) {
            $r = & $fb flash $p $img 2>&1 | Out-String
            if ($r -match 'Finished' -and $r -notmatch 'FAILED') { Log "还原 $p 成功"; $ok = $true; break }
            Log "  还原 $p 第 $t 次失败，重试"
            Start-Sleep -Seconds 2
        }
        if (-not $ok) { Log "警告：$p 还原失败（继续）" }
    }
}

# ---------- 3. 分片写回 super ----------
$slice = Join-Path $Work 'slice.simg'
$cur = [int64]$From
$window = [int64]$WindowMB * 1MB
$round = 0
$okCount = 0

while ($cur -lt $TOTAL) {
    if ($MaxSlices -gt 0 -and $round -ge $MaxSlices) { Log "达到 MaxSlices=$MaxSlices，停止"; break }
    $round++
    $end = [int64]$cur + $window
    if ($end -gt $TOTAL) { $end = $TOTAL }
    $end = [int64]([Math]::Floor($end / $BLK) * $BLK)

    $size = New-SparseSlice -SourcePath $superImg -DestPath $slice -Start $cur -End $end -Total $TOTAL
    Log ("片 {0}: {1:N0}..{2:N0}  ({3:N0} MB, 镜像 {4:N0} MB)" -f $round, $cur, $end, (($end - $cur) / 1MB), ($size / 1MB))

    if ($DryRun) { Log '[dry-run] 不刷写'; break }

    $t0 = Get-Date
    $r = & $fb flash super $slice 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sec = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 0)

    if ($code -eq 0) {
        Log ("  OK  {0}s" -f $sec)
        $cur = $end
        $okCount++
        if ($okCount -ge 5 -and $window -lt [int64]$WindowMB * 1MB) {
            $window = [int64]$WindowMB * 1MB
            Log '  连续成功，窗口恢复默认'
        }
    } else {
        $reason = ($r -split "`n" | Where-Object { $_ -match 'FAILED' } | Select-Object -First 1)
        Log ("  FAIL {0}s  {1}" -f $sec, ($reason -as [string]).Trim())
        $okCount = 0
        $window = [int64]([Math]::Floor($window * 0.6))
        if ($window -lt 128MB) { throw "窗口已缩到 $([Math]::Round($window/1MB,0)) MB 仍失败，中止" }
        Log ("  缩窗到 {0} MB 重试" -f [Math]::Round($window / 1MB, 0))
    }
}

# ---------- 4. 结果 ----------
$pct = if ($TOTAL -gt 0) { [Math]::Round($cur * 100.0 / $TOTAL, 2) } else { 0 }
Log ("完成度: {0:N0} / {1:N0} 字节 ({2}%)" -f $cur, $TOTAL, $pct)

if ($DryRun) {
    Log 'DryRun 结束'
    exit 0
}

if ($cur -ge $TOTAL) {
    Log 'super 写回完成'
    Log '重启设备…'
    & $fb reboot 2>&1 | Out-Null
    Log '等待系统启动（数据未动的设备约 40 秒；被擦过的设备需要走初始化向导）'
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $m = Get-DeviceMode
        if ($m -eq 'android' -or $m -eq 'recovery') { Log "设备已启动（$m）"; break }
    }
    exit 0
} else {
    Log "未写完，可加 -From $cur 继续"
    exit 1
}
