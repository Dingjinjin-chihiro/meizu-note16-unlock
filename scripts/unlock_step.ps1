param([string]$mode = 'flash_cboot')

$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$bk      = 'C:\Users\DINGJINJIN\Downloads\Compressed\_backup'
$log     = Join-Path $dump ("unlock_$mode.log")

function Get-SprdPort {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { return (($p | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') }
    return $null
}

$deadline = (Get-Date).AddMinutes(10)
$done = $false

for ($attempt = 1; $attempt -le 5 -and -not $done; $attempt++) {

    $port = $null
    while ((Get-Date) -lt $deadline) {
        $port = Get-SprdPort
        if ($port) { break }
        Start-Sleep -Milliseconds 120
    }
    if (-not $port) { "NO PORT WITHIN WINDOW"; break }

    "=== $mode attempt $attempt  port: $port  $(Get-Date -Format HH:mm:ss) ==="

    Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
        ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }

    switch ($mode) {
        'flash_cboot' {
            $sp = @('--wait','20','--reconnect','--verbose','1',
                    'exec_addr2','0x65017f08',
                    'fdl','fdl1-dl.bin','0x65000800',
                    'fdl','fdl2-dl.bin','0xbefffe00',
                    'exec','w','uboot_a','fdl2-cboot.bin','reset')
        }
        'send_payload' {
            $sp = @('--wait','20','--reconnect','--verbose','1',
                    'exec_addr2','0x65017f08',
                    'fdl','spl-unlock.bin','0x65000800')
        }
        'verify_only' {
            $sp = @('--wait','20','--reconnect','--verbose','1',
                    'exec_addr2','0x65017f08',
                    'fdl','fdl1-dl.bin','0x65000800',
                    'fdl','fdl2-dl.bin','0xbefffe00',
                    'exec','path',$dump,
                    'read_part','miscdata','8192','64','miscdata_after.bin',
                    'reset')
        }
        'verify_restore' {
            $sp = @('--wait','20','--reconnect','--verbose','1',
                    'exec_addr2','0x65017f08',
                    'fdl','fdl1-dl.bin','0x65000800',
                    'fdl','fdl2-dl.bin','0xbefffe00',
                    'exec','path',$dump,
                    'read_part','miscdata','8192','64','miscdata_after.bin',
                    'w','uboot_a',"$bk\uboot_a.bin",'reset')
        }
        default { "unknown mode"; exit 2 }
    }

    Set-Location $tool
    & '.\spd_dump.exe' @sp *>&1 | Out-File -FilePath $log -Append -Encoding utf8
    $code = $LASTEXITCODE
    "attempt $attempt exit=$code"

    $tail = Get-Content $log -Tail 40 -ErrorAction SilentlyContinue | Out-String

    if ($mode -eq 'flash_cboot') {
        if ($tail -match 'Write Part Done|Finished|reset') { $done = $true }
    } elseif ($mode -eq 'send_payload') {
        # "device removed" after sending the payload is the expected SUCCESS signal
        if ($tail -match 'device removed|Successfully connected') { $done = $true }
    } else {
        if (Test-Path (Join-Path $dump 'miscdata_after.bin')) { $done = $true }
    }
    if (-not $done) { Start-Sleep -Seconds 3 }
}

"=== RESULT $mode : $(if($done){'OK'}else{'FAILED'}) ==="
Get-Content $log -Tail 25 -ErrorAction SilentlyContinue | Out-String
