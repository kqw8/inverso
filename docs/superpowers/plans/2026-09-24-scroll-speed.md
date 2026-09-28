# Scroll distance correction and adjustable speed

The user confirmed that one notch travels too little, rather than that the response
is delayed. The installed 0.3.0 binary remains unchanged during development.

Evidence: an unposted AppKit/CGEvent probe maps a line event with line=1, point=10,
fixed=1 to a nonprecise NSEvent delta of 1; a continuous 10-pixel event has delta 10.
Chromium multiplies nonprecise fixed-point/NSEvent delta by 40, but uses continuous
point deltas directly. Preserving a discrete CG point field was insufficient to
preserve application travel. Separate probes also reproduced canceled motion when
only a noncontext flag or unknown target PID changed.

## Selected behavior

- Discrete smoothing uses fixed-point lines × 40, then integer lines × 40 if fixed
  is absent, then point-only fallback. The 80 ms timing remains unchanged.
- Ignore noncontext flag changes and preserve a known target across unknown PID
  observations. Two different known targets still cancel pending motion.
- `inverso speed` queries and `inverso speed 1.5` changes a finite multiplier in
  [0.25, 4]. Default 1.0 uses the corrected distance policy. Only eligible smooth
  wheel output is scaled; trackpad/native continuous/shortcut passthrough is unchanged.
- Store the preference atomically in `~/Library/Application Support/Inverso/settings.json`.
  Existing five-second control-thread health checks reload it; the input thread never
  reads files. A change cancels the previous-speed tail, then applies to subsequent
  input. Invalid/unreadable settings retain the last valid value and report once.
- Future speed tuning changes configuration only, so it does not alter binary
  signatures or require reauthorization. Installing the new executable may still
  require macOS approval; do not claim otherwise.

## Tasks and evidence

- [x] Processor: RED→GREEN conversion, acceleration/fractional values, 1.5× gain,
  unchanged passthrough, noncontext flags, unknown/known target transitions.
- [x] Configuration and CLI: RED→GREEN numeric/JSON validation, atomic roundtrip,
  missing defaults, malformed errors, argument rejection before side effects.
- [x] Runtime: RED→GREEN control-thread loading, speed application before startup,
  live changes without tap reconstruction, retention of last-good settings.
- [x] Independent review, complete Swift tests, relevant TSAN, installer tests,
  release builds and native/Intel CLI smoke checks.
- [x] Package 0.3.1 separately and document exact measurement limits and install
  steps. Do not silently replace or re-sign the currently authorized installation.

## Sources

- [Chromium conversion](https://github.com/chromium/chromium/blob/main/components/input/web_input_event_builders_mac.mm#L478-L575)
- [Chromium 40-pixel constant](https://github.com/chromium/chromium/blob/main/ui/events/cocoa/cocoa_event_utils.h#L15-L17)
- [Apple nonprecise delta guidance](https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay)

This models Chromium's discrete-wheel distance and gives users a tuning control;
it does not establish WeChat's internal scale or measure this physical mouse.
