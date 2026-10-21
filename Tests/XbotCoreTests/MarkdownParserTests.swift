import XCTest
@testable import XbotCore

final class MarkdownParserTests: XCTestCase {
    func testCodeAndMermaidAreSeparateBlocks() {
        XCTAssertEqual(MarkdownParser.parse("```swift\nlet x = 1\n```\n\n```mermaid\ngraph TD; A-->B\n```"), [.code(language: "swift", text: "let x = 1"), .mermaid("graph TD; A-->B")])
    }
    func testTableAlignmentEscapedPipesAndInlineCode() {
        let blocks = MarkdownParser.parse("| A | B | C |\n| :--- | :---: | ---: |\n| a\\|b | `x|y` | 3 |")
        XCTAssertEqual(blocks, [.table(headers: ["A", "B", "C"], rows: [["a|b", "`x|y`", "3"]], alignments: [.leading, .center, .trailing])])
    }
    func testHeadingsListsQuotesAndImages() {
        let blocks = MarkdownParser.parse("### Title\n\n1. first\n  - child\n> quote\n> next\n![alt](/api/file.png)\n\n---")
        XCTAssertEqual(blocks, [.heading(3, "Title"), .listItem(marker: "1.", text: "first", indent: 0), .listItem(marker: "•", text: "child", indent: 1), .quote("quote\nnext"), .image(alt: "alt", url: "/api/file.png"), .rule])
    }
    func testStreamingUnclosedFenceAndCRLF() {
        XCTAssertEqual(MarkdownParser.parse("~~~python\r\nprint('ok')"), [.code(language: "python", text: "print('ok')")])
    }
    func testOrdinaryPipesDoNotCreateTables() {
        XCTAssertEqual(MarkdownParser.parse("a | b\nordinary text"), [.paragraph("a | b\nordinary text")])
    }
    func testImageTitleAndFencedHtmlStayInert() {
        XCTAssertEqual(MarkdownParser.parse("![图](https://example.com/a.png \"title\")"), [.image(alt: "图", url: "https://example.com/a.png")])
        XCTAssertEqual(MarkdownParser.parse("```html\n<script>alert(1)</script>\n```"), [.code(language: "html", text: "<script>alert(1)</script>")])
    }
}
