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
    
    func testAddTag() throws {
        let tag = Tag(
            name: "TEST_TAG",
            nodeId: "ns=2;s=Test",
            value: .analog(50.0),
            quality: .good
        )
        
        tagEngine.addTag(tag)
        
        XCTAssertEqual(tagEngine.tagCount, tag.samples.count + 1) // +1 for test tag
        XCTAssertNotNil(tagEngine.getTag(named: "TEST_TAG"))
    }
    
    func testUpdateTag() throws {
        let tagName = "TANK_001.LEVEL_PV"
        let newValue: TagValue = .analog(85.5)
        
        tagEngine.updateTag(name: tagName, value: newValue)
        
        let updatedTag = tagEngine.getTag(named: tagName)
        XCTAssertNotNil(updatedTag)
        XCTAssertEqual(updatedTag?.value.numericValue, 85.5)
    }
    
    func testRemoveTag() throws {
        let tagName = "TANK_001.LEVEL_PV"
        let initialCount = tagEngine.tagCount
        
        tagEngine.removeTag(named: tagName)
        
        XCTAssertEqual(tagEngine.tagCount, initialCount - 1)
        XCTAssertNil(tagEngine.getTag(named: tagName))
    }
    
    func testFilterTagsByQuality() throws {
        let goodTags = tagEngine.getTags(withQuality: .good)
        XCTAssertTrue(goodTags.allSatisfy { $0.quality == .good })
    }
}
