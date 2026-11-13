[English](README.md) | 简体中文

# Inverso

轻量 macOS 命令行后台程序，反转实体鼠标滚轮方向，保留类似触控板的滚动事件。没有菜单栏界面，也不添加平滑滚动。

需要 macOS 13+。Homebrew 软件包适用于 Apple Silicon（arm64）；源码构建需要 Swift 6.4+。

## Homebrew

```sh
brew tap kqw8/tools
brew install kqw8/tools/inverso
brew services start kqw8/tools/inverso
inverso status
```

仅安装不会启动服务。软件包保留 0.4.0 可执行文件及其签名。以当前登录用户运行服务，不要使用 `sudo`。

升级：

```sh
brew services stop kqw8/tools/inverso
brew upgrade kqw8/tools/inverso
brew services start kqw8/tools/inverso
```

使用 `brew services restart kqw8/tools/inverso` 重启。**不要混用 Homebrew 服务管理与原生 `inverso install/start/stop/uninstall` 命令。**

## 源码安装

如需独立使用源码管理安装，在本仓库构建后，将可执行文件复制到稳定路径：

```sh
swift build -c release
sudo install -m 755 "$(swift build -c release --show-bin-path)/inverso" /usr/local/bin/inverso
/usr/local/bin/inverso install
```

`install` 注册可执行文件的绝对路径、启用登录启动并重新加载服务。不要注册 `.build` 内的程序，否则清理构建目录会使服务失效。重新构建后，替换已安装的程序并再次执行 `install`。

以下原生命令仅用于源码安装：

| 命令 | 作用 |
| --- | --- |
| `inverso install` | 注册或重新加载服务，启用登录启动 |
| `inverso start` | 启动或重启服务，启用登录启动 |
| `inverso stop` | 停止当前会话中的服务；下次登录可能再次启动 |
| `inverso uninstall` | 停止服务、禁用登录启动、移除 LaunchAgent 和日志；保留可执行文件 |

## 权限与状态

macOS 要求授予辅助功能权限才能读取和修改输入事件。缺少权限时，后台程序会请求授权并持续重试，也可以执行：

```sh
inverso permission
inverso status
```

macOS 27 中，在**系统设置 > 隐私与安全性 > 设备控制和数据访问**中批准已安装的程序；旧版本将此权限页面称为**辅助功能**。它不是系统设置中通用的辅助功能分类。替换本地构建或临时签名的程序后，可能需要删除旧权限条目并重新添加。

在本仓库中，可选助手会从 `PATH` 定位程序、打开权限页面、在 Finder 中显示程序，并在授权后检查后台事件监听：

```sh
bash scripts/authorize-inverso.command
```

助手目前输出中文提示。它不会替换程序或重置权限；如果后台事件监听已经启用，会直接退出，不打开授权流程。

`status` 区分 LaunchAgent 已加载、进程正在运行和滚轮事件监听已启用。**Accessibility (this process)** 表示发起查询的命令行进程权限，不代表后台程序。后台事件监听单独检查；查询失败显示 `unknown`，存在 launchctl 错误时会一并显示。

## 行为与限制

- 只原地反转垂直滚轮增量，保留水平增量、修饰键、时序及滚动曲线；不拦截指针移动、点击或键盘事件。
- 根据滚动阶段、惯性阶段和滚动计数判断滚轮事件，属于启发式判断，不是硬件识别。不会仅因事件使用像素滚动就排除它。Magic Mouse、远程输入及第三方滚动驱动需要在实际环境中测试。
- 事件回调在独立的交互优先级线程运行，不轮询输入。每五秒进行健康检查，处理权限恢复和无效监听；收到超时通知时立即重新启用监听。
- 每个用户只允许运行一个后台实例。退出后保留空的 `daemon.lock` 以维持锁文件身份，文件存在不代表程序仍在运行。第二个由 launchd 管理的实例会等待；手动执行 `inverso --daemon` 则立即退出。
- 只在一个滚动工具中启用反转。旧的 `--smooth` / `--no-smooth` 参数仍可接受，但会被忽略；源码安装可用 `inverso install` 重写旧 LaunchAgent。

## 卸载与残留

Homebrew 安装：

```sh
brew services stop kqw8/tools/inverso
pgrep -fl -x inverso
brew services list
```

确认服务停止，且 `pgrep` 未找到进程（退出状态为 1）后执行：

```sh
brew uninstall kqw8/tools/inverso
```

源码安装使用 `inverso uninstall`，确认所有进程退出后，可按需手动删除已安装的可执行文件。

可能残留：

- `~/Library/Logs/inverso.out.log` 和 `~/Library/Logs/inverso.err.log`（原生卸载会删除）。
- `~/Library/Application Support/Inverso/daemon.lock`。
- 服务移除不完整时的 `~/Library/LaunchAgents/com.kqw8.inverso.plist`。

清理前先检查残留的服务文件。**任何 Inverso 进程仍在运行，或服务仍可能重启时，都不能删除锁文件**，否则可能导致多个实例同时运行。卸载不会重置 macOS TCC 权限；请在系统设置中手动移除过期授权条目。

## 开发与背景资料

```sh
swift test
bash scripts/benchmark.sh
```

测试需要包含 XCTest 的 Xcode 工具链。若当前选择的是 Command Line Tools，可使用 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`。测试覆盖事件变换、权限、锁、服务处理和事件线程恢复，不向桌面发送事件，也不修改实际服务。基准测试使用未发送的内存事件，只衡量处理成本，不代表硬件或显示延迟。实体设备行为仍需手动验证。

0.4.0 移除了 0.3 引入的平滑滚动层。实现参考、取舍及设备检查见[滚动卡死记录](docs/research/2026-09-28-scroll-freeze.md)、[源码研究](docs/research/2026-09-24-scrolling.md)和[验证记录](docs/research/2026-09-24-validation.md)。
