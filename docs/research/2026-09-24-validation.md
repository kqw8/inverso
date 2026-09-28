# Inverso 0.3.0 验证记录

用户报告：迈从 A7 V2，在微信、Chrome 均有偶发停顿和滚轮逐格跳动。
这次同时处理输入链路阻塞与离散滚轮平滑；实际设备手感尚不能由自动化测试代替。

## 已完成的实现

- 独立 `.userInteractive` 事件线程；权限查询和日志留在控制线程。
- LaunchAgent 从 `Background` 改成 `Interactive`，避免把输入过滤器当作后台计算任务。
- 主动 tap 只处理滚轮；被动 tap 观察指针、按钮按下/松开及修饰键，不阻塞普通鼠标移动。
- 默认启用短时平滑：临界阻尼响应，约 80 ms 有限尾巴，120 Hz 活跃期定时器，空闲时停止。
- 小数像素累计、快速反向取消旧余量、3 个坐标单位内的手部抖动容忍、跨上下文取消。
- 使用包含休眠时间的 `ContinuousClock`；超过 500 ms 的调度间隔丢弃旧尾巴。
- 忽略比最新滚轮输入更早的被动事件，防止两个监听源乱序导致吞掉新滚动。
- `install --smooth` / `install --no-smooth` 持久化模式；裸 `install` 保留已有选择。

## 自动化证据

环境：arm64、macOS 27.2 (26B5086k)、Swift 6.4、完整 Xcode beta 工具链。
默认选中的 Command Line Tools 缺少 XCTest，因此测试按命令指定 `DEVELOPER_DIR`，未修改系统工具链选择。

| 检查 | 结果 | 说明 |
| --- | --- | --- |
| 改动前基线 | 31/31 Swift 测试通过 | 已有未提交修改保留 |
| 输入隔离阶段 | 53/53 测试通过 | 含真实 RunLoop、并发启停和线程内释放 |
| 最终完整测试 | 101/101 通过 | 含算法、CGEvent 适配、CLI、生命周期与压力测试 |
| 最终 Thread Sanitizer | 101/101 通过，无竞争诊断 | 已核实链接了 TSAN 运行库 |
| 安装脚本 | 8/8 离线场景通过 | 下载、sudo 均为测试替身，不安装软件 |
| 混合事件压力 | 120,000 次变换通过 | 校验三个轴、时间戳、位置、修饰键、来源及手势字段 |
| 优化构建基准 | 变换与平滑引擎各三轮通过 | 见原始记录；非硬件/显示延迟 |
| 二进制 | arm64、x86_64 构建通过 | 两个 Mach-O slice 均声明 macOS 13.0 最低版本 |
| CLI 冒烟 | 版本、帮助、错误参数通过 | Intel slice 也通过 Rosetta 执行 `--version` |
| 签名及归档 | ad hoc 签名、严格校验、SHA-256 通过 | 本地构建，未发布、未 notarize |
| 实际系统 tap 探针 | **跳过** | 测试进程没有辅助功能权限，未提示授权、未创建监听 |

测试不向桌面发布合成滚动。平滑适配器注入输出接收器，真实 `CGEvent` 仅在内存中检查。
创建私有事件源需要访问 WindowServer；受限沙箱内该 API 返回 nil。沙箱外的测试复核后通过。

回归用例也验证了自己能发现问题：

- `Background` 调度配置在新期望下明确失败，再改为 `Interactive` 后通过。
- 临时副本将权限检查放回事件线程，两个隔离测试均失败；正式代码通过。
- 平滑审查用例先复现按钮松开缺失、小数余量跨位置和轻微抖动吞整格，再修复通过。
- 算法测试复现并修复浮点时间纪元造成的尾巴不结束问题。
- 临时 no-op 变换能被基准的数据校验抓住；临时错误 CLI 默认值/持久化标志也被测试抓住。

一个额外的 CoreGraphics 最小实验发现：原始 `pixelsPerLine` 为 10、16、20 的事件，
重新构造事件源后都读到 10，而事件本身的 point delta 正确保留各自距离。
因此优先使用 point delta；缺失时明确按 10 像素/行回退，避免声称能恢复不可获得的设备比例。

## 性能数值的边界

[原始三轮记录](2026-09-24-benchmarks.txt) 包含固定样本数、工具链、校验结果和测量方法。
直接变换基准的分位数是 **256 次调用的批次均值**；平滑引擎基准测量虚拟时间下的线程 CPU 成本。
它们不包含系统 tap 调度、事件发送、应用渲染、无线链路和屏幕刷新，不能当作端到端延迟。
直接变换源码与本次会话开始的版本相同，因此没有宣称该函数获得了倍数加速。

## 复现命令

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swift test --sanitize thread
bash scripts/test-install.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/benchmark.sh
```

在受限环境中为 SwiftPM 的 scratch/cache/config/security 和 clang module cache 指定可写临时目录；
CoreGraphics 事件源测试仍需正常的 macOS 用户会话。工具链路径按实际 Xcode 安装位置调整。

## 本地产物及安装

- `release/v0.3.0/inverso`：可直接分发的通用可执行文件。
- `release/v0.3.0/inverso-v0.3.0-universal.tar.gz`：仅包含该可执行文件的归档。
- `release/v0.3.0/checksums.txt`：二者的 SHA-256。

系统中原来的 `/usr/local/bin/inverso` 与 LaunchAgent **尚未替换**。要在实际鼠标上验收，
从项目根目录安装候选版本并重载服务：

```sh
sudo cp /usr/local/bin/inverso /usr/local/bin/inverso.before-v0.3.0
sudo install -m 755 release/v0.3.0/inverso /usr/local/bin/inverso
/usr/local/bin/inverso install --smooth
/usr/local/bin/inverso status
```

替换本地 ad hoc 签名二进制后，macOS 可能需要在辅助功能中移除并重新添加该路径。
`inverso permission` 可触发授权流程。对比直接反转模式：`inverso install --no-smooth`。

回滚可将 `inverso.before-v0.3.0` 复制回原路径后再执行 `inverso install`；
备份命令只适用于此前已安装在这个路径的情况。

## 尚需实机验收

以下没有冒充为通过；需装好候选版本并授权后，用迈从 A7 V2 实测：

- [ ] Chrome 长网页：慢速单格、连续滚动、快速反向、停手后的短尾巴。
- [ ] 微信会话列表和消息区：分别滚动，并在两者之间移动和点击，确认无迟到滚动。
- [ ] 比较 `--smooth` / `--no-smooth`；记录是否仍有偶发停顿，区别应用渲染与输入延迟。
- [ ] 轻微手抖、明显移开指针、按下/松开按钮、Shift/Ctrl/Command 等快捷操作。
- [ ] 如果有触控板，与鼠标交替使用，确认原生惯性与方向不被重复处理。
- [ ] 睡眠/唤醒、接收器重插或连接方式切换、系统繁忙时连续滚动。
- [ ] 如果还有其他鼠标工具，让其与 Inverso 逐一启用对比，避免重复反转/平滑。

120 Hz 定时器不保证所有刷新率下的显示同步；设备分类仍是启发式。
被动上下文取消是尽力而为，3 单位抖动容忍也可能跨过很小的视图边界。
这些是当前实现明确保留的权衡，不是已完成全硬件验证的承诺。
