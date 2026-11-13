[English](README.md) | 简体中文

# Inverso

macOS 命令行后台程序，反转鼠标垂直滚轮方向，保留类似触控板的事件，不添加平滑滚动或菜单栏界面。

需要 macOS 13+；Homebrew 软件包支持 Apple Silicon（arm64）。

## 安装

```sh
brew tap kqw8/tools
brew install kqw8/tools/inverso
brew services start kqw8/tools/inverso
```

仅安装不会启动服务。以当前登录用户运行，不要使用 `sudo`。
**服务管理仅使用 `brew services`，不要混用原生 `inverso install/start/stop/uninstall`。**

## 常用命令

```sh
inverso permission
inverso status
brew services restart kqw8/tools/inverso
```

在**系统设置 > 隐私与安全性 > 辅助功能**中批准已安装的程序（macOS 27 称为**设备控制和数据访问**）。替换本地构建或临时签名的程序后，可能需要重新授权。

滚轮识别属于启发式判断；Magic Mouse、远程输入及第三方驱动需实机测试。只在一个工具中启用反转。

## 卸载

```sh
brew services stop kqw8/tools/inverso
pgrep -fl -x inverso
brew services list
```

确认服务停止，且 `pgrep` 未找到进程（退出状态为 1）后执行：

```sh
brew uninstall kqw8/tools/inverso
```

Inverso 仍在运行或服务仍可能重启时，不得删除 `daemon.lock`。卸载不会重置 macOS 权限。

升级、源码安装（Swift 6.4+）、权限排查、行为、开发、历史与残留清理见[使用指南](docs/guide.zh-CN.md)。

[MIT 许可证](LICENSE)
