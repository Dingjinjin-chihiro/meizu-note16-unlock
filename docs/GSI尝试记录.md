# GSI 尝试与回滚记录

> 日期：2026-11-01
> 设备：MEIZU Note 16（M521Q / UMS9621S）· Flyme 12.0.1.7A · Android 15
> 结论：**GSI 能刷进去、能引导到系统界面，但无法使用现有 /data，最终回滚，数据完好。**

## 一、先查 DSU：不可用

原计划用 DSU（动态系统更新）无损试 GSI，实测发现魅族把服务摘了：

```
$ adb shell service list | grep dynsystem
（无输出，361 个系统服务里没有）

$ adb shell cmd dynsystem
cmd: Can't find service: dynsystem

$ adb shell pm path com.android.dynsystem
package:/system/priv-app/DynamicSystemInstallationService/DynamicSystemInstallationService.apk
```

**APK 在，服务不注册** —— 所以 DSU Sideloader 这类工具也用不了。

## 二、fastbootd 的真相

之前刷 `init_boot`（8 MB）报 `Too many links`，让人以为"大文件刷不了"。实测证明**那是 bootloader 模式的问题**：

| 测试 | 结果 |
|---|---|
| fastbootd 写 1 MB（misc） | ✅ 0.3 秒 |
| fastbootd 写 100 MB（vendor_boot_a） | ✅ 3.2 秒（30.7 MB/s） |
| bootloader 写 8 MB（init_boot） | ❌ `Too many links` |

**但 fastbootd 有约 70 秒的写入会话超时**：

```
第 1 次：写 1.50 GB 后 FAILED (Invalid argument)，耗时 71.2 秒
第 2 次：写 1.66 GB 后 FAILED，耗时 67.1 秒
第 3 次：写 1.62 GB 后 FAILED，耗时 70.9 秒
```

三次都卡在 ~70 秒，不是容量限制，是**会话时限**。10 GiB 按 31 MB/s 需要 340 秒，一次写不完。

## 三、用 sparse 分片绕过超时

Android sparse 镜像支持 `DONT_CARE`（0xCAC3）块类型——设备读到就跳过。于是可以构造"只写某一段"的镜像：

```
[0 .. start)        → DONT_CARE（秒过）
[start .. end)      → RAW（真实数据，约 1.2 GB）
[end .. 分区末尾)    → DONT_CARE（秒过）
```

每次会话有 70 秒，1.2 GB 只花 42 秒，安全。脚本：`scripts/make_sparse_slice.py`。

```
[1] 2,959,081,472..4,217,372,672   OK  43s
[2] 4,217,372,672..5,475,663,872   OK  43s
...
[7] 10,508,828,672..10,737,418,240 OK   8s
→ 10 GiB 全部写完
```

## 四、GSI 本身

| 项目 | 值 |
|---|---|
| 镜像 | `aosp_arm64-exp-AP3A.241005.015-12366759-3c0ee79d.zip`（827 MB） |
| 解压后 | `system.img` 1.79 GB（raw ext4，非 sparse） |
| 分区容量 | `system_a` = 4.53 GiB（装得下，无需 resize） |
| 刷入 | `fastboot flash system_a system.img` → 56.5 秒，7 个 sparse 块，全部 OK |

**引导结果**：GSI 成功引导，但停在「清除全部数据」界面。

原因是 `/data` 已经用 Flyme 的密钥加密，GSI 这套 system 无法解开。这不是 GSI 的错，是**换 system 必然面对的问题**——想用 GSI 只能接受恢复出厂。

## 五、回滚

### 为什么不能简单 `fastboot flash super`

同样是 70 秒超时，10 GiB 写不完。用上面的 sparse 分片法，7 次写完。

### 完整回滚命令

**推荐用封装好的一键脚本**（设备在系统/recovery/bootloader/fastbootd 都能直接跑）：

```powershell
.\scripts\restore-super.ps1 -Backup D:\_backup
```

手动流程：

```powershell
# 1. 进 fastbootd
adb reboot fastboot

# 2. 确认
fastboot getvar is-userspace        # 应为 yes
fastboot getvar partition-size:super # 0x280000000 = 10 GiB

# 3. 分片写回（每片 1.2 GB，脚本见 make_sparse_slice.py）
python make_sparse_slice.py super.bin slice.simg <start> <end> 10737418240
fastboot flash super slice.simg

# 4. 重启
fastboot reboot
```

### 数据结果

- 回滚后 Flyme 正常启动，`sys.boot_completed=1`
- 包数 276、`/data` 用量 1.9 GB —— **数据和设置都在**
- KernelSU 仍生效（`ksu=1`），BL 仍解锁
- 唯一被重置的是部分"禁用包"状态，已用脚本补回（115 → 114）

## 六、真的刷进去试了：起不来

第二次决定彻底试一次（数据不要了）：

```
1. fastboot flash system_a system.img          → 59 秒，成功
2. fastboot -w（擦 userdata）                   → 成功，但提示 "File system type raw not supported"
3. 重启                                          → 进 Flyme recovery（"清除全部数据"界面）
```

判定 boot 链不认这套 system。于是尝试关掉 dm-verity：

```
fastboot --disable-verity --disable-verification flash vbmeta_a        _backup\vbmeta_a.bin
fastboot --disable-verity --disable-verification flash vbmeta_system_a _backup\vbmeta_system_a.bin
```

**结果更糟**：原本是「落到 recovery」，关掉 verity 后变成**无限重启**——Meizu logo 一闪就重启，连 recovery 都进不去。

## 七、完整救援过程（实战时间线）

| 时间 | 动作 | 结果 |
|---|---|---|
| 11:26 | 抓到一次 bootloader，发 `fastboot reboot fastboot` | 5 分钟没等到 fastbootd，失败 |
| — | 试 BROM（`spd_dump --wait`） | COM4 出现 0.5 秒即 `Connection failed` |
| 11:38 | **「电源 + 音量下」同按 20 秒** | ✅ 成功停在 fastboot mode |
| 11:40 | `fastboot flash vbmeta_a` / `vbmeta_system_a`（原厂，不加标志） | ✅ 还原成功，恢复"能落 recovery"的状态 |
| 11:41 | `fastboot reboot recovery` | 20 秒后 adb recovery 上线 |
| 11:42 | `adb reboot fastboot` | 20 秒后 fastbootd 就绪 |
| 11:43 | sparse 分片写 `super`：720 MB × 15 片 + 160 MB | 每片 25–26 秒，全部 OK，共 10 GiB |
| 11:51 | `fastboot reboot` | 300 秒内 adb 无响应（**因为数据被擦、USB 调试关闭**，并非失败） |
| 11:57 | 屏幕确认 → 系统正常 | ✅ 恢复完成 |

### 关键点：为什么一定要先还原 vbmeta

| vbmeta 状态 | 启动失败时的表现 |
|---|---|
| 原厂（verity enforcing） | 落到 **recovery**，adb 可用，能救 |
| 关掉 verity 标志 | **无限重启**，连 recovery 都进不去，adb 完全不可用 |

**教训**：在这台机器上，为了跑 GSI 去关 verity 是净负收益——它把一条"可救援"的失败路径变成了一条"不可救援"的路径。

### 意外发现：解锁与 root 不受影响

救援完成后直接验证：

```
ro.boot.flash.locked          = 0        ← BL 仍解锁
/proc/modules → kernelsu 1               ← 内核 root 仍在
ro.boot.veritymode           = enforcing
```

原因很简单：**BL 锁状态存在 misc 分区，root 存在 `init_boot` 分区**，这二者都不在 `super` 里，刷 GSI 和恢复 `super` 都碰不到它们。

唯一丢的是 `/data` —— KernelSU 管理器 App 和 `/data/adb` 里的配置。重新安装管理器即可：

```
adb install -r -g KernelSU_v3.3.1_32680-release.apk
# SHA256 前缀 B4A059AC，与内核 v3.3.1 完全匹配
```

装完打开即显示「工作中 / LKM / v3.3.1」，root 恢复。

## 八、结论

**这台机器跑不了 GSI，不要再试。** 三条理由：

1. DSU 被阉割（`dynsystem` 服务不存在），没有无损试用的路
2. 直接刷 `system_a` 能写进去，但 Flyme 的 boot 链不认这套 system
3. 关掉 verity 试图强推，只会把设备推向不可救援的无限重启

想体验原生，现实路径只有等第三方做设备适配——而展锐机型几乎没有。

## 九、踩坑清单

| # | 现象 | 根因 | 处理 |
|---|---|---|---|
| 1 | DSU Sideloader 无法安装 | `dynsystem` 服务未注册 | 放弃 DSU，改 fastbootd |
| 2 | `Too many links` | bootloader 模式的 USB 写 | 改用 fastbootd |
| 3 | `Invalid argument` at ~1.6 GB | fastbootd **70 秒会话超时** | sparse `DONT_CARE` 分片 |
| 4 | GSI 停在「清除全部数据」 | boot 链不认 GSI 的 system | 只能回滚 |
| 5 | 关 verity 后变无限重启 | 失去了落到 recovery 的兜底 | 先还原原厂 vbmeta |
| 6 | 电源键无法强制关机 | 快速重启循环里按键采样不到 | **「电源 + 音量下」同按 20 秒** |
| 7 | 插 USB 就重启 | 上电即启动，没停在 bootloader | 先按住音量下再插线 |
| 8 | 回滚后 adb 完全看不到 | 数据被擦 → **USB 调试默认关闭** | 看屏幕，手动开调试 |
| 9 | `[math]::Min` 报 Int32 溢出 | `$TOTAL`(10 GiB) 超出 Int32 | 用 `[int64]` 显式转换 |
| 10 | 回滚后 9 个 GMS 包被重新启用 | Flyme 检测到修改后恢复默认 | 重新 `pm disable-user` |
