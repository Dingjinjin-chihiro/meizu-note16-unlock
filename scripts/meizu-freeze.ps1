<#
.SYNOPSIS
    魅族 / Flyme 专用应用冻结工具（支持导入包名列表）

.DESCRIPTION
    通过 adb + root 调用 `pm disable-user` / `pm enable` 冻结和解冻应用。
    与「小黑屋」的冻结是同一机制，但不依赖任何第三方 App，可批量、可导入列表、可回滚。

    设计原则：
      - 只冻结，不卸载（随时可解冻，不破坏系统完整性）
      - 内置保护名单，绝不冻结桌面 / 系统界面 / 电话 / 短信 / 输入法 等关键组件
      - 每次操作自动生成反向脚本，出问题一条命令回滚
      - 支持 DryRun 预演

.PARAMETER Action
    freeze   冻结列表里的应用
    unfreeze 解冻列表里的应用
    status   查看列表里应用的当前状态
    export   把设备上当前所有「已冻结」应用导出成列表文件

.PARAMETER List
    包名列表文件（每行一个，`#` 开头为注释，空行忽略）。
    行内可有空格和行尾备注，取第一个 token 作为包名。

.PARAMETER DryRun
    只打印将要执行的操作，不实际修改。

.PARAMETER OnlyMeizu
    只处理 com.meizu.* / com.flyme.* 的包，忽略其它。

.PARAMETER Force
    跳过保护名单检查（危险，不建议）。

.EXAMPLE
    .\meizu-freeze.ps1 -Action freeze -List .\debloat.txt -DryRun

.EXAMPLE
    .\meizu-freeze.ps1 -Action freeze -List .\debloat.txt

.EXAMPLE
    .\meizu-freeze.ps1 -Action export -List .\current-frozen.txt

.EXAMPLE
    .\meizu-freeze.ps1 -Action status -List .\debloat.txt
#>
[CmdletBinding()]
param(
    [ValidateSet('freeze', 'unfreeze', 'status', 'export')]
    [string]$Action = 'status',

    [string]$List = '',

    [string]$Adb = 'C:\Users\DINGJINJIN\Downloads\Compressed\展讯公钥签名解锁BL_by酷安@某贼_2025.1.20-1\bin\adb.exe',

    [string]$LogDir = 'C:\Users\DINGJINJIN\Downloads\Compressed\_freeze_logs',

    [switch]$DryRun,
    [switch]$OnlyMeizu,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ---------- 保护名单：任何情况下都不冻结 ----------
$PROTECT = @(
    'android',
    'com.android.systemui',
    'com.android.settings',
    'com.android.providers.settings',
    'com.android.shell',
    'com.android.phone',
    'com.android.phone.injection',
    'com.android.server.telecom',
    'com.android.providers.telephony',
    'com.android.providers.contacts',
    'com.android.providers.media',
    'com.android.providers.media.module',
    'com.android.permissioncontroller',
    'com.android.packageinstaller',
    'com.android.webview',
    'com.google.android.webview',
    'com.android.bluetooth',
    'com.android.nfc',
    'com.android.networkstack',
    'com.android.networkstack.tethering',
    'com.android.providers.downloads',
    'com.android.externalstorage',
    'com.android.documentsui',
    'com.android.intentresolver',
    'com.android.keychain',
    'com.android.certinstaller',
    'com.android.location.fused',
    'com.android.inputdevices',
    'com.android.se',
    'com.android.role.notes.enabled',
    'com.android.carrierconfig',
    'com.android.dialer',
    'com.android.mms',
    'com.android.mms.service',
    'com.android.incallui',
    'com.android.ons',
    'com.android.providers.blockednumber',
    'com.android.providers.userdictionary',
    'com.spreadtrum.ims',
    'com.spreadtrum.sgps',
    'com.android.unisoc.telephony.server',
    'com.unisoc.phone',
    'com.meizu.flyme.launcher',
    'com.sohu.inputmethod.sogou.meizu',
    'me.weishu.kernelsu',
    'web1n.stopapp'
)

# 资源 / overlay 类：冻结后容易出现隐性故障
$PROTECT_RE = '^(android\.|com\.android\.internal\.|com\.android\.theme\.|.*\.overlay|com\.android\.wifi\.|com\.android\.connectivity\.resources|com\.android\.unisoc\.|com\.genext\.|com\.unisoc\.)'

# ---------- 工具函数 ----------
function Assert-Adb {
    if (-not (Test-Path $Adb)) { throw "找不到 adb: $Adb" }
    $d = & $Adb devices 2>&1 | Out-String
    if ($d -notmatch '\sdevice\s') { throw '设备未连接或未授权。请检查 USB 调试。' }
}

function Get-InstalledPackages {
    (& $Adb shell 'pm list packages' 2>&1) |
        ForEach-Object { $_ -replace '^package:', '' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}

function Get-DisabledPackages {
    (& $Adb shell 'pm list packages -d' 2>&1) |
        ForEach-Object { $_ -replace '^package:', '' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
}

function Read-PackageList {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "列表文件不存在: $Path" }
    $out = @()
    foreach ($line in Get-Content $Path -Encoding UTF8) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t.StartsWith('#')) { continue }
        # 取第一个 token 作为包名，其余当作备注
        $pkg = ($t -split '\s+')[0]
        if ($pkg -match '^[a-zA-Z][\w\.]*$') { $out += $pkg }
    }
    return ($out | Select-Object -Unique)
}

function Test-Protected {
    param([string]$Pkg)
    if ($Force) { return $false }
    if ($PROTECT -contains $Pkg) { return $true }
    if ($Pkg -match $PROTECT_RE) { return $true }
    return $false
}

function New-LogPath {
    param([string]$Kind)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    return (Join-Path $LogDir "$Kind`_$stamp.txt")
}

# ---------- 主流程 ----------
Assert-Adb

switch ($Action) {

    'export' {
        if (-not $List) { $List = Join-Path (Get-Location) 'frozen-export.txt' }
        $disabled = Get-DisabledPackages | Sort-Object
        $header = @(
            "# 魅族 Note 16 已冻结应用列表",
            "# 导出时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "# 共 $($disabled.Count) 个，可直接用于 -Action unfreeze",
            ""
        )
        ($header + $disabled) | Set-Content -Path $List -Encoding UTF8
        Write-Host "已导出 $($disabled.Count) 个已冻结应用到: $List" -ForegroundColor Green
        break
    }

    'status' {
        if (-not $List) { throw '-Action status 需要 -List' }
        $pkgs = Read-PackageList $List
        $installed = Get-InstalledPackages
        $disabled = Get-DisabledPackages
        $rows = foreach ($p in $pkgs) {
            $state = if ($installed -notcontains $p) { '未安装' }
                     elseif ($disabled -contains $p) { '已冻结' }
                     else { '启用中' }
            [pscustomobject]@{ Package = $p; State = $state }
        }
        $rows | Format-Table -AutoSize | Out-String | Write-Host
        $rows | Group-Object State | ForEach-Object { "{0,-8} {1}" -f $_.Name, $_.Count } | Write-Host
        break
    }

    'freeze' {
        if (-not $List) { throw '-Action freeze 需要 -List' }
        $pkgs = Read-PackageList $List
        if ($OnlyMeizu) {
            $pkgs = $pkgs | Where-Object { $_ -match '^com\.(meizu|flyme)\.' }
        }
        $installed = Get-InstalledPackages
        $already = Get-DisabledPackages

        $log = New-LogPath 'freeze'
        $inverse = [System.IO.Path]::ChangeExtension($log, $null) + '_unfreeze.ps1'
        "# 反向操作：解冻 $log 中冻结的应用" | Set-Content $inverse -Encoding UTF8

        $ok = 0; $skipProt = 0; $skipMissing = 0; $skipFrozen = 0; $fail = @()
        foreach ($p in $pkgs) {
            if (Test-Protected $p) {
                Write-Host "  跳过（保护名单）: $p" -ForegroundColor DarkYellow
                $skipProt++; continue
            }
            if ($installed -notcontains $p) {
                Write-Host "  跳过（未安装）: $p" -ForegroundColor DarkGray
                $skipMissing++; continue
            }
            if ($already -contains $p) {
                $skipFrozen++; continue
            }
            if ($DryRun) {
                Write-Host "  [dry-run] 冻结 $p" -ForegroundColor Cyan
                $ok++; continue
            }
            $r = (& $Adb shell "pm disable-user --user 0 $p" 2>&1 | Out-String).Trim()
            if ($r -match 'new state: disabled') {
                Write-Host "  ✅ $p" -ForegroundColor Green
                Add-Content -Path $log -Value $p -Encoding UTF8
                Add-Content -Path $inverse -Value "& `"$Adb`" shell `"pm enable $p`"" -Encoding UTF8
                $ok++
            } else {
                Write-Host "  ❌ $p -> $r" -ForegroundColor Red
                $fail += $p
            }
        }

        Write-Host ""
        Write-Host "冻结成功:   $ok" -ForegroundColor Green
        Write-Host "已在冻结中: $skipFrozen"
        Write-Host "保护名单跳过: $skipProt"
        Write-Host "未安装:     $skipMissing"
        Write-Host "失败:       $($fail.Count)"
        if (-not $DryRun -and $ok -gt 0) {
            Write-Host "日志:       $log"
            Write-Host "一键回滚:   $inverse" -ForegroundColor Yellow
        }
        break
    }

    'unfreeze' {
        if (-not $List) { throw '-Action unfreeze 需要 -List' }
        $pkgs = Read-PackageList $List
        $installed = Get-InstalledPackages
        $disabled = Get-DisabledPackages

        $log = New-LogPath 'unfreeze'
        $ok = 0; $skip = 0; $fail = @()
        foreach ($p in $pkgs) {
            if ($installed -notcontains $p) { $skip++; continue }
            if ($disabled -notcontains $p) { $skip++; continue }
            if ($DryRun) {
                Write-Host "  [dry-run] 解冻 $p" -ForegroundColor Cyan
                $ok++; continue
            }
            $r = (& $Adb shell "pm enable $p" 2>&1 | Out-String).Trim()
            if ($r -match 'new state: enabled') {
                Write-Host "  ✅ $p" -ForegroundColor Green
                Add-Content -Path $log -Value $p -Encoding UTF8
                $ok++
            } else {
                Write-Host "  ❌ $p -> $r" -ForegroundColor Red
                $fail += $p
            }
        }
        Write-Host ""
        Write-Host "解冻成功: $ok" -ForegroundColor Green
        Write-Host "跳过（未安装或未冻结）: $skip"
        Write-Host "失败: $($fail.Count)"
        break
    }
}
