import XCTest
@testable import TideKit

final class PieceMapTests: XCTestCase {
    func testBitsMSBFirst() {
        let m = PieceMap(count: 10, bits: [0b1000_0001, 0b0100_0000])
        XCTAssertTrue(m.has(0)); XCTAssertTrue(m.has(7)); XCTAssertTrue(m.has(9))
        XCTAssertFalse(m.has(1)); XCTAssertFalse(m.has(8))
        XCTAssertEqual(m.doneCount, 3)
    }
    func testBuckets() {
        let m = PieceMap(count: 8, bits: [0b1111_0000])
        XCTAssertEqual(m.buckets(2), [1, 0])
    }
}
