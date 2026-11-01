# Phase A of the documented Note16 unlock flow, with correct A/B partition names.
# 1) backup + erase splloader   2) flash cboot   3) send payload   4) read lock record
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$bk      = 'C:\Users\DINGJINJIN\Downloads\Compressed\_backup'

# safety gate
foreach ($f in @("$bk\splloader.bin", "$bk\uboot_a.bin")) {
    if (-not (Test-Path $f)) { "ABORT: missing backup $f"; exit 9 }
}

function Get-SprdPort {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { return $true }
    return $false
}

function Wait-Port([int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        if (Get-SprdPort) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Run-Step([string]$name, [string[]]$sp) {
    if (-not (Wait-Port 180)) { "[$name] NO PORT"; return $false }
    Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
        ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }
    $log = Join-Path $dump "phaseA_$name.log"
    Set-Location $tool
    "--- [$name] $(Get-Date -Format HH:mm:ss) ---"
    & '.\spd_dump.exe' @sp *>&1 | Out-File -FilePath $log -Encoding utf8
    $code = $LASTEXITCODE
    $tail = Get-Content $log -Tail 12 -ErrorAction SilentlyContinue | Out-String
    "[$name] exit=$code"
    $tail
    return $true
}

# ---- step 1: backup + erase splloader (device will fall into BROM after reset) ----
Run-Step 'erase_spl' @('--wait','180','--reconnect','--verbose','1',
    'exec_addr2','0x65017f08',
    'fdl','fdl1-dl.bin','0x65000800',
    'fdl','fdl2-dl.bin','0xbefffe00',
    'exec','r','splloader','r','uboot_a','e','splloader','reset') | Out-Null

Start-Sleep -Seconds 8

# ---- step 2: flash patched cboot ----
Run-Step 'flash_cboot' @('--wait','180','--reconnect','--verbose','1',
    'exec_addr2','0x65017f08',
    'fdl','fdl1-dl.bin','0x65000800',
    'fdl','fdl2-dl.bin','0xbefffe00',
    'exec','w','uboot_a','fdl2-cboot.bin','reset') | Out-Null

Start-Sleep -Seconds 12

# ---- step 3: payload ----
Run-Step 'payload' @('--wait','180','--reconnect','--verbose','1',
    'exec_addr2','0x65017f08',
    'fdl','spl-unlock.bin','0x65000800') | Out-Null

Start-Sleep -Seconds 10

# ---- step 4: read lock record ----
Remove-Item (Join-Path $dump 'miscdata2.bin') -Force -ErrorAction SilentlyContinue
Run-Step 'verify' @('--wait','180','--reconnect','--verbose','1',
    'exec_addr2','0x65017f08',
    'fdl','fdl1-dl.bin','0x65000800',
    'fdl','fdl2-dl.bin','0xbefffe00',
    'exec','path',$dump,
    'read_part','miscdata','8192','64','miscdata2.bin','reset') | Out-Null

"=== PHASE A DONE ==="
$p = Join-Path $dump 'miscdata2.bin'
if (Test-Path $p) {
    $b = [System.IO.File]::ReadAllBytes($p)
    "miscdata2 非零字节数: " + ($b | Where-Object { $_ -ne 0 }).Count
    "HEX: " + (($b | ForEach-Object { $_.ToString('x2') }) -join ' ')
} else { "miscdata2 未生成" }
