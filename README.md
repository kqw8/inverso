English | [简体中文](README.zh-CN.md)

# Inverso

A macOS CLI daemon that reverses vertical mouse-wheel scrolling while leaving trackpad-like events alone, without smoothing or a menu bar app.

Requires macOS 13+; the Homebrew package supports Apple Silicon (arm64).

## Install

```sh
brew tap kqw8/tools
brew install kqw8/tools/inverso
brew services start kqw8/tools/inverso
```

Installation alone does not start the service. Run it as your login user, without `sudo`.
**Use only `brew services` for service management; do not mix it with native `inverso install/start/stop/uninstall`.**

## Common commands

```sh
inverso permission
inverso status
brew services restart kqw8/tools/inverso
```

Approve the installed executable under **System Settings > Privacy & Security > Accessibility** (called **Device Control and Data Access** on macOS 27). Replacing a locally built or ad hoc signed binary may require reauthorization.

Wheel detection is heuristic; test Magic Mouse, remote input, and third-party drivers on your setup. Enable reversal in only one utility.

## Uninstall

```sh
brew services stop kqw8/tools/inverso
pgrep -fl -x inverso
brew services list
```

Confirm the service is stopped and `pgrep` finds no processes (exit status 1), then:

```sh
brew uninstall kqw8/tools/inverso
```

Never delete `daemon.lock` while Inverso is running or its service can restart. Uninstalling does not reset macOS permissions.

See the [guide](docs/guide.md) for upgrades, source installation (Swift 6.4+), permission troubleshooting, behavior, development, history, and leftover cleanup.

[MIT License](LICENSE)
