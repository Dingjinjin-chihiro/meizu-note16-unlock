# 魅族 Note 16（M521Q）解锁 Bootloader 与 Root · 全流程实录

> 一台魅族 Note 16（展锐 UMS9621S / Flyme 12.0.1.7A / Android 15），从 **fastboot 公钥签名解锁失败**，到最终 **Bootloader 解锁 + KernelSU(LKM) Root 生效** 的完整过程记录。

![Device](https://img.shields.io/badge/Device-MEIZU%20Note%2016%20(M521Q)-blue)
![SoC](https://img.shields.io/badge/SoC-UNISOC%20UMS9621S-orange)
![Bootloader](https://img.shields.io/badge/Bootloader-Unlocked-brightgreen)
![Root](https://img.shields.io/badge/Root-KernelSU%20v3.3.1%20LKM-brightgreen)
![Backup](https://img.shields.io/badge/Backup-11.68%20GiB-yellow)

---

## 一、结果

| 项目 | 状态 | 验证方式 |
|---|---|---|
| Bootloader | ✅ 已解锁 | `ro.boot.flash.locked=0`、`verifiedbootstate=orange` |
| 解锁记录 | ✅ 已写入 | `miscdata` + `0x2000` 处 64 字节 = 32B 标识 + 16B 哈希 + 16B 哈希 |
| Root | ✅ 生效 | `/proc/modules` 中存在 `kernelsu … Live (OE)` |
| Root 方案 | KernelSU v3.3.1 **LKM** | KMI `android13-5.15`，写入 `init_boot_a` |
| 全盘备份 | ✅ 11.68 GiB / 80 个分区 | `r all`（排除 userdata/cache/blackbox） |

设备指纹：`meizu/Meizu_Note16_CN/MeizuNote16:15/AP3A.240905.015.A2/23:user/release-keys`

---

## 二、交互式文档

完整图文流程在 **[`docs/index.html`](docs/index.html)**（离线可用，双击打开）：

- **15 个章节**：摘要与仪表盘 / 设备档案 / 启动链与漏洞 / 环境工具 / 完整流程 / 逐步实录 / 踩坑与错误码 / 数据附录 / 恢复手册 / 截图证据 / FAQ / 术语表 / 脚本源码
- **DHTB 镜像结构**拆解（魔数、版本、摘要域、载荷长度字段）
- **SPL 补丁字节级证据**：5 段 × 16 字节 AArch64 `NOP`（`1f 20 03 d5`），含原指令的反汇编注释
- **84 行分区表**（可搜索 / 按大小筛选，逐项用途注释）、13 个镜像 SHA256、20+ 条时间线
- **14 条错误码对照表**，每条给出含义与处理方式
- **决策树**：6 种异常现象 → 根因 → 处置
- **15 条术语表**（BROM / SPL / DHTB / AVB / dm-verity / LKM / KMI …）
- 20 个可折叠详情、所有命令块一键复制、15 张截图可放大
- **补丁点反汇编**（§13）：5 处补丁点全部指向同一个验签函数 `0x0B9C8`，含 `0x0CD00` 的完整反汇编与 C 伪代码（Capstone 5.0.7 生成，含一处极性更正记录）
- **BROM 协议逐帧解析**（§14）：帧格式、9358 帧的类型统计、握手序列、数据块大小规律
- **系统精简**（§15）：103 个系统应用冻结 + 7 个第三方卸载，含恢复脚本与验证记录
- 另有 [去膨胀记录](docs/去膨胀记录.md)、[模块指南](docs/模块指南.md)、[GSI 尝试记录](docs/GSI尝试记录.md)、[极限精简记录](docs/极限精简记录.md)、[模块与去广告记录](docs/模块与去广告记录.md) 五份补充文档

> 启用 GitHub Pages：仓库 **Settings → Pages → Source: Deploy from a branch → Branch: `main` / folder: `/docs`**，
> 之后访问 `https://Dingjinjin-chihiro.github.io/meizu-note16-unlock/`。

---

## 三、三条核心结论

### 1. 本机的 fastboot 公钥签名解锁必然是失败的

网上流传的 `sign.pem`（RSA-4096）在这台机器的 `uboot_a.bin` 里**根本不存在**：

```
sign.pem 公钥模数前缀: d8 04 af e3 d3 84 6c 7e 0d 89 3d c2 8c d3 12 55
uboot_a.bin (3MB) 中匹配:  NO
```

所以 `flashing unlock_bootloader` 永远返回 `Unlock bootloader fail.`。
**注意陷阱**：本地用同一把 `sign.pem` 验签会返回 `Verified OK` —— 这是自己验自己，属于假阳性。

### 2. 必须先把 `splloader` 擦掉

解锁载荷本质是「打过补丁的 SPL」，被 BROM 装进 SRAM 执行后设备会重启。
若 `splloader` 分区仍在，BootROM 会重新加载**原厂 SPL**，校验权回到原厂，刚写入的解锁记录被丢弃（`miscdata` 依旧全零）。
擦除后设备每次重启都会自动落回 BROM，**既保证结果不被覆盖，又让后续全程不需要再按组合键**。

### 3. fastboot 大块写入不稳定，BROM 才是可靠通道

8 MB 的 `init_boot` 走 fastboot 两次失败：

```
Sending 'init_boot_a' (8192 KB)   OKAY [0.199s]
Writing 'init_boot_a'             FAILED (Status read failed (Too many links))
```

改走 BROM 直接写分区，一次成功（36.7 Mb/s）。同样的问题也体现在 BROM 端口的存活窗口上——**端口出现后必须在 1 秒内握手**，否则自行脱落。

---

## 四、仓库结构

```
meizu-note16-unlock/
├─ docs/
│  ├─ index.html              # 主文档（交互式，11 章）
│  ├─ assets/                 # 15 张截图
│  └─ 恢复指南.md              # 备份与救援速查
├─ scripts/                   # 本次实际使用的 PowerShell 脚本
│  ├─ brom_grab.ps1           # 端口自动捕捉 + 重试执行
│  ├─ brom_backup.ps1         # 全盘备份（r all）
│  ├─ brom_read.ps1           # 读取关键分区（只读）
│  ├─ brom_write.ps1          # 向指定分区写入镜像
│  ├─ unlock_step.ps1         # 分阶段解锁（flash_cboot / payload / verify）
│  ├─ phaseA.ps1              # 擦 SPL + 刷 cboot + 发载荷 + 校验
│  ├─ phaseB.ps1              # 写回签名 SPL + 原版 uboot
│  └─ partitions.json         # 84 条分区数据
├─ logs/                      # 精选运行日志（真实输出）
├─ evidence/                  # miscdata 前后 64 字节对照
└─ README.md
```

### 未入库的内容（有意排除）

| 内容 | 原因 |
|---|---|
| `_backup/`（11.68 GiB 固件） | 超过 GitHub 限制，且含 IMEI 等设备私有数据 |
| `init_boot_patched.img`（8 MB） | 可用 KernelSU 现场重新生成，且镜像与设备一一对应 |
| 第三方工具包（`spd_dump.exe`、`fdl*.bin`、`cboot.bin`） | 版权归原作者，请从上游获取（见致谢） |

> 引导关键分区（24 个，177.2 MB）已单独归档到 **[meizu-note16-firmware](https://github.com/Dingjinjin-chihiro/meizu-note16-firmware)**：gzip 后 51.5 MB，拆 2 卷，附 manifest.json 与一键还原脚本。

---

## 五、关键参数（本机验证有效）

| 参数 | 值 | 说明 |
|---|---|---|
| BROM 漏洞地址 | `0x65017f08` | CVE-2022-38694，覆盖签名校验函数指针 |
| FDL1 装载地址 | `0x65000800` | SRAM |
| FDL2 装载地址 | `0xbefffe00` | DDR |
| SPL 真实长度 | `0x10F28`（69416 B） | 由 `gen_spl-unlock` 自动探测 |
| 解锁记录位置 | `miscdata + 8192`，64 字节 | 全零 = 锁定 |
| 分区总数 | 83（GPT）+ splloader 裸区 | Storage: UFS，A/B 双槽 |

最小可用命令（进入 BROM 后）：

```powershell
.\spd_dump.exe --wait 120 --reconnect exec_addr2 0x65017f08 `
  fdl fdl1-dl.bin 0x65000800 `
  fdl fdl2-dl.bin 0xbefffe00 `
  exec p reset
```

---

## 六、复现须知（请务必读完）

1. **强芯片/固件相关**：`0x65017f08`、`fdl1-dl.bin`、`fdl2-dl.bin`、`fdl2-cboot.bin` 全部是针对 `ums9621` 的。同系列其他机型常见地址是 `0x65015f08` / `0x65015f48`，**照抄会砖**。
2. **先备份再动手**：`r all` 拿到全部引导相关分区，这是唯一的后悔药。
3. **解锁会清空数据**，且失去保修、影响 OTA。
4. 本文记录的是**单台设备的一次实践**，不构成通用教程。

---

## 七、免责声明

本项目仅用于**本人设备的备份、研究与恢复**记录。
解锁引导器、绕过签名校验、修改系统分区均可能导致**设备变砖、数据永久丢失、保修失效**。
任何人参照本仓库内容操作，**风险自负**，作者不承担任何责任。
请遵守当地法律与设备厂商的用户协议。

---

## 八、致谢

- **[TomKing062](https://github.com/TomKing062)** — `spd_dump` / CVE-2022-38694 unlock bootloader 工具链
- **[tiann/KernelSU](https://github.com/tiann/KernelSU)** — 内核级 Root 方案
- **酷安 @keimi滑稽糖** — 原始解锁思路与教程（`docs/assets/tutorial_*.jpg` 为教程截图引用，版权归原作者）
- Hovatek 社区 — Unisoc 解锁流程参考

---

## License

文档与脚本采用 [MIT](LICENSE)。
仓库中引用的第三方工具、固件、截图版权归各自作者所有。
