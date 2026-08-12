import XCTest
@testable import Marker

final class CodeBlockTextTests: XCTestCase {
    func testCopiesOnlyFencedBody() throws {
        let source = """
        ```swift
        let answer = 42
        print(answer)
        ```
        """ as NSString

        XCTAssertEqual(try body(from: source), "let answer = 42\nprint(answer)")
    }

    func testPreservesInternalCRLFLineEndings() throws {
        let source = "```text\r\none\r\ntwo\r\n```\r\n" as NSString

        XCTAssertEqual(try body(from: source), "one\r\ntwo")
    }

    func testOmitsBlockquotePrefixes() throws {
        let source = """
        > ```swift
        > let answer = 42
        > ```
        """ as NSString

        XCTAssertEqual(try body(from: source), "let answer = 42")
    }

    func testEmptyFenceCopiesEmptyString() throws {
        XCTAssertEqual(try body(from: "```\n```" as NSString), "")
    }

    private func body(from source: NSString) throws -> String {
        let document = MarkdownParser.parse(source)
        let region = try XCTUnwrap(document.codeRegions.first)
        return CodeBlockText.body(of: region, in: document, source: source)
    }
}
