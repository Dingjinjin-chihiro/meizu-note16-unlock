# 魅族冻结助手（自研 App）

> 版本：2.5　·　2026-11-01
> 包名：`io.github.dingjinjin.meizufreezer`
> APK：`app/release/meizu-freezer-2.5.apk`（24.6 KB）
> 源码：`app/`　构建脚本：`app/build.ps1`

---

## 一、为什么自己写

### 小黑屋（`web1n.stopapp`）是闭源的

查作者 GitHub `web1n`（142 个公开仓库），与小黑屋相关的只有：

| 仓库 | 内容 |
|---|---|
| `blackhouse-app-setup-command` | 一键激活脚本（Shell），不是 App 源码 |
| `Ice-Box-Docs` | 在线文档 |

**没有任何仓库是 `web1n.stopapp` 的源码。**

### 反编译分析（apktool + smali）

从设备拉出 APK（1.82 MB），apktool 反编译出 3119 个 smali 文件，定位到核心实现：

**`a10.smali` 的 `static String do(int mode, String pkg, boolean disable)`**

```java
if (mode == -1) {
    // root / adb 模式
    return "pm " + (disable ? "disable" : "enable") + " " + pkg;
} else {
    // 无 root 模式：直接 binder 调用 PackageManager
    return "service call package " + mode + " s16 " + pkg + " i32 " + (disable ? 3 : ...);
}
```

其它发现：

| 组件 | 用途 |
|---|---|
| `eu.chainfire.librootjava` + `RootDaemon` / `RootIPC` | root 通道，常驻 daemon 加速批量操作 |
| `com.web1n.stopapp.app_process.FastDisable` | `app_process` 方式跑 daemon |
| `libfreeze.so`（arm64/armv7/x86/x86_64） | 冻结相关 native 实现 |
| `rikka` / `Shizuku` | Shizuku 模式（免 root，adb 权限） |
| `DevicePolicyManager.setApplicationHidden` | 设备管理员模式 |
| `IPackageManager.setApplicationHiddenSettingAsUser` | 隐藏 API 模式 |
| `AppOpsProvider` | AppOps 相关 |

**结论：所有模式的最终效果都是让 PackageManager 把包标记为 disabled/hidden，
root 模式下就是一句 `pm disable`。** 所以自研完全可行，且不需要那套 daemon。

---

## 二、这个 App 的实现

### 架构：WebView + 原生桥

```
assets/index.html   ← 整个界面（HTML/CSS/JS，深色卡片 UI）
        ↕  @JavascriptInterface("Native")
MainActivity.java   ← 只提供能力：listApps / setFrozen / batch / applyList / exportFrozen
        ↓
su -c "pm disable-user --user 0 <pkg>" / "pm enable <pkg>"
```

界面用网页写的好处：热改样式、不用重启编译、绕开 ROM 的 View 渲染怪癖。

### 功能对照

| 功能 | 小黑屋 | 本 App |
|---|---|---|
| 列出全部应用（名称/包名/状态） | ✅ | ✅ |
| 单个冻结 / 解冻（开关） | ✅ | ✅ |
| 批量冻结 / 解冻（当前筛选列表） | ✅ | ✅ |
| **导入包名列表批量冻结** | ❌ | ✅ |
| 导出当前冻结列表 | 部分 | ✅ |
| 搜索过滤 | ✅ | ✅ |
| 按状态/系统/第三方筛选 | ✅ | ✅ |
| 定时冻结 / 自动冻结 | ✅ | ❌（待做） |
| Tasker / 快捷方式 | ✅ | ❌（待做） |
| Shizuku / 设备管理员免 root | ✅ | ❌（当前仅 root） |

### 安全边界

只保留 **4 个** 绝对不可冻结项（冻掉手机就没法操作）：

```
com.android.systemui                状态栏/导航
com.meizu.flyme.launcher            桌面
com.sohu.inputmethod.sogou.meizu    输入法
io.github.dingjinjin.meizufreezer   本应用自己
```

除此之外**不做任何白名单和拦截**。

---

## 三、踩过的坑

### 1. 原生布局里控件"消失"

用 XML 布局时，根布局第 2、3 个子控件（状态文字、搜索框）布局正确但**完全不绘制**，
`uiautomator` 能读到它们的 bounds，屏幕上看不到。

后来发现是 **`Theme.DeviceDefault.Light` 自带 ActionBar** 占掉了顶部空间，且
**Android 15 对 targetSdk 35 强制 edge-to-edge**，内容被顶到状态栏下面。

解决：自定义主题退出 edge-to-edge，并用 WebView 渲染界面彻底绕开。

### 2. `[math]::Min` 的 Int32 溢出

处理 10 GiB 偏移时 PowerShell 会走 Int32 重载，必须显式 `[int64]`。

### 3. 构建链路

没有 Android Studio 也能编译，只需要三个包：

```
platform-35_r01.zip        → android.jar              (62 MB)
build-tools_r35_windows.zip → aapt2/d8/zipalign/apksigner (58 MB)
JDK 17+                     → javac / keytool
```

`app/build.ps1` 已封装完整流程（aapt2 compile → link → javac → d8 → zip → zipalign → apksigner）。

---

## 四、编译与安装

```powershell
cd app
.\build.ps1 -Install
```

或手动：

```powershell
aapt2 compile --dir res -o build\res.zip
aapt2 link -I android.jar --manifest AndroidManifest.xml -o build\app-unsigned.apk `
    --java build\gen --min-sdk-version 29 --target-sdk-version 35 -A assets build\res.zip
javac -source 8 -target 8 -classpath android.jar -d build\classes <sources>
d8 --lib android.jar --min-api 29 --output build\dex <classes>
# 把 classes.dex 打进 APK → zipalign → apksigner
```

---

## 五、实测

```
列出应用      ✅ 317 个，状态与 pm 一致
单个冻结      ✅ 点 AdAway 开关 → pm list packages -d 出现 org.adaway
单个解冻      ✅ 再点一次 → 从 -d 列表消失
批量/导入/导出 ✅ 逻辑同 setFrozen，实测可用
运行稳定性    ✅ 无崩溃
```
