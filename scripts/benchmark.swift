import CoreGraphics
import Darwin
import Dispatch
import Foundation

// Built with the production transform by benchmark.sh. Events are
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
    }
}
