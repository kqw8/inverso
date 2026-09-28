import CoreGraphics
import Darwin
@testable import InversoKit
import XCTest

final class PixelEventFactoryTests: XCTestCase {
    func testOneEventSourceServesEveryEvent() throws {
        var sources = 0
        let factory = try XCTUnwrap(PixelEventFactory(makeSource: {
            sources += 1
            return CGEventSource(stateID: .privateState)
        }))
        for pixels in 1...100 {
            let event = try XCTUnwrap(factory.make(pixels: Int32(pixels)))
            XCTAssertTrue(ScrollTransform.isSynthetic(event))
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
            XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), Int64(pixels))
        }
        XCTAssertEqual(sources, 1)
    }

    // Each private event source pins a read-only WindowServer page for the life
    // of the process; 0.3.1 leaked one per synthetic scroll event (1.7 GB in 4 days).
    func testManyEventsDoNotPinSharedMemory() throws {
        let factory = try XCTUnwrap(PixelEventFactory())
        guard factory.make(pixels: 1) != nil else {
            throw XCTSkip("CoreGraphics event sources need a WindowServer session")
        }
        let before = Self.readOnlySharedRegionCount()
        for _ in 0..<500 {
            autoreleasepool { _ = factory.make(pixels: 1) }
        }
        let growth = Self.readOnlySharedRegionCount() - before
        XCTAssertLessThan(growth, 25, "synthetic events must not map WindowServer memory per event")
    }

    private static func readOnlySharedRegionCount() -> Int {
        var count = 0
        var address: mach_vm_address_t = 0
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_extended_info_data_t()
            // VM_REGION_EXTENDED_INFO_COUNT is a sizeof macro that Swift cannot import.
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<vm_region_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            var objectName: mach_port_t = 0
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    mach_vm_region(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO,
                                   $0, &infoCount, &objectName)
                }
            }
            guard result == KERN_SUCCESS else { return count } // Past the last region.
            let mode = Int32(info.share_mode)
            if (mode == SM_SHARED || mode == SM_TRUESHARED) && info.protection == VM_PROT_READ {
                count += 1
            }
            address += size
        }
    }
}
