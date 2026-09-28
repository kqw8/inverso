# Inverso

`inverso` is a small macOS CLI daemon that reverses and smooths a physical mouse
wheel while leaving trackpad-like scrolling alone.

It is intentionally not a menu bar app. Install it once, let launchd keep it running, and control it from the terminal.

Requires macOS 13 or later. Source builds require Swift 6.4 or later.

## Install

### Quick install

No Xcode required. This downloads the latest universal binary from GitHub Releases, verifies its checksum, and installs it to `/usr/local/bin`:

```sh
curl -fsSL https://raw.githubusercontent.com/kqw8/Inverso/main/scripts/install.sh | bash
```

Then start the background service:

```sh
inverso install
inverso install --smooth
inverso install --no-smooth
```

### Build from source

For local changes, build and copy the executable to a stable location before registering the service:

```sh
git clone https://github.com/kqw8/Inverso.git
cd Inverso
swift build -c release
INVERSO_BUILD_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$INVERSO_BUILD_DIR/inverso" "$HOME/.local/bin/inverso"
"$HOME/.local/bin/inverso" install
```

Add `~/.local/bin` to your `PATH`, or use the full executable path for the commands below.
The LaunchAgent stores the executable's absolute path. Registering a binary inside `.build`
would make the service stop working after that directory is cleaned. After rebuilding,
copy the new binary and run its `install` command again to reload the service.

## Commands

```sh
inverso install
inverso status
inverso speed
inverso speed 1.5
inverso permission
inverso stop
inverso start
inverso uninstall
```

`install` enables start-at-login by default.
New installations enable smooth scrolling. Bare `install` preserves an existing
mode; `install --smooth` enables it explicitly and `install --no-smooth` selects
immediate reversal without interpolation. These commands reload the service.
`status` reports the configured mode, which may differ from an older running binary
until it is replaced and the service reinstalled.

`speed` shows the smooth-scroll distance multiplier. `speed 1.5` makes each eligible
wheel movement travel 50% farther than the normal `1.0` setting; `speed 1` restores
normal distance. Values from `0.25` to `4` are supported. A running 0.3.1+ daemon
loads the setting at its next health check, normally about five seconds later.
Changing speed does not restart the daemon or change its executable/signature.
The setting is stored in `~/Library/Application Support/Inverso/settings.json`
and is retained by `uninstall`. Direct mode and native trackpad scrolling are not scaled.
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
Repeated identical failures are logged once until the state changes. Each log line
starts with a local timestamp, and the health check reports when and how often macOS
disabled the tap for a slow callback. If smooth mode cannot create its event source,
wheel input is reversed directly and smoothing is retried at each health check.
Logs are in `~/Library/Logs/inverso.err.log` and `~/Library/Logs/inverso.out.log`.

## Notes

Inverso handles ordinary physical mouse-wheel events. Trackpad-like events are passed through unchanged.

- Smooth mode turns unmodified, vertical-only, discrete wheel input into continuous
  pixel scrolling. A critically damped response uses elapsed time, settles its tail
  about 80 ms after the last input, and preserves fractional distance across frames.
  The 120 Hz frame timer stops when idle; it is not a mouse polling loop or a promise
  of display synchronization on every monitor.
- Every synthetic event comes from one event source created when the tap starts.
  The scroll callback itself never calls WindowServer, which is waiting for its answer.
- A notch that smooth mode has taken over is always delivered: pointer movement,
  clicks, dragging and modifier keys never discard it. Only a direction change, a
  speed change, trackpad or native gesture input, modified or mixed-axis wheel input,
  or a stall of 0.5 s or more ends the remaining tail early.
- Inverso taps scroll-wheel events only; pointer movement, clicks and keys never pass
  through it.
- Already-continuous wheels, modified input and mixed-axis events use direct
  reversal, avoiding double smoothing and preserving shortcut behavior.
- Discrete wheel input uses fractional line distance × 40, matching Chromium's
  wheel-to-pixel convention; rounded integer lines are the fallback, followed by
  point-only input when neither line representation exists. This preserves
  fractional acceleration without assuming a discrete CG point is a screen pixel.
  Other applications may use different line heights; use `speed` to tune the feel.
- Direct mode preserves the original event's timing and scroll curve.
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
- Other scrolling utilities can also reverse events. Enable reversal in only one tool.

## Development checks

```sh
swift test
bash scripts/test-install.sh
bash scripts/benchmark.sh
```

The Swift tests require an Xcode toolchain with XCTest. Installer tests use temporary
files and mocked downloads/sudo; they never install or execute a downloaded binary.
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
A regression test counts the test process's read-only shared memory regions to prove
that synthetic scroll events share one event source.
Smoothing tests inject a clock, frame driver and output sink; they do not post events
to the desktop. Actual CoreGraphics event-source fixtures need an interactive macOS
session and may be unavailable inside a restricted sandbox.
The benchmark compiles the production transform with optimization and measures
unposted synthetic events. It never takes over the mouse or asks for permissions.
Its numbers measure processing cost, not end-to-end hardware or display latency.

Version 0.3.1 corrects the short wheel distance in 0.3.0 and adds live speed tuning.
See the [distance correction record](docs/research/2026-09-24-scroll-speed.md).

Version 0.3.2 fixes intermittent scroll freezes and vanished notches in smooth mode:
0.3.1 created a WindowServer event source for every synthetic event (1.7 GB after four
days of use) and discarded consumed notches when the pointer moved.
See the [scroll freeze record](docs/research/2026-09-28-scroll-freeze.md).

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
