# Scroll event research — 2026-09-24

This review inspected source snapshots downloaded from the repositories' default branches on 2026-09-24. The commit links below pin what was actually read. Star counts were retrieved from GitHub's repository API on that date, rather than estimated from rounded website badges. Popularity establishes adoption, not a performance or correctness guarantee. These snapshots were studied, not built or benchmarked locally.

## Projects and reuse boundaries

| Project | Exact stars | Inspected commit | License in that snapshot | Main relevance |
| --- | ---: | --- | --- | --- |
| [Mos](https://github.com/Caldis/Mos) | [21,479](https://api.github.com/repos/Caldis/Mos) | [`8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2`](https://github.com/Caldis/Mos/tree/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2) | [CC BY-NC 4.0](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/LICENSE) | Display-linked interpolation, axis settings, recovery |
| [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) | [10,990](https://api.github.com/repos/noah-nuebling/mac-mouse-fix) | [`46cd62d79aa1a638535b15d6167fbe60d1485ae4`](https://github.com/noah-nuebling/mac-mouse-fix/tree/46cd62d79aa1a638535b15d6167fbe60d1485ae4) | [Custom MMF License](https://github.com/noah-nuebling/mac-mouse-fix/blob/46cd62d79aa1a638535b15d6167fbe60d1485ae4/License) | Gesture simulation, smoothing, scheduling pitfalls |
| [LinearMouse](https://github.com/linearmouse/linearmouse) | [6,892](https://api.github.com/repos/linearmouse/linearmouse) | [`9a9889d29bfae6a4d0432125cada18f7bf96ac07`](https://github.com/linearmouse/linearmouse/tree/9a9889d29bfae6a4d0432125cada18f7bf96ac07) | [MIT](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LICENSE) | Dedicated event thread, transform pipeline, device identity |
| [UnnaturalScrollWheels](https://github.com/ther0n/UnnaturalScrollWheels) | [4,215](https://api.github.com/repos/ther0n/UnnaturalScrollWheels) | [`07a61a0ddc73f37ff2e14a10afe4cec50f69184d`](https://github.com/ther0n/UnnaturalScrollWheels/tree/07a61a0ddc73f37ff2e14a10afe4cec50f69184d) | [GPL-3.0](https://github.com/ther0n/UnnaturalScrollWheels/blob/07a61a0ddc73f37ff2e14a10afe4cec50f69184d/LICENSE) | Small reversal implementation and wake recovery |
| [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) | [3,612](https://api.github.com/repos/pilotmoon/Scroll-Reverser) | [`187bf3945b6107cd8486327c6165f32e523535a4`](https://github.com/pilotmoon/Scroll-Reverser/tree/187bf3945b6107cd8486327c6165f32e523535a4) | [Apache-2.0](https://github.com/pilotmoon/Scroll-Reverser/blob/187bf3945b6107cd8486327c6165f32e523535a4/LICENSE) | Precise reversal semantics and richer classification |

Mos and Mac Mouse Fix have publicly readable source, but their current licenses are not ordinary permissive open-source licenses. Mos restricts commercial use. MMF adds attribution and executable-publication conditions, including a substantial-improvement exception to monetization-system requirements. They are architectural references here; this work does not copy their code. USW is likewise a reference, not a source of code for Inverso's MIT implementation. Reusing substantial LinearMouse or Scroll Reverser code would still require preserving the relevant notices and complying with the upstream license.

## Anti-stall work and synthetic smoothing are separate

Direct reversal can return the original event immediately after negating its deltas. It preserves the incoming event cadence and does not need an animation timer. Isolating that callback from permission checks, logging, and other control work reduces opportunities for this daemon to delay delivery. It cannot make a physically discrete wheel emit trackpad-like motion, guarantee scheduling during system overload, or fix another application's rendering stalls.

Synthetic smoothing consumes wheel events and produces a new timed stream of pixel events. It deliberately changes cadence and often adds momentum. It needs stop/cancel behavior, gesture phases, fractional-delta handling, synthetic-event tagging, and application compatibility work. Mos, Mac Mouse Fix, and the inspected LinearMouse snapshot contain those additional systems. Adding only a timer and a low-pass filter would omit substantial behavior present in these mature implementations.

For Inverso's reversal path, the strongest fit is a small, dedicated event thread with in-place transformation and lightweight recovery. The user subsequently confirmed both intermittent stalls and discrete stepping, using a MCHOSE A7 V2 in WeChat and Chrome. Smooth interpolation is therefore implemented as a separate optional layer after validating that reversal path.

## What the source actually does

### LinearMouse: the closest scheduling reference

[`EventThread.swift`, lines 41–63](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/EventTap/EventThread.swift#L41-L63) creates a named `Thread`, assigns `.userInteractive`, installs a keep-alive source, and runs its own run loop. Its dispatch helpers use `CFRunLoopPerformBlock` and `CFRunLoopWakeUp`; timers and transformer state are confined to that event thread. This directly supports isolating Inverso's event delivery from the main control loop. Cross-thread teardown and startup synchronization remain implementation responsibilities; a thread by itself does not solve lifetime races.

[`EventTap.swift`, lines 35–48 and 122–156](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/EventTap/EventTap.swift#L35-L48) re-enables timeout-disabled taps, and uses a five-second run-loop timer to detect invalid or disabled taps. Cleanup is scheduled onto the owning run loop. That watchdog is a safety net; it does not justify expensive work in normal event callbacks. The upstream timeout path itself logs errors, so Inverso can keep a stricter separation by reporting counters later from its control loop.

[`ReverseScrollingTransformer.swift`, lines 16–28](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/EventTransformer/ReverseScrollingTransformer.swift#L16-L28) transforms the existing event and bypasses its own synthetic events. Device identification is substantially more involved than checking a scroll flag: [`DeviceManager.swift`, lines 920–932](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/Device/DeviceManager.swift#L920-L932) obtains the associated HID event, extracts its sender ID, and looks up a device snapshot. The code specifically avoids reading a live dictionary while another thread may remove devices. This is useful for per-device settings, but would expand Inverso's IOKit and private-interface surface.

Its smoothing path is separate: [`SmoothedScrollingTransformer.swift`, lines 12–33, 78–125 and 239–308](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/EventTransformer/SmoothedScrollingTransformer.swift#L12-L33) uses a nominal 120 Hz event-thread timer and monotonic system uptime, suppresses the axes it handles, posts marked synthetic pixel events, tracks phases and subpixel remainders, and stops the timer when the engine becomes idle. [`SmoothedScrollingEngine.swift`, lines 200–228 and 294–320](https://github.com/linearmouse/linearmouse/blob/9a9889d29bfae6a4d0432125cada18f7bf96ac07/LinearMouse/EventTransformer/SmoothedScrollingEngine.swift#L200-L228) accounts for elapsed time and opposing momentum. Strength: explicit state and independently testable smoothing. Cost: considerably more state and behavioral choices than reversal requires.

### Scroll Reverser: preserve the original event's representations

[`MouseTap.m`, lines 91–102 and 212–230](https://github.com/pilotmoon/Scroll-Reverser/blob/187bf3945b6107cd8486327c6165f32e523535a4/MouseTap.m#L212-L230) highlights a critical CoreGraphics detail: setting a line delta can also modify the point and fixed-point fields. It captures the original values first, then writes line deltas before restoring transformed fixed-point and point deltas. This supports Inverso's existing all-representations reversal and the need to test actual `CGEvent` fields, not only arithmetic in a detached value type.

Its device heuristic is richer than a continuous flag: [`MouseTap.m`, lines 130–155](https://github.com/pilotmoon/Scroll-Reverser/blob/187bf3945b6107cd8486327c6165f32e523535a4/MouseTap.m#L130-L155) classifies noncontinuous input as mouse; for continuous input, two touches within 222 ms suggest trackpad, and a sufficiently old touch with normal momentum phase suggests mouse. Ambiguous input inherits the preceding classification. This handles some continuous mice, but depends on gesture observations and history. The source uses two session taps on the main run loop, not a dedicated event thread ([lines 288–316](https://github.com/pilotmoon/Scroll-Reverser/blob/187bf3945b6107cd8486327c6165f32e523535a4/MouseTap.m#L288-L316)). It is a useful semantics reference, not evidence that every mature project isolates its tap.

### Mos: interpolation adds display and lifecycle machinery

[`ScrollCore.swift`, lines 53–93](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/Mos/ScrollCore/ScrollCore.swift#L53-L93) skips its synthetic events, bypasses trackpad-like input and some remotely smoothed input, and clears poster state on tap-disable boundaries. [`ScrollEvent.swift`, lines 61–81](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/Mos/ScrollCore/ScrollEvent.swift#L61-L81) uses phase/count heuristics with a Logitech Options process exception.

[`ScrollPoster.swift`, lines 184–224 and 399–478](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/Mos/ScrollCore/ScrollPoster.swift#L399-L478) uses `CVDisplayLink`; each frame advances toward the accumulated target by a configured fraction, filters the result, manages tracking/momentum phases, and ends settled motion. Its state lock and captured configuration separate the display callback from main-thread configuration reads. [`ScrollPoster.swift`, lines 298–359](https://github.com/Caldis/Mos/blob/8a2fd112e2af444c37ca5f65f42e9bd19c08a5c2/Mos/ScrollCore/ScrollPoster.swift#L298-L359) also has a five-second health check for a display link that reports running but has stopped calling back, plus refresh-rate rechecks after display changes. Strength: actual smoothing and explicit recovery. Cost: display lifecycle, synchronization, extra events, and phase compatibility. These mechanisms are unnecessary for an in-place reversal daemon.

### Mac Mouse Fix: useful lessons from a larger event system

[`GlobalEventTapThread.m`, lines 15–26 and 63–66](https://github.com/noah-nuebling/mac-mouse-fix/blob/46cd62d79aa1a638535b15d6167fbe60d1485ae4/Helper/Utility/GlobalEventTapThread.m#L15-L26) discusses responsiveness and ordering problems when input processing crosses threads; it creates an interactive-QoS `NSThread`. This is architectural evidence, not a measured speedup for Inverso. The scrolling implementation still has its own queue: [`Scroll.m`, lines 204–249](https://github.com/noah-nuebling/mac-mouse-fix/blob/46cd62d79aa1a638535b15d6167fbe60d1485ae4/Helper/Core/Scroll/Scroll.m#L204-L249) handles timeout recovery, bypasses several non-wheel-like cases, copies intercepted events, queues processing, and suppresses the originals. It would be inaccurate to describe all MMF scrolling as already confined to one thread.

Its animator uses a display-link abstraction ([`TouchAnimatorBase.swift`, lines 69–85](https://github.com/noah-nuebling/mac-mouse-fix/blob/46cd62d79aa1a638535b15d6167fbe60d1485ae4/Helper/Core/Touch/TouchAnimatorBase.swift#L69-L85)); output includes explicit momentum termination and simulated touch cancellation for application compatibility ([`Scroll.m`, lines 916–1015](https://github.com/noah-nuebling/mac-mouse-fix/blob/46cd62d79aa1a638535b15d6167fbe60d1485ae4/Helper/Core/Scroll/Scroll.m#L916-L1015)). Strength: extensive gesture behavior. Cost: substantial scheduling, synthesis, and compatibility complexity. Inverso should borrow the ownership lesson, not this pipeline.

### UnnaturalScrollWheels: small scope with recovery tradeoffs

[`ScrollInterceptor.swift`, lines 25–80](https://github.com/ther0n/UnnaturalScrollWheels/blob/07a61a0ddc73f37ff2e14a10afe4cec50f69184d/UnnaturalScrollWheels/ScrollInterceptor.swift#L25-L80) reverses incoming line deltas, offers continuous-only and phase/count classification alternatives, and handles both tap-disable notifications. It does not explicitly preserve all point/fixed-point representations in that reversal block. Its comments acknowledge uncertainty in the alternate classification.

[`ScrollInterceptor.swift`, lines 96–135 and 141–201](https://github.com/ther0n/UnnaturalScrollWheels/blob/07a61a0ddc73f37ff2e14a10afe4cec50f69184d/UnnaturalScrollWheels/ScrollInterceptor.swift#L96-L135) runs a CF run loop on a global interactive dispatch worker, re-enables or rebuilds taps, and retries around wake. Strength: narrow focus and practical recovery. Tradeoff: long-lived run loops on shared dispatch workers and delayed restart sequencing are less explicit than one owned thread with serialized lifecycle operations. Its code is evidence of an approach, not a concurrency proof.

## Classification limits and recommendations for Inverso

Apple defines [`scrollWheelEventIsContinuous`](https://developer.apple.com/documentation/coregraphics/cgeventfield/scrollwheeleventiscontinuous) in the installed CoreGraphics SDK as pixel-based versus line-based scrolling. It does not identify physical hardware. The SDK's `scrollWheelEventScrollCount` entry has no explanatory contract beyond an internal issue reference; it is not a documented guarantee that a device is a trackpad. Mos and USW using it provide precedent for a heuristic, not proof. Continuous mice, vendor-generated events, remote desktops, drawing tablets, and mixed-device input require explicit care.

For the current small binary:

1. Preserve immediate, in-place reversal and all original delta representations. Keep normal event handling free of logging, permission IPC, filesystem work, and blocking handoffs to the main queue.
2. Give the tap one named interactive-QoS thread and one run loop. Create, check, recover, and destroy its resources on that owner. Keep permission checks and reporting on the control loop. Account for thread startup, teardown, restart, and callback-context lifetime explicitly.
3. Recover promptly from disable notifications, with a lightweight periodic fallback for silent disable or invalidation. A watchdog must distinguish an idle user from a broken tap; absence of scroll events alone is not failure evidence.
4. Describe the current classification as conservative wheel detection. Skipping ambiguous input protects trackpad behavior but can miss mice whose drivers emit gesture-like phase/count metadata. Continuous input alone is not excluded by Inverso. Do not claim universal physical-device recognition.
5. Keep interpolation separate from the anti-stall mechanism. After the user confirmed the stepping symptom, add an optional engine with monotonic elapsed time, fractional-distance accounting, direction-change handling, synthetic-loop prevention, context cancellation and idle timer shutdown. Ordinary phase-free pixel output avoids claiming trackpad gesture compatibility.

## Implemented smoothing choices after clarification

The selected engine is a constant-space, critically damped response with an 80 ms
finite tail; same-direction input adds distance without restarting acceleration.
A 120 Hz timer lives on the event worker and stops when idle. This takes the simpler
owned-thread scheduling approach seen in LinearMouse; it does not claim display-link
synchronization at arbitrary monitor refresh rates.

Fresh pixel events carry a private synthetic marker. Continuous native input,
trackpad phases, modifiers and mixed axes retain direct/passthrough behavior. A
separate listen-only tap watches context changes, avoiding synchronous pointer
filtering. Timestamp checks handle reordering between the two tap sources. A small,
fixed three-unit movement tolerance avoids canceling an entire notch due to hand
jitter; deliberate context changes cancel undelivered motion.

The production clock uses [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock),
which advances through sleep. A 500 ms scheduling gap discards old motion instead
of flushing it on wake. Unit tests simulate that gap; actual sleep/wake feel is a
separate device check.

A local CoreGraphics probe showed that reconstructing a source from an event loses
a custom `pixelsPerLine`: original values 10, 16 and 20 all reconstructed as 10,
although generated point deltas correctly retained 10, 16 and 20. Version 0.3.0
therefore used point deltas with a 10-pixels-per-line fallback. Subsequent user
feedback and AppKit/Chromium source checks showed that this did not preserve
application travel when changing from line events to pixel events. Version 0.3.1
uses fractional lines ×40 and adds a configurable gain; see the
[distance correction record](2026-09-24-scroll-speed.md) for evidence and limits.
Direct mode preserves the original representations. No upstream smoothing code was copied.

These recommendations address causes the daemon controls. Demonstrating an improvement in a particular mouse or application's perceived smoothness still requires a real-device comparison; repository popularity, source inspection, and unit tests cannot establish that result.
