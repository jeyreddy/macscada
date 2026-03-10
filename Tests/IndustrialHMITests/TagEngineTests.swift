import XCTest
@testable import IndustrialHMI

final class TagEngineTests: XCTestCase {

    var tagEngine: TagEngine!

    override func setUpWithError() throws {
        tagEngine = TagEngine()
    }

    override func tearDownWithError() throws {
        tagEngine = nil
    }

    // MARK: - addTag

    func testAddTag() throws {
        let before = tagEngine.tagCount
        let tag = Tag(name: "TEST_ADD", nodeId: "ns=2;s=TestAdd",
                      value: .analog(50.0), quality: .good)
        tagEngine.addTag(tag)
        XCTAssertEqual(tagEngine.tagCount, before + 1)
        XCTAssertNotNil(tagEngine.getTag(named: "TEST_ADD"))
    }

    // MARK: - updateTag

    func testUpdateTag() throws {
        let tag = Tag(name: "TEST_UPD", nodeId: "ns=2;s=TestUpd",
                      value: .analog(10.0), quality: .good)
        tagEngine.addTag(tag)
        tagEngine.updateTag(name: "TEST_UPD", value: .analog(85.5), quality: .good)
        let updated = tagEngine.getTag(named: "TEST_UPD")
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.value.numericValue, 85.5)
    }

    // MARK: - removeTag

    func testRemoveTag() throws {
        let tag = Tag(name: "TEST_REM", nodeId: "ns=2;s=TestRem",
                      value: .analog(0.0), quality: .good)
        tagEngine.addTag(tag)
        let after = tagEngine.tagCount
        tagEngine.removeTag(named: "TEST_REM")
        XCTAssertEqual(tagEngine.tagCount, after - 1)
        XCTAssertNil(tagEngine.getTag(named: "TEST_REM"))
    }

    // MARK: - quality filter

    func testFilterTagsByQuality() throws {
        let tagA = Tag(name: "TEST_GOOD", nodeId: "ns=2;s=TestGood",
                       value: .analog(1.0), quality: .good)
        tagEngine.addTag(tagA)
        let goodTags = tagEngine.getTags(withQuality: .good)
        XCTAssertTrue(goodTags.allSatisfy { $0.quality == .good })
    }

    // MARK: - historianEnabled flag

    func testHistorianEnabledDefaultIsTrue() throws {
        let tag = Tag(name: "TEST_HIST", nodeId: "ns=2;s=TestHist")
        XCTAssertTrue(tag.historianEnabled)
    }

    func testHistorianCanBeDisabled() throws {
        let tag = Tag(name: "TEST_NOHIST", nodeId: "ns=2;s=TestNoHist",
                      historianEnabled: false)
        XCTAssertFalse(tag.historianEnabled)
    }
}
