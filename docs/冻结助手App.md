# 魅族冻结助手（自研 App）

> 版本：6.8　·　2026-11-01
> 包名：`io.github.dingjinjin.meizufreezer`
> APK：`app/release/meizu-freezer-6.8.apk`（25 KB）
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

---

## 六、交互逻辑（对照小黑屋）

从反编译出的文案和布局还原出小黑屋的真实流程：

| 资源 | 文案 / 结构 |
|---|---|
| `ct` | 请点击右上角加号添加应用到小黑屋 |
| `ce` / `cd` | 冻结应用 / 解冻应用 |
| `cb` | 取消选择 |
| `cg` | 同时解冻这些应用 |
| `el` / `a9` | 全部冻结 / 一键冻结 |
| `layout/aa.xml`、`ab.xml` | `SheetFeatureView` 底部操作面板：打开 / 冻结 / 解冻 / 加短链 / 设置 / 加入清单 / 移出清单 / 取消选择 |

**关键点：勾选只是「选择」，不会立刻冻结。** 选中后弹出底部操作栏，
再点「冻结 / 解冻」才真正执行。

### v3.0 起按此逻辑重做

- 点行 = 勾选（只改选中状态，不动系统）
- 选中 ≥1 时底部滑出操作栏：`已选择 N 个应用` + **冻结** / **解冻** / **取消**
- 顶栏：全选 / 取消选择 / 导入列表 / 导出 / 刷新
- 执行前弹原生确认框（`WebChromeClient.onJsConfirm` → `AlertDialog`）
- 移除了原来那个没用的悬浮刷新按钮

实测：选中 AdAway → 底部栏出现 → 点冻结 → 原生确认框 → 确定 →
`pm list packages -d` 出现 `org.adaway`（124→125），解冻后回到 124。
### v3.1 布局调整

- 头部（标题/搜索/筛选/工具栏）**固定不动**，只有应用列表滚动
- 用 `html,body{height:100%;overflow:hidden}` + `.app{display:flex}` + `.listwrap{flex:1;overflow-y:auto}` 实现
- 切换筛选/搜索时列表回到顶部
- 底部操作栏同样是 fixed，始终贴在底部
### v3.2 交互提示（toast）

| 场景 | 提示 |
|---|---|
| 选中 / 取消选中 | `已选中 Aicy 助手　共 3 个` |
| 全选 | `已全选 317 个应用` |
| 取消选择 | `已取消 5 个选择` / `当前没有选中项` |
| 切换筛选 | `只看已冻结：122 个` |
| 搜索 | `搜索「qq」：3 个匹配` / `没有匹配「xx」的应用` |
| 刷新 | `已刷新：共 317 个应用，冻结 124 个` |
| 批量执行 | `正在冻结 5 个…` → `已冻结 5 个` |
| 部分失败 | `部分冻结：成功 3 / 5` |
| root 失败 | `冻结失败，请检查 root 授权` |
| 导入 | `已冻结 12 个，跳过 3 个` / `先粘贴包名列表` |
| 导出 | `已导出到 frozen-xxx.txt（应用目录下）` |

样式区分：成功绿色、失败红色、普通灰色；操作栏出现时 toast 自动上移避免遮挡。
---

## 七、小黑屋完整功能盘点（反编译清单）

### 组件

| 类型 | 组件 | 作用 |
|---|---|---|
| Activity | `MainActivity` / `AppListActivity` | 主界面 / 应用选择 |
| Activity | `AppInfoActivity` | **应用详情页** |
| Activity | `SettingsActivity` / `StorageSetting` | 设置 / 存储 |
| Activity | `ShortcutActivity` / `ActionStartActivity` | **快捷方式**（点图标即冻结/解冻） |
| Activity | `TaskerEditActivity` | Tasker 集成 |
| Activity | `IntroActivity` / `EnableSystemAppActivity` | 引导 / 激活预装应用 |
| Service | `QuickSettingService` | 通知栏快捷磁贴 |
| Service | `NotificationCollectorService` | 通知监听（有通知不自动冻结） |
| Service | `AutoDisableService` | **自动冻结**（锁屏 / Home 后） |
| Service | `AdminService` + `AdminReceiver` | 设备管理员模式 |
| Receiver | `RecentTaskReceiver` | 监听最近任务，配合自动冻结 |
| Native | `libfreeze.so` + `app_process/FastDisable` | 常驻 daemon 加速批量冻结 |

### 能力

- 冻结 / 解冻 / 全部冻结 / 全部解冻 / 一键冻结 / 一键解冻
- **工作模式**：Root、Shizuku、设备管理员、冰箱托管、预装激活
- **自动冻结**：锁屏后、Home 后；例外：有通知的 App、后台服务
- **冻结并锁屏**
- **快捷方式**：为应用建桌面图标，点击直接冻结/解冻
- **通知栏磁贴**
- **Tasker** 插件
- 应用详情页、排序方式、显示系统应用、图标缓存
- 指纹/面部验证保护
- 把应用加入/移出「小黑屋清单」

### 本 App 对照

| 功能 | 小黑屋 | 本 App |
|---|---|---|
| 冻结/解冻/批量 | ✅ | ✅ |
| 导入包名列表 | ❌ | ✅ |
| 导出冻结清单 | 部分 | ✅ |
| 搜索/筛选/排序 | ✅ | ✅（名称/大小/时间） |
| **应用详情（UID/版本/大小/路径/运行状态）** | ✅ | ✅ 长按打开 |
| **从详情页打开应用** | ✅ | ✅ |
| 一键解冻全部 | ✅ | ✅ |
| 自动冻结（锁屏/Home 后） | ✅ | ❌ 待做 |
| 快捷方式 / 通知磁贴 | ✅ | ❌ 待做 |
| Tasker | ✅ | ❌ |
| 指纹锁 | ✅ | ❌ |
| Shizuku / 设备管理员免 root | ✅ | ❌（仅 root） |
| 常驻 daemon 加速 | ✅ | ❌（每次 exec su，300 个约 10 秒） |

## 八、v4.0 / v4.1 更新

- **长按应用行 → 详情面板**：状态、运行状态（pid）、类型、版本、UID、SDK、
  APK 大小、数据大小（`du -sk`）、安装/更新时间、APK 路径
- 详情里可直接 **打开应用 / 冻结 / 解冻**
- **排序**：名称 → 大小 → 时间，循环切换
- **解冻全部**：标题栏右侧红色按钮，确认后一次性解冻
- 数据大小在 Java 侧解析 `du` 输出（`cut` 在这台机器上不可靠）
## 九、v5.0 / v5.1 界面打磨

**视觉**
- 深色主题重做：`#0B0D10` 背景 + 分层卡片，渐变标题文字
- **列表显示真实应用图标**（`PackageManager.getApplicationIcon` → PNG → base64，Java 侧 HashMap 缓存，JS 分批 14 个/轮加载避免卡顿）
- 骨架屏加载（shimmer），空状态插图
- 卡片行：图标 + 名称 + 等宽包名 + 状态胶囊，选中态带蓝色描边与光晕
- 筛选 chip 选中态渐变 + 投影；按钮按压缩放反馈
- 底部操作栏毛玻璃（`backdrop-filter: blur`），显示「冻结 N · 启用 M」统计
- 弹层圆角 20px、底部抽屉动画、遮罩模糊
- 详情面板头部显示应用图标

**逻辑**
- 修正冻结判定：原来只认 `DISABLED_USER(3)`，漏掉了 `DISABLED(2)`
  （本机 `com.sprd.powersavemodelauncher`、`com.android.devicelockcontroller`）
  现在 2/3/4 都算已冻结，App 计数与 `pm list packages -d` 完全一致（124 = 124）
- 搜索框加清除按钮
- 排序按钮文案简化为「排序」，当前方式在 toast 里提示
---

## 十、自动冻结（v6.x）

### 功能

锁屏后自动冻结「自动冻结清单」里的应用。

- 只冻结清单内的应用，清单为空时什么都不做
- 正在前台/可见的应用跳过，不会把用户正在用的冻掉
- 60 秒节流，避免重复执行
- 常驻前台通知，可随时关闭

UI：顶栏「自动」→ 面板里的开关 / 清单数量 / 上次执行时间 / 把选中加入清单 / 清空 / 立即执行一次。

### 实现

```
AutoFreezeService（前台服务，specialUse 类型）
  ├─ BroadcastReceiver(ACTION_SCREEN_OFF)   ← 常规路径
  ├─ PowerManager.isInteractive 轮询        ← 2 秒一次
  ├─ AlarmManager.setAndAllowWhileIdle(60s) ← 心跳兜底
  └─ SharedPreferences 存开关与清单
```

### 踩到的坑：锁屏后进程被系统冻结

第一次测试完全没反应。查日志发现：

```
ps -A → io.github.dingjinjin.meizufreezer  do_freezer_trap
```

**Flyme 在锁屏后把我们的进程直接冻结了**（cgroup freezer），
所以 `ACTION_SCREEN_OFF` 广播收不到、2 秒轮询也不跑。

解决：加 **AlarmManager 心跳**（60 秒一次，`setAndAllowWhileIdle`），
闹钟到点会唤醒进程跑一次 `isInteractive()` 检查，检测到熄屏就执行冻结。

实测日志：

```
I AutoFreeze: heartbeat
I AutoFreeze: checkScreen interactive=false last=true
I AutoFreeze: runFreeze enabled=true force=false
I AutoFreeze: targets=1 toFreeze=1 fg=[io.github.dingjinjin.meizufreezer]
I AutoFreeze: su result: Package org.adaway new state: disabled-user
```

冻结点：锁屏后 **约 60~75 秒内**生效（取决于闹钟调度）。

### 限制

- 首次「立即执行一次」可立即验证配置是否正确
- 若长时间不生效，需要到系统「权限管理 / 后台运行」里允许本应用后台运行
  （Flyme 会清后台，即使前台服务也可能被杀）