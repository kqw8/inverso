# Responsive scrolling implementation plan

> **For agentic workers:** use superpowers:executing-plans or
> superpowers:subagent-driven-development; implement and verify each task.

**Goal:** remove avoidable scroll stalls while preserving the tiny binary's input semantics.

**Architecture:** isolate the event tap on a dedicated interactive CFRunLoop thread.
Keep permission and reporting outside that thread and mutate the original event.

**Tech stack:** Swift, CoreGraphics, Foundation, XCTest, launchd, Bash.

**Spec:** [responsive scrolling design](../specs/2026-09-24-responsive-scrolling-design.md).

## Global constraints

- macOS 13 or later; Swift 6.4 or later; Swift language mode 5.
- Single distributable executable; no third-party runtime dependencies.
- Preserve horizontal axes, timestamp, location, modifiers, phases and source data.
- Preserve pre-existing uncommitted modifications. Work in the supplied checkout;
  snapshots of its initial source and diff are saved under `/tmp/inverso-before-session*`.
- Research and implementation are authorized by the user's request. Continue with
  independent implementation/review; do not create additional permission stages.
- Do not commit unrelated pre-existing changes or install a new daemon as part of tests.

## Review focus

- Main thread stalls must not stop the event worker; demonstrate with a semaphore,
  not a main-thread XCTest run-loop wait.
- Rapid stop/start and deinit on the owning thread must not leak or deadlock.
- Failed create/enable and invalid source must not leave a dangling callback context.
- A healthy tap must not be rebuilt on each health check.
- Trackpad, horizontal and marked synthetic events must preserve metadata and deltas.

## Task 1 — event run-loop ownership

Files: create `Sources/InversoKit/RunLoopWorker.swift` and
`Tests/InversoKitTests/RunLoopWorkerTests.swift`.

Interface: `init(name: String = "com.kqw8.inverso.events")`,
`sync<T>(_ operation: @escaping () -> T) -> T`.

- [x] Write tests for thread affinity, sync return values, nested `sync`, ordered
  concurrent submissions, source delivery while the calling thread waits, and
  repeated construction/destruction. A weak reference to the worker must become nil.
- [x] Run focused tests before implementation; missing worker is expected initially.
- [x] Implement a `.userInteractive` Thread capturing a separate state object;
  publish the run loop only after installing the dormant source. Use
  `CFRunLoopPerformBlock`/`CFRunLoopWakeUp`, per-operation autorelease pools and a
  completion semaphore for shutdown. Never schedule a periodic timer.
- [x] Run focused tests and full suite; examine hangs and sanitizer results.

## Task 2 — isolate and verify tap lifecycle

Files: `EventTapService.swift`, new `EventTapConnection.swift`, new
`EventTapServiceTests.swift`; `LaunchAgent.swift`/`LaunchAgentTests.swift`.

Interfaces: `EventTapService` retains its public `start`, `stop`, `isRunning` and
tap-list query API. Internal connection exposes `isValid`, `isEnabled`,
`setEnabled(_:)`, `invalidate()`; a factory receives the callback and binds to the
current run loop. Tests inject a connection only at the system/TCC boundary.

- [x] Add failing behavioral tests for creation on a non-main thread, permission
  checks on caller, transform during control-side blocking, immediate timeout
  recovery, healthy start idempotence, invalid tap replacement and cleanup.
- [x] Add a failing plist test requiring interactive scheduling of the installed
  daemon. Run against the baseline before changing implementation.
- [x] Route lifecycle operations through the worker; keep AX IPC outside. Factory
  failure and enable failure must invalidate resources. Stop is idempotent.
- [x] Change launchd `ProcessType` to `Interactive`, with an explanatory comment.
- [x] Run new tests, full Swift suite and installer tests.

## Task 3 — performance evidence and distribution

Files: new `scripts/benchmark.swift`/`scripts/benchmark.sh`, stress tests,
README and `docs/research/2026-09-24-scrolling.md`.

- [x] Add mixed-event stress cases using actual unposted CGEvents. Check all three
  axes, modifier/source metadata, timestamps and sub-line values.
- [x] Build a standalone release benchmark using the production transform source;
  no permission prompt, event tap registration or event posting. Warm up, measure
  batches/distribution, validate results, print sample count, p50/p95/p99/max.
- [x] Run release benchmarks and record hardware/OS/toolchain and scope limitations.
- [x] Build arm64 and x86_64, inspect universal executable and checksums, run CLI
  help/version/invalid-command smoke checks. Do not replace the installed daemon.
- [x] Document source comparisons, findings, verification results and physical-device
  acceptance procedure. Update README scheduling and toolchain instructions.
- [x] Obtain independent source review; fix material findings with regression tests.
- [x] Run final full suite, installer tests and release validation after fixes.

## Task 4 — smoothing after user clarification

The user confirmed both intermittent stalls and mechanical wheel stepping. The
spec's smoothing extension supersedes the original no-interpolation assumption.

- [x] Add `ScrollSmoother` and deterministic tests for the critically damped engine,
  fractional distance, input between frames, direction changes, stale/reset/invalid
  time and sustained input. Engine uses no CGEvent, thread or timer.
- [x] Add `RunLoopSmoothingDriver` and tests for active-only 120 Hz timing on the
  event worker, stop/restart, and cancellation inside a callback.
- [x] Add `ScrollEventProcessor` with injected clock, driver, event factory and sink;
  test actual unposted CGEvents for eligibility, output fields, conservation,
  passthrough, context cancellation, stale frames and fail-open paths.
- [x] Integrate processor lifecycle with the event tap. Extend the event mask only
  in smooth mode to observe pointer/button/modifier changes for cancellation.
- [x] Add typed CLI argument parsing and persisted `--smooth` / `--no-smooth`
  installation options, preserving explicit prior mode on bare reinstall.
- [x] Update source-study recommendations, README, validation and artifact build.
  Re-review smoothing independently, then run full tests, thread sanitizer,
  installer tests and release verification. Actual feel still requires a device.

## Verification command

Use the installed full Xcode toolchain without changing global selection:

```sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcrun swift test --scratch-path /tmp/inverso-quality-tests --disable-sandbox
bash scripts/test-install.sh
```

Expected: all Swift tests pass and all eight installer scenarios pass. The default
CommandLineTools toolchain can compile the executable but lacks XCTest on this Mac.

## Final evidence

Automated tasks complete. See [validation record](../../research/2026-09-24-validation.md) for the 101-test full and TSAN passes, benchmarks, artifacts, and explicitly pending physical-device acceptance. The existing installed service was not replaced.
