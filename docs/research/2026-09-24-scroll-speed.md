# 0.3.1 滚动距离修正

用户实测迈从 A7 V2 后确认：每格移动距离偏短，不是起步时间偏长。
0.3.0 已成功运行并启用事件监听；诊断期间未修改其二进制、签名或授权。

## 原因和证据

0.3.0 优先保留离散事件的 CoreGraphics point delta，再发出连续像素事件。
这个数值守恒不足以保证应用中的移动距离不变。

本地未发布事件实验得到：普通行事件 `line=1, point=10, fixed=1` 在 AppKit 中
是 `scrollingDeltaY=1, precise=false`；10 像素事件则为 `deltaY=10, precise=true`。
[Chromium 的普通滚轮路径](https://github.com/chromium/chromium/blob/main/components/input/web_input_event_builders_mac.mm#L478-L575)
将 NSEvent/fixed-point 的行数乘以
[40 像素](https://github.com/chromium/chromium/blob/main/ui/events/cocoa/cocoa_event_utils.h#L15-L17)，
而连续输入直接使用 point delta。上面的常见表示在旧平滑路径只输出 10，
Chrome 普通滚轮路径则输出 40。这是可复现的单位换算问题；尚未采集 A7 V2 的实际事件来断言所有输入都恰好相差四倍。

[Apple 文档](https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay)
也区分精确像素和应用需要按行高缩放的普通滚轮值。微信的内部换算比例没有源码证据，
因此提供倍率调节，而不是宣称所有应用都能用同一个物理换算比例。

另外两个未发布事件实验复现了不必要的距离损失：连续两次 40 像素输入通常输出 80，
但仅改变 `maskNonCoalesced` 或把未知目标 PID 从 0 变为已知值，旧代码会取消第一段，最终只输出 40。

## 修正

- 普通离散滚轮优先使用 fractional fixed-point 行数 ×40；其次为整数行 ×40，最后才用 point-only 输入。
- 保留 80 ms 平滑时序与既有指针容忍范围，没有用缩短动画来掩盖距离问题。
- 非操作语境标志不再取消滚动；未知 PID 不覆盖已知 PID，不同已知目标之间仍取消。
- 增加 `inverso speed` 和 `inverso speed 1.5`，支持 0.25–4 倍，默认 1 倍对应修正后的单位。
- 配置文件在控制线程的既有健康检查中读取。实时事件线程只接收已验证数字，非法文件保留上一次有效设置并避免重复日志。
- 切换倍率时取消旧倍率尾巴，下一次输入使用新倍率；不会重建 tap 或要求重新授权。

最后一句适用于 **已经安装 0.3.1 之后的倍率调节**。从 0.3.0 更换为新的 ad hoc 签名二进制，
仍可能需要 macOS 重新授权，不能承诺绕过系统的签名检查。

## 使用

安装 0.3.1 后，先体验默认距离，再按需要调节：

```sh
/usr/local/bin/inverso speed       # 当前倍率
/usr/local/bin/inverso speed 1.5   # 比正常距离再增加 50%
/usr/local/bin/inverso speed 1     # 恢复正常距离
```

普通 `speed` 调节无需 sudo，通常约五秒后生效。它只影响本工具平滑的鼠标滚轮，
不修改系统的全局鼠标设置，也不改变触控板或快捷键滚动。

## 最终验证与产物

- 完整 Swift 测试 **129/129 通过**；完整 Thread Sanitizer **129/129 通过**，无竞争诊断。
- 安装脚本 **8/8** 离线场景通过。
- 实际配置加载在控制线程；初次启动前生效，热更新不重建 tap，重建后仍保留倍率。
- 独立审查的目标 PID 记忆问题已用失败用例复现并修复，再复核通过。
- arm64 和 x86_64 发布构建成功；通用文件的两个 slice 均为 macOS 13.0 起，Intel slice 的版本命令也已运行。
- 签名严格校验、归档校验通过；新 CLI 的查询和非法参数检查没有改写实际用户配置。
- 调整授权助手：优先检查后台真实监听，避免把终端/Codex 自身的权限状态误报为后台未授权。

本地产物位于 `release/v0.3.1/`，当前已安装的 0.3.0 未被替换或重新签名。
新二进制 SHA-256：`cefc00e854447a5db5ec3674202b23efd1b06c51821bc7b195dc5a3f1a44543c`。

从项目目录升级一次：

```sh
sudo install -m 755 release/v0.3.1/inverso /usr/local/bin/inverso
/usr/local/bin/inverso install --smooth
```

若新签名需要授权，运行 `bash scripts/authorize-inverso.command`。
先用修正后的默认 `1.0` 体验；仍想更快时再设置 `speed 1.5`。
实际迈从 A7 V2 在微信和 Chrome 的新版本手感，需要用户安装后继续验证。
