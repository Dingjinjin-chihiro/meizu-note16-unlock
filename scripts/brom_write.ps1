param(
    [string]$part = 'init_boot_a',
    [string]$file = 'C:\Users\DINGJINJIN\Downloads\Compressed\_patched\init_boot_patched.img'
)
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$dump    = 'C:\Users\DINGJINJIN\Downloads\Compressed\_dump'
$log     = Join-Path $dump "bromwrite_$part.log"

if (-not (Test-Path $file)) { "ABORT: $file missing"; exit 9 }
"写入源: $file ($((Get-Item $file).Length) 字节) -> 分区 $part"

$deadline = (Get-Date).AddMinutes(10)
$done = $false
for ($attempt = 1; $attempt -le 4 -and -not $done; $attempt++) {
    $port = $null
    while ((Get-Date) -lt $deadline) {
        $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
             Where-Object { $_.Name -notmatch '^PS' }
        if ($p) { $port = $true; break }
        Start-Sleep -Milliseconds 120
    }
    if (-not $port) { "NO PORT"; break }

    Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
        ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }

    "=== attempt $attempt $(Get-Date -Format HH:mm:ss) ==="
    Set-Location $tool
    & '.\spd_dump.exe' --wait 120 --reconnect --verbose 1 `
        exec_addr2 0x65017f08 `
        fdl fdl1-dl.bin 0x65000800 `
        fdl fdl2-dl.bin 0xbefffe00 `
        exec w $part $file reset *>&1 | Out-File -FilePath $log -Append -Encoding utf8

    $tail = Get-Content $log -Tail 60 -ErrorAction SilentlyContinue | Out-String
    if ($tail -match 'Write Part Done') { $done = $true }
    "attempt $attempt exit=$LASTEXITCODE  done=$done"
    Get-Content $log -Tail 8 -ErrorAction SilentlyContinue | Out-String
    if (-not $done) { Start-Sleep -Seconds 3 }
}
"=== RESULT: $(if($done){'WRITE OK'}else{'WRITE FAILED'}) ==="
