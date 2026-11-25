import XCTest
@testable import com_awareframework_ios_core

final class SQLiteEngineSaveTests: XCTestCase {
    func testSaveReportsAnUnavailableDatabase() {
        let engine = SQLiteEngine(Engine.EngineConfig())
        let finished = expectation(description: "save reports its result")

        engine.save([AccelerometerDbModelSQLite(x: 0, y: 0, z: 0)]) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 1)
    }
}
