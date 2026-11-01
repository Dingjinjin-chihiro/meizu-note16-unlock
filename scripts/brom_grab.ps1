# Resilient BROM catcher: grab the port the instant it appears, retry up to 6 times.
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$log     = Join-Path $dump 'session4.log'

function Get-SprdPort {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { return (($p | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') }
    return $null
}

$deadline = (Get-Date).AddMinutes(12)
$attempt  = 0
$maxTry   = 6

while ((Get-Date) -lt $deadline -and $attempt -lt $maxTry) {

    $port = $null
    while ((Get-Date) -lt $deadline) {
        $port = Get-SprdPort
        if ($port) { break }
        Start-Sleep -Milliseconds 120
    }
    if (-not $port) { "NO PORT WITHIN WINDOW"; break }

    $attempt++
    "=== attempt $attempt  port: $port ==="

    Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
        ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }

    Set-Location $tool
    & '.\spd_dump.exe' --wait 10 --reconnect --verbose 2 `
        exec_addr2 0x65017f08 `
        fdl fdl1-dl.bin 0x65000800 `
        fdl fdl2-dl.bin 0xbefffe00 `
        exec path $dump `
        read_part splloader 0 0x40000 splloader.bin `
        read_part uboot_a 0 0x300000 uboot_a.bin `
        read_part miscdata 8192 64 miscdata_8k.bin `
        reset *>&1 | Out-File -FilePath $log -Append -Encoding utf8

    "attempt $attempt exit=$LASTEXITCODE"

    if ((Test-Path (Join-Path $dump 'splloader.bin')) -and (Test-Path (Join-Path $dump 'uboot_a.bin'))) {
        "READ OK - files captured"
        break
    }
    Start-Sleep -Seconds 2
}

"--- files ---"
Get-ChildItem $dump | Select-Object Name, Length | Format-Table -AutoSize | Out-String
"--- log tail ---"
Get-Content $log -Tail 12 -ErrorAction SilentlyContinue | Out-String
