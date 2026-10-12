import AudioTapBridgeTests
import XCTest

/// Runs the C test suite and reports each failed check through XCTest.
final class CTests: XCTestCase {
    func testAudioTapBridge() {
        SATAudioTapBridgeRunTests { file, line, expression in
            XCTFail("\(String(cString: file!)):\(line): CHECK(\(String(cString: expression!)))")
        }
    }
}
