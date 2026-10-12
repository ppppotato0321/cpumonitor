# cpumonitor — iPhone XS Max (A12) / iOS 12.3.1 越狱性能监测

## 这是什么
一个 theos 命令行工具，跑在已经越狱的 XS Max 上，每 1 秒刷新一次：

| 指标 | 来源 | 可靠度 |
|---|---|---|
| 每核占用率 | `host_processor_info` | 100% |
| 电池电压 (mV) | IOKit `AppleSmartBattery` / `Voltage` | 100% |
| 电池电流 (mA) | IOKit `AppleSmartBattery` / `Amperage` | 100% |
| **整机功耗 (W)** | `abs(电流) × 电压` | **100%，硅片级真实读数** |
| 电池温度 (°C) | IOKit `Temperature` | 100% |
| 电池容量 / 循环次数 | IOKit `CurrentCapacity` / `CycleCount` | 100% |
| CPU 标称最高/最低频率 | `sysctl hw.cpufrequency_max/min` | 通常有 |
| **P 核 / E 核实时频率** | 私有框架 IOReport | 尽力而为，iOS 12 A12 上需要现场确认 group 名 |

## 重要前提（必须先看）

**iOS / A12 上没有独立的"CPU 功率"传感器**。
- x86 Mac 有 RAPL MSR，可以直接读每核功耗；iOS 没有。
- 所以 `power draw` 那一行是**整个手机**的硅片功耗（从电池端测的，最真实），不是纯 CPU。
- 想得到"纯 CPU 功耗"只能用模型估算：`P_cpu ≈ C_eff × V² × f × active_cycles`，需要先导出 A12 的 DVFS 表（见下文）。

## 编译 / 安装

1. 在你的 Mac 上装好 theos（`https://github.com/theos/theos`）。
2. 把 `cpumonitor/` 目录拷到 theos 工程目录下。
3. `cd cpumonitor && make package`
4. 把生成的 `com.local.cpumonitor_0.1_iphoneos-arm64.deb` 通过 Sileo/Cydia 安装，或 `dpkg -i` 直接装到设备。
5. SSH 到设备，root 身份运行：
   ```bash
   sudo cpumonitor          # 持续刷新
   sudo cpumonitor -1       # 只输出一次快照
   ```

> A12 在 iOS 12.1.3–12.4 上的越狱（unc0ver / checkra1n）要求二进制用 CMS blob 签名；theos 默认会处理，如果你自己交叉编译，记得 `ldid -S` 签名一次。

## 如果实时频率那一行显示 "(IOReport not available)"

说明 iOS 12.3.1 上 IOReport 的 group 名跟代码里写的 `"CPU Stats"` 对不上。在设备上跑这两条命令把真实 group 名抓出来：

```bash
# 方法 1：列出所有 IOReport group / subgroup
sudo powermetrics --samplers cpufreq -n 1 -i 100 2>&1 | head -50

# 方法 2：直接 dump IORegistry 里跟 freq 有关的节点
ioreg -l | grep -i -E "freq|cluster|hwperf" | head -40
```

把你看到的 group / subgroup 名（一般长这样：`CPU Stats` / `P-CORE`、`GPU` / `GPCC`）告诉我，我把 `sampleCPUFrequencies()` 里的字符串换掉就行。

## 想进一步拿到"纯 CPU 功耗"

1. **导出 A12 DVFS 表**：在设备上装 `CPUFriend` 或 `CPUFriendDataProvider`，它生成的 `/var/containers/.../cpufrienddata.plist` 里就有每个 P 核 / E 核档位的 `frequency` 和 `voltage`。
2. 把那个 plist 发我，我在工具里加一行：
   ```
   P0 active time × V²(f_P0) × f_P0   →   P0 动态功耗
   ```
3. 静态漏电功耗在 iOS 上读不到，只能用经验系数（A12 典型值 ~50–150 mW 待机漏电）。

## 已知限制
- 这是命令行工具，不是 SpringBoard 插件。想在状态栏实时显示可以再套一个 `cpumonitor` 的 tweak 版（`%hook` 进 `SBStatusBar_Modern`），要的话我再给。
- 整机功耗在充电时会变成负值方向（电流为正），公式已经取了绝对值，能正常显示充电功率。
- A12 的 P 核（Vortex ×2）和 E 核（Tempest ×4）是两个独立 cluster，实时频率读数会分开出现在 `P-CORE/...` 和 `E-CORE/...` 键下。
