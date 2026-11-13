English | [简体中文](README.zh-CN.md)

# Inverso

A small macOS CLI daemon that reverses physical mouse-wheel scrolling while leaving trackpad-like events alone. No menu bar app or smoothing layer.

Requires macOS 13+. The Homebrew package is for Apple Silicon (arm64); source builds require Swift 6.4+.

## Homebrew

```sh
brew tap kqw8/tools
brew install kqw8/tools/inverso
brew services start kqw8/tools/inverso
inverso status
```

Installation alone does not start the service. The package preserves the 0.4.0 executable and its signature. Run services as your login user, without `sudo`.

Upgrade:

```sh
brew services stop kqw8/tools/inverso
brew upgrade kqw8/tools/inverso
brew services start kqw8/tools/inverso
```

Use `brew services restart kqw8/tools/inverso` to restart. **Do not mix Homebrew services with native `inverso install/start/stop/uninstall` commands.**

## Source installation

For a separate source-managed installation, build from this checkout and copy the executable to a stable location:

```sh
swift build -c release
sudo install -m 755 "$(swift build -c release --show-bin-path)/inverso" /usr/local/bin/inverso
/usr/local/bin/inverso install
```

`install` registers the executable's absolute path, enables start-at-login, and reloads the service. Do not register a binary inside `.build`; cleaning it would break the service. After rebuilding, replace the installed binary and run `install` again.

Native commands are for source installations only:

| Command | Effect |
| --- | --- |
| `inverso install` | Register/reload the service and enable start-at-login |
| `inverso start` | Start/restart the service and enable start-at-login |
| `inverso stop` | Stop for this session; it may start at the next login |
| `inverso uninstall` | Stop, disable start-at-login, remove LaunchAgent and logs; keep the binary |

## Permissions and status

macOS requires Accessibility permission to read and rewrite input events. The daemon requests approval and retries while permission is missing. You can also run:

```sh
inverso permission
inverso status
```

Approve the installed executable in **System Settings > Privacy & Security > Device Control and Data Access** on macOS 27; earlier versions call this permission page **Accessibility**. This is not the general Accessibility settings category. Replacing a locally built or ad hoc signed binary may require removing and re-adding its permission entry.

From this checkout, the optional helper locates the executable on `PATH`, opens the permission page, reveals the binary in Finder, and checks the daemon's event tap after approval:

```sh
bash scripts/authorize-inverso.command
```

The helper currently prints Chinese instructions. It does not replace the binary or reset permissions; if the daemon's tap is already enabled, it exits without opening the approval flow.

`status` distinguishes a loaded LaunchAgent, a running process, and an enabled scroll event tap. **Accessibility (this process)** describes the CLI making the query, not the daemon. The daemon's tap is checked separately; failed queries report `unknown`, with launchctl errors shown when available.

## Behavior and limitations

- Only vertical wheel deltas are reversed in place. Horizontal deltas, modifiers, timing, and the scroll curve are preserved; pointer movement, clicks, and keys are not intercepted.
- Wheel detection uses scroll phase, momentum phase, and scroll count: a heuristic, not hardware identification. Pixel-based scrolling is not excluded on its own. Test Magic Mouse, remote input, and third-party scrolling drivers on your actual setup.
- Event callbacks run on a dedicated interactive-priority thread without polling. A five-second health check handles permission recovery and invalid taps; timeout notifications re-enable the tap immediately.
- Only one daemon per user is allowed. The empty `daemon.lock` remains after exit to preserve lock identity; its presence does not mean the daemon is running. A second launchd-managed daemon waits; a manual `inverso --daemon` exits immediately.
- Enable reversal in only one scrolling utility. Legacy `--smooth` / `--no-smooth` arguments are accepted but ignored; source installs can rewrite old LaunchAgents with `inverso install`.

## Uninstall and leftovers

For Homebrew:

```sh
brew services stop kqw8/tools/inverso
pgrep -fl -x inverso
brew services list
```

Confirm the service is stopped and `pgrep` finds no processes (exit status 1), then run:

```sh
brew uninstall kqw8/tools/inverso
```

For source installations, use `inverso uninstall`, confirm all processes have exited, then manually remove the installed binary if desired.

Possible leftovers:

- `~/Library/Logs/inverso.out.log` and `~/Library/Logs/inverso.err.log` (native uninstall removes these).
- `~/Library/Application Support/Inverso/daemon.lock`.
- `~/Library/LaunchAgents/com.kqw8.inverso.plist` if service removal was incomplete.

Inspect remaining service files before cleanup. **Never delete the lock while any Inverso process is running or its service can restart**: doing so can allow multiple daemons. Uninstalling does not reset macOS TCC permissions; manually remove stale entries in System Settings.

## Development and background

```sh
swift test
bash scripts/benchmark.sh
```

Tests require an Xcode toolchain with XCTest. If Command Line Tools is selected, use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`. Tests cover transforms, permissions, locking, service handling, and event-thread recovery without posting desktop events or changing the real service. The benchmark uses unposted in-memory events and measures processing cost, not hardware/display latency. Physical-device behavior still requires manual validation.

Version 0.4.0 removes the smoothing layer introduced in 0.3. See the [scroll freeze record](docs/research/2026-09-28-scroll-freeze.md), [source study](docs/research/2026-09-24-scrolling.md), and [validation record](docs/research/2026-09-24-validation.md) for implementation references, trade-offs, and device checks.
