# Phase B: write patched (re-signed) SPL, restore stock uboot, wipe userdata, reboot.
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$bk      = 'C:\Users\DINGJINJIN\Downloads\Compressed\_backup'

# prepare the patched SPL under the name the flow expects
$patched = Join-Path $dump '_spltest\splloader.bin'   # 1-arg gen_spl-unlock output (67.8KB)
if (-not (Test-Path $patched)) { "ABORT: patched spl missing"; exit 9 }
Copy-Item $patched (Join-Path $tool 'u-boot-spl-16k-sign.bin') -Force

foreach ($f in @("$tool\u-boot-spl-16k-sign.bin", "$bk\uboot_a.bin")) {
    if (-not (Test-Path $f)) { "ABORT: missing $f"; exit 9 }
    "{0,-42} {1,10} bytes" -f (Split-Path $f -Leaf), (Get-Item $f).Length
}

# wait for the BROM port (SPL is erased, so the device lands in BROM by itself)
$end = (Get-Date).AddSeconds(180); $ok = $false
while ((Get-Date) -lt $end) {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { $ok = $true; break }
    Start-Sleep -Milliseconds 150
}
if (-not $ok) { "NO PORT - device not in BROM"; exit 8 }

Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
    ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }

$log = Join-Path $dump 'phaseB.log'
Set-Location $tool
"--- phase B $(Get-Date -Format HH:mm:ss) ---"
& '.\spd_dump.exe' --wait 180 --reconnect --verbose 1 `
    exec_addr2 0x65017f08 `
    fdl fdl1-dl.bin 0x65000800 `
    fdl fdl2-dl.bin 0xbefffe00 `
    exec w splloader u-boot-spl-16k-sign.bin `
    w uboot_a "$bk\uboot_a.bin" `
    e userdata reset *>&1 | Out-File -FilePath $log -Encoding utf8

"exit=$LASTEXITCODE"
Get-Content $log -Tail 30 -ErrorAction SilentlyContinue | Out-String
