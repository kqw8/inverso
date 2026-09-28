import CoreFoundation
import Foundation

/// Owns an event run loop that remains responsive while the calling thread blocks.
/// Operations must not synchronously wait for their caller (for example, main).
final class RunLoopWorker {
    private let state: State
    private let thread: Thread

    init(name: String = "com.kqw8.inverso.events") {
        let state = State()
        self.state = state
        // Capture the state, not this owner: deinit must be able to stop the loop.
        let thread = Thread { state.run() }
        thread.name = name
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        state.ready.wait()
    }

    func sync<T>(_ operation: @escaping () -> T) -> T {
        if Thread.current === thread {
            return autoreleasepool(invoking: operation)
        }
        let completed = DispatchSemaphore(value: 0)
        let result = ResultBox<T>()
        CFRunLoopPerformBlock(state.runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result.value = autoreleasepool(invoking: operation)
            completed.signal()
        }
        CFRunLoopWakeUp(state.runLoop)
        completed.wait()
        return result.value!
    }

    deinit {
        let loop = state.runLoop!
        if Thread.current === thread {
            // The current callback can finish and let the loop unwind naturally.
            CFRunLoopStop(loop)
        } else {
            // Enqueue stop so shutdown is not lost between ready and CFRunLoopRun.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
            state.finished.wait()
        }
    }

    private final class ResultBox<T> {
        // The completion semaphore publishes this value to the calling thread.
        var value: T?
    }

    private final class State {
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // Written once before ready is signaled, then read without further mutation.
        private(set) var runLoop: CFRunLoop!

        func run() {
            autoreleasepool {
                let loop = CFRunLoopGetCurrent()!
                var context = CFRunLoopSourceContext()
                context.perform = { _ in }
                let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)!
                // A dormant source keeps the loop alive without a polling timer.
                CFRunLoopAddSource(loop, source, .defaultMode)
                runLoop = loop
                ready.signal()
                CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
            finished.signal()
        }
    }
}
