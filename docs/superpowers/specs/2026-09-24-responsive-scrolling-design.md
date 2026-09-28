# Responsive scrolling design

> **Superseded in part (2026-09-28, v0.3.2).** The passive context observer, gesture
> anchor and target-PID cancellation described below were removed: they discarded
> notches smooth mode had already consumed. Synthetic events now share one event
> source instead of creating one per event. Discrete distance is lines × 40 since
> 0.3.1, not the 10-pixels/line fallback below. See
> [the scroll freeze record](../../research/2026-09-28-scroll-freeze.md).

## Intent

The user wants a small macOS mouse-wheel reversal binary that feels immediate and
stays reliable, with primary-source research and repeated validation. Rewriting is
authorized if necessary. The existing CLI, vertical-only reversal, trackpad
passthrough, launchd installation and single-instance protection remain useful.
Existing uncommitted work is part of the baseline and must be preserved.

The user subsequently confirmed **both intermittent stalls and mechanical wheel
stepping**. Scope therefore includes optional, enabled-by-default pixel smoothing,
built on the isolated event thread. An explicit direct-reversal mode remains
available for compatibility. The anti-stall work was validated independently first.

## Evidence and alternatives

The baseline already processes events synchronously, rather than polling input.
The installed LaunchAgent declares `ProcessType=Background`. Apple's launchd
manual reserves `Interactive` for work essential to responsiveness. The current
event source, permission IPC and stderr writes share the main run loop. That is a
credible blocking mechanism, not yet proof of the user's observed hardware issue.

1. Keep everything on main and only change launchd classification: small, but
   permission/log stalls can still hold up the input callback.
2. **Selected:** dedicated event run loop, interactive scheduling, bounded in-place
   transform, separate control work, deterministic recovery and teardown.
3. Replace with a display-synchronized smoothing/HID stack: useful for intentionally
   changing the scroll curve, but adds synthetic events, device identity and
   application compatibility concerns without evidence these are needed here.

Primary sources: [Apple event tap callback threading](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)),
[Apple launchd ProcessType](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5),
[UnnaturalScrollWheels event worker and recovery](https://github.com/ther0n/UnnaturalScrollWheels/blob/main/UnnaturalScrollWheels/ScrollInterceptor.swift),
[Scroll Reverser event field preservation](https://github.com/pilotmoon/Scroll-Reverser/blob/master/MouseTap.m).
The research report records pinned revisions, stars and licensing separately.

## Architecture

- `RunLoopWorker` owns a named `.userInteractive` thread and a Core Foundation run
  loop. A dormant source keeps the loop alive without a polling timer. Control
  operations use synchronous run-loop blocks; events themselves never dispatch
  between threads or wait for a control-side lock. Reentrant control calls execute
  immediately. Destruction stops and joins the thread without a self-join.
- `EventTapService` owns the worker and confines tap state to it. System tap
  creation, registration, enable checks, recovery and invalidation run on that
  worker. Permission checks occur on the caller/control thread. A small tap
  connection interface allows lifecycle tests without changing global input or
  requiring Accessibility authorization.
- `DaemonRunner` retains its five-second, tolerant health check on main. It never
  polls mouse input. The worker continues handling events if permission checks or
  reporting block main. Timeout/user-input-disabled callbacks immediately re-enable
  a valid tap; the health check recreates invalid taps and recovers permission loss.
- The original scroll event is returned, with only eligible vertical deltas
  reversed in direct mode. Smooth mode intercepts only unmodified, vertical-only,
  discrete wheel input; it emits marked pixel events. Already-continuous wheels,
  modified/mixed-axis input and trackpad gestures retain the original policy.
- `LaunchAgent` classifies this latency-sensitive service as `Interactive`.

## Smoothing extension (user clarification)

- A constant-state, critically damped engine integrates actual monotonic elapsed
  time. Its nominal response is 80 ms, with exact residual settlement at the end
  of a finite tail. Same-direction input preserves velocity rather than restarting
  an animation. Opposite input discards un-emitted old motion before advancing.
- A 120 Hz run-loop timer is active only while motion is pending. This follows
  LinearMouse's owned-thread approach. It does not poll input, does not cross
  threads per frame, and is explicitly not display-synchronized on every monitor.
- Pixel distance comes from the source point delta when present. A verified local
  probe showed custom source pixelsPerLine is lost when reconstructed from an event.
  Discrete line/fixed-only events therefore use an explicit 10-pixels/line fallback.
  Keep fractional pixels across frames; do not truncate every frame separately.
- Output consists of ordinary continuous pixel wheel events, with phase/momentum
  zero, original location/modifiers and a marker bypassed before classification.
  This does not simulate undocumented trackpad gestures.
- Observe pointer/button/modifier changes passively; only the wheel tap can modify
  input. Ignore passive events older than the latest accepted wheel timestamp.
  Cancel residual motion on button press/release, modifiers, dragging and pointer
  movement beyond three coordinate units from a fixed gesture anchor, trackpad takeover,
  incompatible input, tap disable/rebuild/stop, and scheduling gaps over 500 ms.
  Cancellation intentionally discards remaining distance. No stale wake-up jump.
  The production ContinuousClock advances during sleep. Passive cancellation is
  best effort; the small pointer tolerance trades exact view boundaries for jitter resistance.
- Source event allocation and driver startup must succeed before physical input
  is suppressed. Failures fall back to immediate reversal.
- Tests inject an explicit output sink, fake monotonic time and a fake frame
  driver. Only the public production construction supplies CGEvent.post.
- `install --smooth` / `install --no-smooth` select persisted LaunchAgent args;
  bare install preserves a prior explicit mode, defaulting to smooth for new
  installs. `start` keeps that configuration; status reports the selected mode.

## Constraints

- macOS 13 or later; Swift 6.4 or later; Swift language mode 5.
- Single distributable executable; no third-party runtime dependencies.
- Preserve horizontal axes, timestamp, location, modifiers, phases and source data
  on passthrough/direct events. Synthetic smooth events are explicitly new events.
- Classification remains a documented heuristic, not a promise of hardware identity.
- No installation, service replacement or global input injection during unit tests.

## Acceptance

1. Existing tests remain green, including installer tests.
2. Real CFRunLoop tests demonstrate event processing while the main/control thread
   is blocked, serialized lifecycle operations, reentrancy and clean teardown.
3. Tap tests cover creation failure, disabled/invalid connection recovery, immediate
   disable notification handling, callback passthrough and stop/restart.
4. Mixed-event stress preserves original metadata and expected deltas over many
   iterations, including sub-line mouse deltas and trackpad momentum.
5. A release-only, permission-free benchmark measures transform distributions;
   it explicitly does not claim end-to-end device latency or display smoothness.
6. Release builds for arm64 and x86_64 are checked; the final local binary and
   reproducible verification commands are documented.
7. Independent review precedes final verification. Actual mouse, trackpad,
   sleep/wake, hotplug and busy-system feel remain explicitly identified manual
   acceptance items, not inferred from synthetic tests.
8. Pure-engine and adapter tests cover fractional conservation, irregular frame
   spacing, dense input, immediate direction reversal, cancellation, failed output
   allocation/driver startup, idle driver shutdown and synthetic-loop prevention.
