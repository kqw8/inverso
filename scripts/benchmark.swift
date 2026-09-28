import CoreGraphics
import Darwin
import Dispatch
import Foundation

// Built with the production transform and smoother by benchmark.sh. Events are
// created once and never posted. Validation and fixture allocation are outside timing.
@main
enum TransformBenchmark {
    struct Fixture {
        let name: String
        let event: CGEvent
        let reverses: Bool
        let original: ScrollSample
        let horizontal: ScrollSample
        let flags: CGEventFlags
        let timestamp: UInt64
        let sourceData: Int64

        init(_ name: String, line: Int64 = 2, point: Double = 11, fixed: Double = 0.75,
             field: CGEventField? = nil, value: Int64 = 0, reverses: Bool = true) {
            self.name = name
            self.reverses = reverses
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else {
                fatalError("Could not create unposted fixture")
            }
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: line)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: point)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed)
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -3)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -17)
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.25)
            event.flags = [.maskShift, .maskControl]
            event.timestamp = 9_876_543_210
            // Some macOS versions retain the first explicit source-data value.
            if field != .eventSourceUserData {
                event.setIntegerValueField(.eventSourceUserData, value: 1234)
            }
            if let field { event.setIntegerValueField(field, value: value) }
            self.event = event
            original = ScrollTransform.verticalSample(from: event)
            horizontal = ScrollTransform.horizontalSample(from: event)
            flags = event.flags
            timestamp = event.timestamp
            sourceData = event.getIntegerValueField(.eventSourceUserData)
        }

        func validate(oddReversals: Bool = false) {
            let expected = oddReversals && reverses
                ? ScrollSample(delta: -original.delta, pointDelta: -original.pointDelta,
                               fixedPointDelta: -original.fixedPointDelta)
                : original
            precondition(ScrollTransform.verticalSample(from: event) == expected, "\(name): vertical corruption")
            precondition(ScrollTransform.horizontalSample(from: event) == horizontal, "\(name): horizontal corruption")
            precondition(event.flags == flags && event.timestamp == timestamp, "\(name): metadata corruption")
            precondition(event.getIntegerValueField(.eventSourceUserData) == sourceData, "\(name): source corruption")
        }
    }

    static func main() {
        let fixtures = [
            Fixture("wheel-up"),
            Fixture("wheel-down", line: -3, point: -19, fixed: -1.25),
            Fixture("continuous-wheel", field: .scrollWheelEventIsContinuous, value: 1),
            Fixture("point-only", line: 0, point: 1, fixed: 0),
            Fixture("fixed-only", line: 0, point: 0, fixed: 0.125),
            Fixture("gesture", field: .scrollWheelEventScrollPhase, value: 2, reverses: false),
            Fixture("momentum", field: .scrollWheelEventMomentumPhase, value: 1, reverses: false),
            Fixture("horizontal-only", line: 0, point: 0, fixed: 0, reverses: false),
            Fixture("marked", field: .eventSourceUserData, value: ScrollTransform.syntheticMarker, reverses: false),
        ]
        let batchSize = 256 // Even: reversing each event this many times restores its fields.
        let samples = 1_000
        let warmup = 10_000
        print("Transform CPU cost only; no tap, posting, permissions, device/display latency, or main-thread scheduling.")
        print("Preallocated unposted fixtures; -O; \(warmup) warmup calls/fixture; 3 rounds.")
        print("Percentiles below describe \(samples) batch means of \(batchSize) calls, in ns/event; not individual-event tail latency.")
        print("Timer/loop overhead is included. Validation is outside each timed region.")

        for fixture in fixtures {
            // Odd-count checks prevent an even-count no-op from passing validation.
            precondition(ScrollTransform.reverseMouseWheelEvent(fixture.event) == fixture.reverses,
                         "\(fixture.name): unexpected classification (source data: \(fixture.event.getIntegerValueField(.eventSourceUserData)))")
            fixture.validate(oddReversals: true)
            precondition(ScrollTransform.reverseMouseWheelEvent(fixture.event) == fixture.reverses,
                         "\(fixture.name): unexpected classification after reversal")
            for _ in 0..<warmup { ScrollTransform.reverseMouseWheelEvent(fixture.event) }
            fixture.validate()
        }

        print("| Round | Fixture | Calls | p50 ns | p95 ns | p99 ns | max ns |")
        print("| --- | --- | ---: | ---: | ---: | ---: | ---: |")
        var checksum = 0
        for round in 1...3 {
            for fixture in fixtures {
                var costs = [Double]()
                costs.reserveCapacity(samples)
                var changed = 0
                for _ in 0..<samples {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for _ in 0..<batchSize {
                        if ScrollTransform.reverseMouseWheelEvent(fixture.event) { changed += 1 }
                    }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    costs.append(Double(elapsed) / Double(batchSize))
                    fixture.validate()
                }
                precondition(changed == (fixture.reverses ? samples * batchSize : 0))
                checksum += changed
                costs.sort()
                func percentile(_ fraction: Double) -> Double {
                    costs[Int(ceil(fraction * Double(costs.count))) - 1]
                }
                print(String(format: "| %d | %@ | %d | %.1f | %.1f | %.1f | %.1f |",
                             round, fixture.name, samples * batchSize, percentile(0.50),
                             percentile(0.95), percentile(0.99), costs.last!))
            }
            // Separate mixed-stream throughput includes selection and counting.
            let passes = 100_000 // Even number of transformations per fixture.
            let calls = fixtures.count * passes
            var changed = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<calls {
                if ScrollTransform.reverseMouseWheelEvent(fixtures[index % fixtures.count].event) { changed += 1 }
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            precondition(changed == fixtures.filter(\.reverses).count * passes)
            fixtures.forEach { $0.validate() }
            checksum += changed
            print(String(format: "Round %d mixed throughput: %d calls, %.3f s, %.0f events/s", round, calls, elapsed, Double(calls) / elapsed))
        }
        print("Validated changed-event checksum: \(checksum)")
        SmootherBenchmark.run()
    }
}

/// A separate benchmark for the new smoothing engine. The transform measurements
/// above remain unchanged so they can still be compared with the saved baseline.
private enum SmootherBenchmark {
    private enum Operation {
        case enqueue(delta: Double, time: Double)
        case advance(time: Double)
        case finishGesture
    }

    private struct Scenario {
        let name: String
        let operations: [Operation]
        let gestures: Int
        let enqueues: Int
        let advances: Int
        let distance: Double
        let magnitude: Double

        var updates: Int { enqueues + advances }

        func validate(_ result: Result) {
            precondition(result.accepted == enqueues, "\(name): input was rejected")
            precondition(result.settled == gestures, "\(name): gesture did not settle")
            precondition(result.distance.isFinite && result.magnitude.isFinite,
                         "\(name): nonfinite output")
            // Input totals come from the fixtures, independently of the engine.
            // Tolerance allows only accumulated Double rounding, not pixel loss.
            let tolerance = max(1e-9, magnitude * 1e-12)
            precondition(abs(result.distance - distance) <= tolerance,
                         "\(name): signed distance was not conserved")
            precondition(abs(result.magnitude - magnitude) <= tolerance,
                         "\(name): absolute distance was not conserved")
        }
    }

    private struct Result {
        var accepted = 0
        var settled = 0
        var distance = 0.0
        var magnitude = 0.0
    }

    static func run() {
        let scenarios = [separateGestures(), denseInput()]
        print("")
        print("New smoothing-engine CPU benchmark; separate from the unchanged transform baseline above.")
        print("Virtual input/tick times; no waiting, driver, CGEvent creation/posting, or device/display measurements.")
        print("120 Hz virtual ticks; isolated gestures and 480 Hz dense input; one warmup pass/scenario; 3 rounds.")
        print("Thread CPU time for each whole block, including operation selection, state checks, and checksum accumulation.")
        print("ns/update divides CPU time by enqueue + advance calls; throughput is engine updates/s, not real-time frames/s.")
        print("Fixtures are preallocated. Finite output, complete settlement, and fractional distance are validated outside timing.")
        for scenario in scenarios { scenario.validate(execute(scenario)) }

        print("| Round | Scenario | Gestures | Enqueues | Advances | CPU ms | ns/update | updates/s |")
        print("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for round in 1...3 {
            for scenario in scenarios {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                let result = execute(scenario)
                let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start
                scenario.validate(result)
                precondition(elapsed > 0, "CPU timer did not advance")
                let nanoseconds = Double(elapsed)
                print(String(format: "| %d | %@ | %d | %d | %d | %.3f | %.1f | %.0f |",
                             round, scenario.name, scenario.gestures, scenario.enqueues,
                             scenario.advances, nanoseconds / 1_000_000,
                             nanoseconds / Double(scenario.updates),
                             Double(scenario.updates) * 1_000_000_000 / nanoseconds))
            }
        }
        for scenario in scenarios {
            print(String(format: "Validated %@ per round: %.3f signed / %.3f absolute pixels; %d settled gestures.",
                         scenario.name, scenario.distance, scenario.magnitude, scenario.gestures))
        }
    }

    @inline(never)
    private static func execute(_ scenario: Scenario) -> Result {
        var smoother = ScrollSmoother()
        var result = Result()
        for operation in scenario.operations {
            switch operation {
            case let .enqueue(delta, time):
                if smoother.enqueue(delta: delta, at: time) { result.accepted += 1 }
            case let .advance(time):
                let output = smoother.advance(at: time)
                result.distance += output
                result.magnitude += abs(output)
            case .finishGesture:
                if !smoother.isActive { result.settled += 1 }
            }
        }
        return result
    }

    private static func separateGestures() -> Scenario {
        let gestures = 10_000
        let deltas = [8.0, 13.25, 2.5, 27.75, 0.125, 16.0, -5.5, -11.25, -3.75, -21.0]
        var operations: [Operation] = []
        operations.reserveCapacity(gestures * 12)
        var distance = 0.0
        var magnitude = 0.0
        for gesture in 0..<gestures {
            let time = 1_000_000 + Double(gesture) * 0.2
            let delta = deltas[gesture % deltas.count]
            operations.append(.enqueue(delta: delta, time: time))
            distance += delta
            magnitude += abs(delta)
            for tick in 1...10 {
                operations.append(.advance(time: time + Double(tick) / 120))
            }
            operations.append(.finishGesture)
        }
        return Scenario(name: "separate-wheel-gestures", operations: operations,
                        gestures: gestures, enqueues: gestures, advances: gestures * 10,
                        distance: distance, magnitude: magnitude)
    }

    private static func denseInput() -> Scenario {
        let gestures = 1_000
        let deltas = [0.25, 0.5, 1.0, 1.5, 2.5, 3.75]
        var operations: [Operation] = []
        operations.reserveCapacity(gestures * 41)
        var distance = 0.0
        var magnitude = 0.0
        for gesture in 0..<gestures {
            let start = 1_000_000 + Double(gesture) * 0.25
            let direction = gesture.isMultiple(of: 2) ? 1.0 : -1.0
            // Twenty-four samples at 480 Hz merge with sixteen 120 Hz ticks.
            // Each gesture keeps one direction, then settles before the next.
            for slot in 0...64 {
                let time = start + Double(slot) / 480
                if slot < 24 {
                    let delta = direction * deltas[(slot + gesture) % deltas.count]
                    operations.append(.enqueue(delta: delta, time: time))
                    distance += delta
                    magnitude += abs(delta)
                }
                if slot > 0 && slot.isMultiple(of: 4) {
                    operations.append(.advance(time: time))
                }
            }
            operations.append(.finishGesture)
        }
        return Scenario(name: "dense-wheel-input", operations: operations,
                        gestures: gestures, enqueues: gestures * 24, advances: gestures * 16,
                        distance: distance, magnitude: magnitude)
    }
}
