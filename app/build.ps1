# PowerShell 一键编译魅族冻结助手（无需 Android Studio / Gradle）
# 依赖：JDK 17+、android.jar（platform 35）、build-tools（aapt2/d8/zipalign/apksigner）
param(
    [string]$SdkRoot = 'C:\Users\DINGJINJIN\Downloads\Compressed\_android_sdk',
    [string]$Jdk     = 'C:\Users\DINGJINJIN\Downloads\Compressed\tools\jdk-21.0.13+9',
    [string]$VersionName = '2.4',
    [int]$VersionCode = 14,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$proj = $PSScriptRoot
$bt   = Join-Path $SdkRoot 'android-15'
$jar  = Join-Path $SdkRoot 'android-35\android.jar'
$build = Join-Path $proj 'build'

foreach ($p in @($bt, $jar, (Join-Path $Jdk 'bin\javac.exe'))) {
    if (-not (Test-Path $p)) { throw "缺少依赖: $p" }
}

$env:JAVA_HOME = $Jdk
$env:PATH = "$Jdk\bin;$env:PATH"
New-Item -ItemType Directory -Force -Path "$build\gen","$build\classes","$build\dex" | Out-Null

Write-Host '[1/6] 编译资源'
& "$bt\aapt2.exe" compile --dir "$proj\res" -o "$build\res.zip"

Write-Host '[2/6] 链接 APK（含 assets）'
& "$bt\aapt2.exe" link -I $jar --manifest "$proj\AndroidManifest.xml" `
    -o "$build\app-unsigned.apk" --java "$build\gen" `
    --min-sdk-version 29 --target-sdk-version 35 `
    --version-code $VersionCode --version-name $VersionName `
    -A "$proj\assets" "$build\res.zip"

Write-Host '[3/6] javac'
$srcs = Get-ChildItem "$proj\src","$build\gen" -Recurse -Filter '*.java' | Select-Object -ExpandProperty FullName
& "$Jdk\bin\javac.exe" -source 8 -target 8 -nowarn -classpath $jar -d "$build\classes" $srcs

Write-Host '[4/6] d8 生成 classes.dex'
Remove-Item "$build\dex\*" -Force -ErrorAction SilentlyContinue
& "$bt\d8.bat" --lib $jar --min-api 29 --output "$build\dex" `
    (Get-ChildItem "$build\classes" -Recurse -Filter '*.class' | Select-Object -ExpandProperty FullName)

Write-Host '[5/6] 打包 dex'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$apk = "$build\app-unsigned.apk"
$zip = [System.IO.Compression.ZipFile]::Open($apk, 'Update')
$e = $zip.GetEntry('classes.dex'); if ($e) { $e.Delete() }
[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
    $zip, "$build\dex\classes.dex", 'classes.dex',
    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
$zip.Dispose()

Write-Host '[6/6] zipalign + 签名'
if (-not (Test-Path "$proj\debug.keystore")) {
    & "$Jdk\bin\keytool.exe" -genkeypair -keystore "$proj\debug.keystore" -alias androiddebugkey `
        -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10000 `
        -dname "CN=Android Debug,O=Android,C=US"
}
& "$bt\zipalign.exe" -f 4 $apk "$build\app-aligned.apk"
& "$bt\apksigner.bat" sign --ks "$proj\debug.keystore" --ks-pass pass:android --key-pass pass:android `
    --out "$build\meizu-freezer.apk" "$build\app-aligned.apk"

Write-Host "完成: $build\meizu-freezer.apk"

if ($Install) {
    $adb = 'C:\Users\DINGJINJIN\Downloads\Compressed\展讯公钥签名解锁BL_by酷安@某贼_2025.1.20-1\bin\adb.exe'
    & $adb install -r "$build\meizu-freezer.apk"
}
