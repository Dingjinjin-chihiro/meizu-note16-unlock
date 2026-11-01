# Full read-only backup via BROM: r all (excludes userdata/cache/blackbox). Retries on link drop.
$ErrorActionPreference = 'Continue'
$regPath = 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM'
$tool    = 'C:\Users\DINGJINJIN\Downloads\Compressed\ums9621_Meizu_Note16'
$bk      = 'C:\Users\DINGJINJIN\Downloads\Compressed\_backup'
$log     = Join-Path $bk 'backup.log'
New-Item -ItemType Directory -Force -Path $bk | Out-Null

function Get-SprdPort {
    $p = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
         Where-Object { $_.Name -notmatch '^PS' }
    if ($p) { return (($p | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',') }
    return $null
}

$deadline = (Get-Date).AddMinutes(20)
$ok = $false

for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {

    $port = $null
    while ((Get-Date) -lt $deadline) {
        $port = Get-SprdPort
        if ($port) { break }
        Start-Sleep -Milliseconds 120
    }
    if (-not $port) { "NO PORT WITHIN WINDOW"; break }

    "=== backup attempt $attempt  port: $port  $(Get-Date -Format HH:mm:ss) ==="

    Get-Process | Where-Object { $_.ProcessName -match 'spd_dump' } |
        ForEach-Object { $_ | Stop-Process -Force -ErrorAction SilentlyContinue }

    # fresh start each attempt, avoid mixing partial files
    Get-ChildItem $bk -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Set-Location $tool
    & '.\spd_dump.exe' --wait 20 --reconnect --verbose 1 `
        exec_addr2 0x65017f08 `
        fdl fdl1-dl.bin 0x65000800 `
        fdl fdl2-dl.bin 0xbefffe00 `
        exec path $bk r all reset *>&1 | Out-File -FilePath $log -Append -Encoding utf8

    $sum = (Get-ChildItem $bk -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'backup.log' } |
            Measure-Object Length -Sum).Sum
    "attempt $attempt done: exit=$LASTEXITCODE  bytes=$sum  ($([math]::Round($sum/1GB,2)) GB)"

    if ($sum -gt 12GB) { $ok = $true }
    else { Start-Sleep -Seconds 3 }
}

"=== RESULT: $(if($ok){'BACKUP COMPLETE'}else{'INCOMPLETE'}) ==="
Get-ChildItem $bk -File | Sort-Object Length -Descending |
    Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} |
    Format-Table -AutoSize | Out-String
