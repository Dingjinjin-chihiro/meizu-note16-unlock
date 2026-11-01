# Wait for SPRD BROM port, settle, then read key partitions (read-only).
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$log     = Join-Path $dump 'session2.log'

$deadline = (Get-Date).AddMinutes(7)
$found = $null
while ((Get-Date) -lt $deadline) {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { $found = ($p | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','; break }
    Start-Sleep -Milliseconds 150
}
if (-not $found) { "PORT NEVER APPEARED (7 min)"; exit 2 }

"port appeared: $found -- connecting immediately"
''

Set-Location $tool
& '.\spd_dump.exe' --wait 25 --reconnect --verbose 1 `
    exec_addr2 0x65017f08 `
    fdl fdl1-dl.bin 0x65000800 `
    fdl fdl2-dl.bin 0xbefffe00 `
    exec path $dump `
    read_part splloader 0 0x40000 splloader.bin `
    read_part uboot_a 0 0x300000 uboot_a.bin `
    read_part miscdata 8192 64 miscdata_8k.bin `
    read_part proinfo 0 0x10000 proinfo.bin `
    reset *>&1 | Out-File -FilePath $log -Encoding utf8

"exit=$LASTEXITCODE"
Get-Content $log -Tail 20 | Out-String


