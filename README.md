# Inverso

`inverso` is a small macOS CLI daemon that reverses a physical mouse wheel while
leaving trackpad-like scrolling alone.

It is intentionally not a menu bar app. Install it once, let launchd keep it running, and control it from the terminal.

Requires macOS 13 or later. Source builds require Swift 6.4 or later.

## Install

This Mac uses the local Homebrew tap in `~/Developer/homebrew-tools`:

```sh
brew install kqw8/tools/inverso
brew services start kqw8/tools/inverso
inverso status
```

Manage that installation with `brew services stop/restart kqw8/tools/inverso` and
`brew uninstall kqw8/tools/inverso`. Do not combine Homebrew services with the
native `inverso install/start/stop/uninstall` commands. The tap preserves the working
0.4.0 executable and its signature; source code remains in this checkout.

For a separate installation built directly from source:

Build from this checkout, then copy the executable to a stable location before
registering the service:

```sh
swift build -c release
sudo install -m 755 "$(swift build -c release --show-bin-path)/inverso" /usr/local/bin/inverso
inverso install
```

`inverso install` registers the LaunchAgent with the executable's absolute path and
starts it. Registering a binary inside `.build` would make the service stop working
after that directory is cleaned. After rebuilding, copy the new binary and run `inverso install` again to
reload the service.

## Commands

```sh
inverso install
inverso status
inverso permission
inverso stop
inverso start
inverso uninstall
```

`install` enables start-at-login and reloads the service.
`stop` unloads the service for the current session; it can start again at the next login.
`start` enables start-at-login and starts/restarts the service. `uninstall` stops it,
disables start-at-login, and removes its LaunchAgent and logs; the binary stays in place.

`status` distinguishes a loaded LaunchAgent from a running process and reports whether
that process has an enabled scroll event tap. Query failures appear as `unknown` with
the underlying error. The Accessibility line describes the CLI process making the
query; the daemon's event tap is checked separately.

## Permission

macOS requires Accessibility permission for tools that read and rewrite input events.

When the background service starts without permission, Inverso asks macOS for approval and keeps retrying while it waits. You can also trigger the same flow manually:

```sh
inverso permission
```

On macOS 27, approve Inverso in System Settings -> Privacy & Security ->
**Device Control and Data Access** (设备控制和数据访问). Earlier macOS versions
call this permission page **Accessibility**. This is a privacy permission page,
not the general Accessibility settings category.

For an installation at `/usr/local/bin/inverso`, this helper opens the correct
permission page and reveals the executable in Finder:

```sh
bash scripts/authorize-inverso.command
```

Drag the selected executable into the permission list and enable its switch.
The helper waits for your approval, then checks the background daemon's event tap.
It does not change the binary or reset any permissions.

If macOS does not list the binary, add `/usr/local/bin/inverso` manually.
For a source install, add the path you actually installed, such as `~/.local/bin/inverso`.
Replacing a locally built or ad hoc signed binary may require removing and re-adding
that executable in Accessibility settings.

Scroll input arrives through macOS event callbacks on a dedicated,
interactive-priority thread; it is never polled. The LaunchAgent also uses interactive scheduling
so macOS does not treat this input filter as background work. Run `inverso install`
after replacing an older binary to update its LaunchAgent settings.

The daemon's health timer runs every five seconds on the control thread.
Permission checks and log writes stay there; brief tap-state checks run on the
event thread that owns the tap. Permission checks and log writes cannot hold up the scroll callback.
A timeout notification re-enables the tap immediately; the health check rebuilds an
invalid one and resumes when permission returns.
Repeated identical failures are logged once until the state changes. Status lines
from the running daemon start with a local timestamp, and the health check reports
when and how often macOS disabled the tap (after a slow callback or because of user
input).
Logs are in `~/Library/Logs/inverso.err.log` and `~/Library/Logs/inverso.out.log`.

## Notes

Inverso handles ordinary physical mouse-wheel events. Trackpad-like events are passed through unchanged.

- Each wheel event is reversed in place and returned immediately: no new events,
  timers or WindowServer calls. Its timing, scroll curve, location and modifiers
  stay exactly as the mouse produced them.
- Inverso taps scroll-wheel events only; pointer movement, clicks and keys never pass
  through it.
- Only vertical deltas are reversed; horizontal deltas and modifier keys are preserved.
- Detection uses scroll phase, momentum phase, and scroll count. It is a heuristic,
  not hardware identification. Pixel-based scrolling alone is not excluded because
  mouse drivers can produce it too. Magic Mouse, remote input, and third-party smooth
  scrolling drivers need testing on the actual setup.
- One daemon per user is allowed. The lock is released automatically when its process
  exits. Its empty file in `~/Library/Application Support/Inverso/daemon.lock` is kept
  to preserve the lock identity; it does not mean a daemon is still running. A second
  daemon started by launchd waits for the first to exit instead of being relaunched
  every ten seconds; a manual `inverso --daemon` in a terminal exits immediately.
- A LaunchAgent written by 0.3 still passes `--smooth` or `--no-smooth`; the daemon
  accepts and ignores it. Run `inverso install` to rewrite it.
- Other scrolling utilities can also reverse events. Enable reversal in only one tool.

## Development checks

```sh
swift test
bash scripts/benchmark.sh
```

The Swift tests require an Xcode toolchain with XCTest.
Tests cover event filtering, delta preservation, permission loss/recovery, instance
locking, plist serialization, and launchctl failure handling without changing the
real background service. Physical-device behavior still needs manual checks:
mouse/trackpad switching with inertia, Shift + wheel, reconnection, sleep/wake,
and revoking/regranting Accessibility permission. On machines where `xcode-select`
points to Command Line Tools, select a full Xcode toolchain for the test command only:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Tests also exercise a real dedicated run loop while the caller is blocked, callback
recovery, resource cleanup, concurrent control operations, and mixed-event stress.
Tests never post events to the desktop.
The benchmark compiles the production transform with optimization and measures
unposted in-memory events. It never takes over the mouse or asks for permissions.
Its numbers measure processing cost, not end-to-end hardware or display latency.

Version 0.4.0 removes the smooth scrolling added in 0.3: Inverso only reverses
wheel events in place again. The [scroll freeze record](docs/research/2026-09-28-scroll-freeze.md)
explains how that layer caused freezes and, in 0.3.1, 1.7 GB of leaked memory.

See the [source study](docs/research/2026-09-24-scrolling.md) and
[validation record](docs/research/2026-09-24-validation.md) for trade-offs,
reproducible checks and the physical-device acceptance checklist.

## Implementation references

The following open-source implementations informed the review; no dependency on
these applications or their private HID/touch APIs was added:

- [UnnaturalScrollWheels, GPL-3.0, `07a61a0`](https://github.com/ther0n/UnnaturalScrollWheels/blob/07a61a0ddc73f37ff2e14a10afe4cec50f69184d/UnnaturalScrollWheels/ScrollInterceptor.swift#L41-L64):
  its alternate detection explains why the existing phase-based heuristic is retained
  for mouse drivers that set `isContinuous`.
- [Scroll Reverser, Apache-2.0, `187bf39`](https://github.com/pilotmoon/Scroll-Reverser/blob/187bf3945b6107cd8486327c6165f32e523535a4/MouseTap.m#L210-L220):
  cache deltas before editing and restore point/fixed-point fields after the line delta,
  since Core Graphics can change those fields together.
- [LinearMouse, MIT, `d82e98f`](https://github.com/linearmouse/linearmouse/blob/d82e98fba7f2b70c63f46f7444300336a96bd54e/LinearMouse/EventTap/EventTap.swift#L104-L134):
  periodically check tap validity/enabled state and explicitly invalidate the tap
  during cleanup. Inverso does this on its dedicated event thread.
