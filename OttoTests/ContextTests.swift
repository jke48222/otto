//
//  ContextTests.swift
//  Otto
//

import AppKit
import ImageIO
import Network
import UniformTypeIdentifiers
import XCTest
@testable import Otto

final class ContextTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OttoContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Text files

    func testLoadsUTF8TextFileWithBadge() async throws {
        let contents = "Hello, Otto — café ☕️\nsecond line\n"
        let url = try write(contents, named: "cat-meme.txt")

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.displayName, "cat-meme.txt")
        XCTAssertEqual(attachment.badge, "TXT")
        XCTAssertEqual(attachment.sourceURL, url)
        XCTAssertEqual(attachment.payload, .text(contents))
        XCTAssertEqual(attachment.byteCount, contents.utf8.count)
        XCTAssertEqual(attachment.contentBlocks(), [[
            "type": "document",
            "source": ["type": "text", "media_type": "text/plain", "data": .string(contents)],
            "title": "cat-meme.txt",
        ]])
    }

    func testSourceFilesUseExtensionBadges() async throws {
        let swift = try await AttachmentLoader.load(fileURL: write("let x = 1\n", named: "main.swift"))
        XCTAssertEqual(swift.kind, .text)
        XCTAssertEqual(swift.badge, "SWIF")

        let json = try await AttachmentLoader.load(fileURL: write("{\"a\": 1}", named: "config.json"))
        XCTAssertEqual(json.badge, "JSON")
    }

    func testTypeScriptIsTextDespiteVideoUTI() async throws {
        // `.ts` maps to the MPEG-2 transport stream type; clean UTF-8 must still load as text.
        let attachment = try await AttachmentLoader.load(fileURL: write("export const answer = 42;\n", named: "index.ts"))
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.badge, "TS")
    }

    func testExtensionlessUTF8FileIsTextWithDefaultBadge() async throws {
        let attachment = try await AttachmentLoader.load(fileURL: write("all:\n\tswift build\n", named: "Makefile"))
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.badge, "TXT")
    }

    func testLatin1TextFallsBack() async throws {
        let url = directory.appendingPathComponent("legacy.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: url)  // "café\n" in ISO-8859-1

        let attachment = try await AttachmentLoader.load(fileURL: url)
        XCTAssertEqual(attachment.payload, .text("café\n"))
    }

    func testUTF16WithBOMIsText() async throws {
        let url = directory.appendingPathComponent("wide.txt")
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap("Hi there".data(using: .utf16LittleEndian)))
        try data.write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)
        XCTAssertEqual(attachment.payload, .text("Hi there"))
    }

    func testBinaryFileIsRejected() async throws {
        let url = directory.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00, 0x7F, 0x45, 0x4C, 0x46]).write(to: url)
        await assertLoadFails(url, with: .unsupportedType(name: "blob.bin"))
    }

    func testTextFileWithNULBytesIsRejected() async throws {
        let url = directory.appendingPathComponent("notes.txt")
        try Data("abc\0def".utf8).write(to: url)
        await assertLoadFails(url, with: .unsupportedType(name: "notes.txt"))
    }

    func testEmptyFileIsRejected() async throws {
        let url = try write("", named: "empty.txt")
        await assertLoadFails(url, with: .empty(name: "empty.txt"))
    }

    func testWhitespaceOnlyFileIsEmpty() async throws {
        let url = try write("  \n\t\n", named: "blank.md")
        await assertLoadFails(url, with: .empty(name: "blank.md"))
    }

    func testOversizedTextIsRejected() async throws {
        let url = try write(String(repeating: "a", count: AttachmentLoader.maxTextCharacters + 1), named: "huge.log")
        let error = await loadError(url)
        guard case .tooLarge(let name, _) = error else {
            return XCTFail("Expected tooLarge, got \(String(describing: error))")
        }
        XCTAssertEqual(name, "huge.log")
    }

    func testFolderIsUnsupported() async throws {
        let folder = directory.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await assertLoadFails(folder, with: .unsupportedType(name: "Project"))
    }

    func testRTFIsConvertedToPlainText() async throws {
        let styled = NSMutableAttributedString(string: "Bold move\nsecond paragraph")
        styled.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 4))
        let rtf = try styled.data(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let url = directory.appendingPathComponent("note.rtf")
        try rtf.write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.badge, "RTF")
        guard case .text(let text) = attachment.payload else { return XCTFail("Expected text payload") }
        XCTAssertTrue(text.contains("Bold move"))
        XCTAssertTrue(text.contains("second paragraph"))
        XCTAssertFalse(text.contains("\\rtf"))
    }

    func testWordDocumentIsConvertedToPlainText() async throws {
        let source = NSAttributedString(string: "Quarterly plan\nShip Otto")
        let docx = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        let url = directory.appendingPathComponent("Plan.docx")
        try docx.write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.badge, "DOCX")
        guard case .text(let text) = attachment.payload else { return XCTFail("Expected text payload") }
        XCTAssertTrue(text.contains("Quarterly plan"))
        XCTAssertTrue(text.contains("Ship Otto"))
    }

    func testHTMLIsConvertedToPlainText() async throws {
        let url = try write(
            "<html><head><meta charset=\"utf-8\"></head><body><h1>Release notes</h1><p>Fixed <b>everything</b>.</p></body></html>",
            named: "notes.html"
        )

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.badge, "HTML")
        guard case .text(let text) = attachment.payload else { return XCTFail("Expected text payload") }
        XCTAssertTrue(text.contains("Release notes"))
        XCTAssertTrue(text.contains("Fixed everything."))
        XCTAssertFalse(text.contains("<h1>"))
    }

    func testHTMLNeverFetchesSubresourcesAndDropsHiddenContent() async throws {
        let server = try ConnectionCounter()
        defer { server.stop() }
        try await server.waitUntilReady()
        let base = "http://127.0.0.1:\(server.port)"
        let url = try write("""
            <html><head><title>Hidden title</title>
            <link rel="stylesheet" href="\(base)/style.css?user=secret">
            <style>body { color: red }</style>
            <script src="\(base)/app.js"></script><script>var markup = "<p>not text</p>";</script></head>
            <body style="background: url(\(base)/bg.png)"><p>Visible text</p>
            <img src="\(base)/pixel.png?tracking=1" srcset="\(base)/2x.png 2x">
            <iframe src="\(base)/frame.html">fallback</iframe>
            <!-- <p>commented out</p> --></body></html>
            """, named: "newsletter.html")

        let start = Date()
        let attachment = try await AttachmentLoader.load(fileURL: url)
        let elapsed = Date().timeIntervalSince(start)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(server.connectionCount, 0, "Attaching HTML must not touch the network")
        XCTAssertLessThan(elapsed, 1.0)
        guard case .text(let text) = attachment.payload else { return XCTFail("Expected text payload") }
        XCTAssertEqual(text, "Visible text")
    }

    func testHTMLTextStructureAndEntities() {
        let text = HTMLText.plainText(fromHTML: """
            <h1>Release&nbsp;notes</h1><p>Caf&eacute; &amp; more &#8212; &#x1F600; &copy 2026 &bogus; a &lt; b</p>
            <ul><li>One</li><li>Two<ol><li>Nested a</li><li>Nested b</li></ol></li></ul>
            <table><tr><th>Name</th><th>Value</th></tr><tr><td>a</td><td>1</td></tr></table>
            <pre>  indented
                code</pre><p>after<br>break</p>
            """)

        XCTAssertEqual(text, """
            Release notes

            Café & more — 😀 © 2026 &bogus; a < b

            - One
            - Two
              1. Nested a
              2. Nested b

            Name\tValue
            a\t1

              indented
                code

            after
            break
            """)
    }

    func testHTMLDeclaredCharsetIsHonored() async throws {
        let html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=iso-8859-1\"></head>"
            + "<body><p>Caf\u{E9} cr\u{E8}me</p></body></html>"
        let url = directory.appendingPathComponent("latin.html")
        try XCTUnwrap(html.data(using: .isoLatin1)).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.payload, .text("Café crème"))
    }

    func testHTMLWithOnlyScriptFallsBackToSource() async throws {
        let source = "<html><body><script>console.log('hi')</script></body></html>"
        let url = try write(source, named: "app.html")

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.payload, .text(source))
    }

    func testOversizedHTMLTextIsRejected() async throws {
        var html = "<html><body>"
        while html.utf8.count < 2_000_000 {
            html += "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>\n"
        }
        let url = try write(html + "</body></html>", named: "big.html")

        await assertLoadFails(url, with: .tooLarge(name: "big.html", limit: "400,000 characters"))
    }

    func testWebArchiveMainResourceIsConverted() async throws {
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data("<html><body><h1>Archived</h1><p>Page text</p><img src=\"https://example.com/a.png\"></body></html>".utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://example.com/",
                "WebResourceFrameName": "",
            ],
        ]
        let url = directory.appendingPathComponent("saved.webarchive")
        try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.payload, .text("Archived\n\nPage text"))
    }

    func testCorruptWebArchiveIsUnreadable() async throws {
        let url = try write("not a property list", named: "broken.webarchive")
        await assertLoadFails(url, with: .unreadable(name: "broken.webarchive"))
    }

    // MARK: - Images

    func testSmallPNGIsKeptAsIs() async throws {
        let png = try encode(try makeImage(width: 64, height: 32, alpha: false), as: .png)
        let url = directory.appendingPathComponent("tiny.png")
        try png.write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.badge, "PNG")
        XCTAssertEqual(attachment.payload, .image(mediaType: "image/png", base64: png.base64EncodedString()))
        XCTAssertNotNil(attachment.thumbnail)
    }

    func testLargeImageIsDownscaledWithinLimit() async throws {
        // Noise defeats compression, so the original PNG is far over the base64 limit.
        let image = try makeImage(width: 3000, height: 2400, alpha: false, noise: true)
        let url = directory.appendingPathComponent("noise.png")
        try encode(image, as: .png).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/jpeg")
        XCTAssertLessThanOrEqual(base64.utf8.count, AttachmentLoader.maxImageBase64Bytes)
        XCTAssertEqual(attachment.byteCount, base64.utf8.count)
        XCTAssertEqual(attachment.badge, "PNG", "Badge reflects the user's file, not the upload encoding")
        let size = try pixelSize(ofBase64: base64)
        XCTAssertLessThanOrEqual(max(size.width, size.height), AttachmentLoader.maxImageLongEdge)
        XCTAssertEqual(Double(size.width) / Double(size.height), 3000.0 / 2400.0, accuracy: 0.01)

        let thumbnail = try XCTUnwrap(attachment.thumbnail)
        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), AttachmentLoader.thumbnailMaxPointSize)
    }

    func testLargeTransparentImageStaysPNG() async throws {
        let url = directory.appendingPathComponent("logo.png")
        try encode(try makeImage(width: 2600, height: 1000, alpha: true), as: .png).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/png")
        let size = try pixelSize(ofBase64: base64)
        XCTAssertEqual(size.width, AttachmentLoader.maxImageLongEdge)
        XCTAssertLessThanOrEqual(base64.utf8.count, AttachmentLoader.maxImageBase64Bytes)
    }

    func testOpaqueImageWithAlphaChannelBecomesJPEG() async throws {
        // An alpha channel with no transparent pixels (typical of screenshots and HEIC decodes) is a photo, not a cut-out.
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let url = directory.appendingPathComponent("screenshot.png")
        try encode(try XCTUnwrap(context.makeImage()), as: .png).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/jpeg")
        XCTAssertEqual(try pixelSize(ofBase64: base64).width, AttachmentLoader.maxImageLongEdge)
    }

    func testTIFFIsReencodedToAnAPIFormat() async throws {
        let url = directory.appendingPathComponent("scan.tiff")
        try encode(try makeImage(width: 300, height: 200, alpha: false), as: .tiff).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        guard case .image(let mediaType, _) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/jpeg")
        XCTAssertEqual(attachment.badge, "TIFF")
    }

    func testRotatedJPEGIsReencodedUpright() async throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let orientation = [kCGImagePropertyOrientation: 6] as CFDictionary  // rotate 90° clockwise to display
        CGImageDestinationAddImage(destination, try makeImage(width: 400, height: 200, alpha: false), orientation)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = directory.appendingPathComponent("portrait.jpeg")
        try (data as Data).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.badge, "JPG")
        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/jpeg")
        let size = try pixelSize(ofBase64: base64)
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 400)
    }

    func testOversizedAnimatedGIFBecomesFirstFrameJPEG() async throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, 2, nil)
        )
        CGImageDestinationAddImage(destination, try makeImage(width: 2400, height: 1200, alpha: false), nil)
        CGImageDestinationAddImage(destination, try makeImage(width: 2400, height: 1200, alpha: false), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let url = directory.appendingPathComponent("party.gif")
        try (data as Data).write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.badge, "GIF")
        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/jpeg")
        XCTAssertEqual(try pixelSize(ofBase64: base64).width, AttachmentLoader.maxImageLongEdge)
    }

    func testJPEGExtensionBadgeIsShortened() {
        XCTAssertEqual(AttachmentLoader.badge(forFileName: "photo.jpeg"), "JPG")
        XCTAssertEqual(AttachmentLoader.badge(forFileName: "notes.markdown"), "MARK")
        XCTAssertNil(AttachmentLoader.badge(forFileName: "README"))
    }

    func testLoadsNSImage() async throws {
        let image = NSImage(cgImage: try makeImage(width: 120, height: 80, alpha: false), size: NSSize(width: 60, height: 40))

        let attachment = try await AttachmentLoader.load(image: image, name: "Pasted")

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.displayName, "Pasted.png")
        XCTAssertEqual(attachment.badge, "PNG")
        guard case .image(let mediaType, let base64) = attachment.payload else { return XCTFail("Expected image payload") }
        XCTAssertEqual(mediaType, "image/png")
        let size = try pixelSize(ofBase64: base64)
        XCTAssertEqual(size.width, 120, "Keeps full pixel resolution, not the point size")
    }

    func testCorruptImageIsUnreadable() async throws {
        let url = directory.appendingPathComponent("broken.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x00, 0x01, 0x02]).write(to: url)
        await assertLoadFails(url, with: .unreadable(name: "broken.png"))
    }

    // MARK: - PDF

    func testPDFLoads() async throws {
        let pdf = try makePDF(pages: 2)
        let url = directory.appendingPathComponent("PDFcea775f5d9.pdf")
        try pdf.write(to: url)

        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.badge, "PDF")
        XCTAssertEqual(attachment.displayName, "PDFcea775f5d9.pdf")
        XCTAssertEqual(attachment.payload, .pdf(base64: pdf.base64EncodedString()))
        XCTAssertNotNil(attachment.thumbnail)
        XCTAssertEqual(attachment.contentBlocks().first?["source"]?["media_type"], "application/pdf")
    }

    func testCorruptPDFIsUnreadable() async throws {
        let url = try write("%PDF-1.7 this is not really a pdf", named: "fake.pdf")
        await assertLoadFails(url, with: .unreadable(name: "fake.pdf"))
    }

    func testMaxSizePDFFitsTheRequestBudget() {
        let base64Length = (AttachmentLoader.maxPDFBytes + 2) / 3 * 4
        XCTAssertLessThanOrEqual(base64Length, AttachmentBudget.maxRequestContentBytes)
        XCTAssertLessThan(AttachmentBudget.maxRequestContentBytes, 32_000_000)
    }

    func testHaikuRejectsPDFsOverOneHundredPages() async throws {
        let url = directory.appendingPathComponent("long.pdf")
        try makePDF(pages: 101).write(to: url)
        let attachment = try await AttachmentLoader.load(fileURL: url)

        XCTAssertEqual(AttachmentLoader.pdfPageCount(of: attachment), 101)
        XCTAssertNil(AttachmentBudget.problem(with: [attachment], model: .opus5))
        XCTAssertNil(AttachmentBudget.problem(with: [attachment], model: .sonnet5))
        XCTAssertEqual(
            AttachmentBudget.problem(with: [attachment], model: .haiku45),
            .tooLarge(name: "long.pdf", limit: "100 pages with Claude Haiku 4.5")
        )

        // Attachments built elsewhere (no cached count) are parsed.
        let copy = Attachment(kind: .pdf, displayName: "copy.pdf", badge: "PDF", payload: attachment.payload, byteCount: attachment.byteCount)
        XCTAssertTrue(AttachmentBudget.exceedsPageLimit(copy, model: .haiku45))
    }

    func testCombinedAttachmentsOverTheBudgetAreRejected() {
        let images = (0..<7).map { fakeImage(named: "img\($0).png", base64Bytes: 5_000_000) }

        XCTAssertNil(AttachmentBudget.problem(with: Array(images.prefix(5)), model: .opus5))
        XCTAssertEqual(
            AttachmentBudget.problem(with: Array(images.prefix(6)), model: .opus5),
            .tooLarge(name: "img5.png", limit: "about 30 MB for all attachments in a message")
        )
    }

    func testEncodedSizeEstimateMatchesTheEncoder() throws {
        let messages = sampleMessages(imageBytes: 1_000)
        let actual = try JSONValue.array(messages).encodedData().count
        XCTAssertEqual(AttachmentBudget.estimatedEncodedBytes(.array(messages)), actual)
    }

    func testFittingStripsOldestAttachmentsAndKeepsTheNewMessage() throws {
        let messages = sampleMessages(imageBytes: 5_000_000)  // 5 + 3 images ≈ 40 MB
        XCTAssertGreaterThan(try JSONValue.array(messages).encodedData().count, AttachmentBudget.maxRequestContentBytes)

        let fitted = try XCTUnwrap(AttachmentBudget.fitting(messages))

        XCTAssertLessThanOrEqual(try JSONValue.array(fitted).encodedData().count, AttachmentBudget.maxRequestContentBytes)
        XCTAssertEqual(fitted.count, messages.count)
        XCTAssertEqual(fitted[2], messages[2], "The message being answered keeps its attachments")
        XCTAssertEqual(fitted[1], messages[1])
        let firstContent = try XCTUnwrap(fitted[0]["content"]?.arrayValue)
        XCTAssertFalse(firstContent.contains { $0.typeName == "image" })
        XCTAssertEqual(firstContent.last, ["type": "text", "text": "turn one"])
        XCTAssertTrue(firstContent[0]["text"]?.stringValue?.contains("removed") == true)
    }

    func testFittingLeavesSmallConversationsAlone() {
        let messages = sampleMessages(imageBytes: 1_000)
        XCTAssertEqual(AttachmentBudget.fitting(messages), messages)
    }

    func testFittingFailsWhenTheNewMessageAloneIsTooLarge() {
        let images = (0..<7).map { fakeImage(named: "img\($0).png", base64Bytes: 5_000_000) }
        let messages: [JSONValue] = [
            ["role": "user", "content": .array(images.flatMap { $0.contentBlocks() } + [["type": "text", "text": "hi"]])],
        ]
        XCTAssertNil(AttachmentBudget.fitting(messages))
    }

    func testStrippingKeepsTitlesAndOtherBlocks() {
        let blocks: [JSONValue] = [
            ["type": "document", "title": "report.pdf", "source": ["type": "base64", "media_type": "application/pdf", "data": "AAAA"]],
            ["type": "text", "text": "question"],
        ]
        let stripped = AttachmentBudget.strippingAttachments(from: blocks)
        XCTAssertEqual(stripped.count, 2)
        XCTAssertEqual(stripped[0].typeName, "text")
        XCTAssertTrue(stripped[0]["text"]?.stringValue?.contains("report.pdf") == true)
        XCTAssertEqual(stripped[1], blocks[1])
    }

    // MARK: - Text attachments & web pages

    func testMakeTextAttachment() throws {
        let attachment = try AttachmentLoader.makeTextAttachment("Some notes", name: "Clipboard.txt")
        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.badge, "TXT")
        XCTAssertNil(attachment.sourceURL)
        XCTAssertEqual(attachment.payload, .text("Some notes"))

        XCTAssertThrowsError(try AttachmentLoader.makeTextAttachment(" \n ", name: "Clipboard.txt")) { error in
            XCTAssertEqual(error as? AttachmentError, .empty(name: "Clipboard.txt"))
        }
    }

    func testWebPageAttachmentContentBlockShape() throws {
        let url = try XCTUnwrap(URL(string: "https://techcrunch.com/"))
        let attachment = AttachmentLoader.makeWebPage(url: url, title: "  TechCrunch \n", appBundleID: "com.google.Chrome")

        XCTAssertEqual(attachment.kind, .webPage)
        XCTAssertEqual(attachment.badge, "WEB")
        XCTAssertEqual(attachment.displayName, "TechCrunch")
        XCTAssertEqual(attachment.sourceURL, url)
        XCTAssertEqual(attachment.appBundleID, "com.google.Chrome")
        XCTAssertEqual(attachment.payload, .webPage(title: "TechCrunch", url: url))
        XCTAssertEqual(attachment.contentBlocks(), [[
            "type": "text",
            "text": "<browser_tab>\nTitle: TechCrunch\nURL: https://techcrunch.com/\n</browser_tab>",
        ]])
    }

    func testWebPageTitleFallsBackToHost() throws {
        let url = try XCTUnwrap(URL(string: "https://www.example.com/articles/42"))
        let attachment = AttachmentLoader.makeWebPage(url: url, title: "   ", appBundleID: nil)
        XCTAssertEqual(attachment.displayName, "example.com")
        XCTAssertEqual(attachment.payload, .webPage(title: "example.com", url: url))
    }

    // MARK: - Pasteboard

    func testPasteboardShortTextBecomesInlineText() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("  What does this error mean?\n", forType: .string)

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(content.attachments.isEmpty)
        XCTAssertEqual(content.inlineText, "What does this error mean?")
    }

    func testPasteboardTextAtLimitStaysInline() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let text = String(repeating: "b", count: AttachmentLoader.maxInlineTextCharacters)
        pasteboard.setString(text, forType: .string)

        let (content, _) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertEqual(content.inlineText, text)
        XCTAssertTrue(content.attachments.isEmpty)
    }

    func testPasteboardLongTextBecomesClipboardDocument() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let text = String(repeating: "long text ", count: 61)  // 610 characters
        pasteboard.setString(text, forType: .string)

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(content.inlineText)
        XCTAssertEqual(content.attachments.count, 1)
        XCTAssertEqual(content.attachments.first?.displayName, "Clipboard.txt")
        XCTAssertEqual(content.attachments.first?.kind, .text)
        XCTAssertEqual(content.attachments.first?.payload, .text(text))
    }

    func testPasteboardWebURLBecomesWebPage() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://www.apple.com/macbook-pro/\n", forType: .string)

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(content.inlineText)
        let attachment = try XCTUnwrap(content.attachments.first)
        XCTAssertEqual(attachment.kind, .webPage)
        XCTAssertEqual(attachment.displayName, "apple.com")
        XCTAssertEqual(attachment.sourceURL, URL(string: "https://www.apple.com/macbook-pro/"))
    }

    func testPasteboardFileURLIsLoaded() async throws {
        let url = try write("print(\"hi\")\n", named: "script.py")
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([url as NSURL])

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(errors.isEmpty)
        XCTAssertNil(content.inlineText)
        XCTAssertEqual(content.attachments.map(\.displayName), ["script.py"])
        XCTAssertEqual(content.attachments.first?.badge, "PY")
    }

    func testPasteboardFileErrorsAreReported() async throws {
        let url = directory.appendingPathComponent("clip.bin")
        try Data([0x00, 0xFF, 0x00, 0x10]).write(to: url)
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([url as NSURL])

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(content.attachments.isEmpty)
        XCTAssertEqual(errors.compactMap { $0 as? AttachmentError }, [.unsupportedType(name: "clip.bin")])
    }

    func testPasteboardImageDataBecomesImage() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = try encode(try makeImage(width: 40, height: 40, alpha: true), as: .png)
        pasteboard.setData(png, forType: .png)

        let (content, errors) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertTrue(errors.isEmpty)
        let attachment = try XCTUnwrap(content.attachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.displayName, "Pasted Image.png")
        XCTAssertEqual(attachment.payload, .image(mediaType: "image/png", base64: png.base64EncodedString()))
    }

    func testPasteboardProseWinsOverImageRendering() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Quarterly totals", forType: .string)
        item.setData(try encode(try makeImage(width: 20, height: 20, alpha: false), as: .png), forType: .png)
        pasteboard.writeObjects([item])

        let (content, _) = await AttachmentLoader.load(pasteboard: pasteboard)

        XCTAssertEqual(content.inlineText, "Quarterly totals")
        XCTAssertTrue(content.attachments.isEmpty)
    }

    // MARK: - Drop providers

    func testProviderPlainTextBecomesInlineText() async {
        let (content, errors) = await AttachmentLoader.load(providers: [NSItemProvider(object: "Summarize this" as NSString)])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(content.inlineText, "Summarize this")
        XCTAssertTrue(content.attachments.isEmpty)
    }

    func testProviderLongTextBecomesDocument() async {
        let text = String(repeating: "x", count: AttachmentLoader.maxInlineTextCharacters + 1)
        let (content, _) = await AttachmentLoader.load(providers: [NSItemProvider(object: text as NSString)])
        XCTAssertNil(content.inlineText)
        XCTAssertEqual(content.attachments.first?.displayName, AttachmentLoader.droppedTextName)
    }

    func testProviderFileURLIsLoaded() async throws {
        let url = try write("# Title\n", named: "README.md")
        let (content, errors) = await AttachmentLoader.load(providers: [NSItemProvider(object: url as NSURL)])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(content.attachments.map(\.displayName), ["README.md"])
        XCTAssertEqual(content.attachments.first?.sourceURL?.standardizedFileURL, url.standardizedFileURL)
    }

    func testProviderWebURLBecomesWebPage() async throws {
        let url = try XCTUnwrap(URL(string: "https://developer.apple.com/documentation/swiftui"))
        let (content, errors) = await AttachmentLoader.load(providers: [NSItemProvider(object: url as NSURL)])
        XCTAssertTrue(errors.isEmpty)
        let attachment = try XCTUnwrap(content.attachments.first)
        XCTAssertEqual(attachment.kind, .webPage)
        XCTAssertEqual(attachment.sourceURL, url)
    }

    func testProvidersKeepOrderAndCollectErrors() async throws {
        let first = try write("one", named: "one.txt")
        let binary = directory.appendingPathComponent("two.bin")
        try Data([0x00, 0x01]).write(to: binary)
        let third = try write("three", named: "three.txt")

        let (content, errors) = await AttachmentLoader.load(providers: [
            NSItemProvider(object: first as NSURL),
            NSItemProvider(object: binary as NSURL),
            NSItemProvider(object: third as NSURL),
        ])

        XCTAssertEqual(content.attachments.map(\.displayName), ["one.txt", "three.txt"])
        XCTAssertEqual(errors.compactMap { $0 as? AttachmentError }, [.unsupportedType(name: "two.bin")])
    }

    func testFileURLItemDecodingHandlesDataAndURL() throws {
        let url = directory.appendingPathComponent("a file.txt")
        XCTAssertEqual(AttachmentLoader.fileURL(fromItem: url), url)
        XCTAssertEqual(AttachmentLoader.fileURL(fromItem: url.dataRepresentation), url)
        XCTAssertNil(AttachmentLoader.fileURL(fromItem: try XCTUnwrap(URL(string: "https://example.com"))))
    }

    // MARK: - Browser context

    func testSupportedBrowsers() {
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.google.Chrome.canary"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.brave.Browser"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.microsoft.edgemac"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.apple.Safari"))
        XCTAssertTrue(BrowserContext.isSupportedBrowser(bundleID: "com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(BrowserContext.isSupportedBrowser(bundleID: "org.mozilla.firefox"))
        XCTAssertFalse(BrowserContext.isSupportedBrowser(bundleID: "com.apple.finder"))
        XCTAssertFalse(BrowserContext.isSupportedBrowser(bundleID: nil))
    }

    func testCurrentTabIgnoresNonBrowsers() async {
        let tab = await BrowserContext.currentTab(of: .current, allowPrompt: false)
        XCTAssertNil(tab)
    }

    func testTabScriptsCheckPrivateWindows() throws {
        let chrome = try XCTUnwrap(BrowserContext.scriptSource(bundleID: "com.google.Chrome"))
        XCTAssertTrue(chrome.contains("mode of frontWindow"))
        let arc = try XCTUnwrap(BrowserContext.scriptSource(bundleID: "company.thebrowser.Browser"))
        XCTAssertTrue(arc.contains("incognito of frontWindow"))
        XCTAssertFalse(arc.contains("mode of frontWindow"))
        XCTAssertNil(BrowserContext.scriptSource(bundleID: "org.mozilla.firefox"))
    }

    func testParsedTabIsOnlyVerifiedWhenTheBrowserSaysSo() throws {
        func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let descriptor = NSAppleEventDescriptor.list()
            for (offset, item) in items.enumerated() {
                descriptor.insert(item, at: offset + 1)
            }
            return descriptor
        }
        let title = NSAppleEventDescriptor(string: "  Example \n Page ")
        let address = NSAppleEventDescriptor(string: "https://example.com/a")

        let verified = try XCTUnwrap(BrowserContext.parseTab(
            list([title, address, NSAppleEventDescriptor(boolean: true)]), bundleID: "com.google.Chrome"
        ))
        XCTAssertEqual(verified.title, "Example Page")
        XCTAssertTrue(verified.isKnownNonPrivate)

        let unverified = try XCTUnwrap(BrowserContext.parseTab(
            list([title, address, NSAppleEventDescriptor(boolean: false)]), bundleID: "com.google.Chrome"
        ))
        XCTAssertFalse(unverified.isKnownNonPrivate)

        let safari = try XCTUnwrap(BrowserContext.parseTab(list([title, address]), bundleID: "com.apple.Safari"))
        XCTAssertFalse(safari.isKnownNonPrivate, "Safari can't report private windows, so its tabs are never verified")

        XCTAssertNil(BrowserContext.parseTab(
            list([title, NSAppleEventDescriptor(string: "file:///etc/hosts")]), bundleID: "com.google.Chrome"
        ))
    }

    // MARK: - Errors

    func testErrorDescriptionsAreFriendly() {
        XCTAssertEqual(AttachmentError.unsupportedType(name: "cat.mov").errorDescription, "cat.mov isn't a supported file type.")
        XCTAssertEqual(AttachmentError.empty(name: "notes.txt").errorDescription, "notes.txt is empty.")
        XCTAssertEqual(AttachmentError.unreadable(name: "x.pdf").errorDescription, "Otto couldn't read x.pdf.")
        XCTAssertEqual(
            AttachmentError.tooLarge(name: "big.pdf", limit: "24 MB").errorDescription,
            "big.pdf is too large to attach (the limit is 24 MB)."
        )
        let permission = try? XCTUnwrap(ScreenCaptureError.permissionDenied.errorDescription)
        XCTAssertTrue(permission?.contains("Screen & System Audio Recording") == true)
    }

    // MARK: - Helpers

    private func fakeImage(named name: String, base64Bytes: Int) -> Attachment {
        Attachment(
            kind: .image, displayName: name, badge: "PNG",
            payload: .image(mediaType: "image/png", base64: String(repeating: "A", count: base64Bytes)),
            byteCount: base64Bytes
        )
    }

    /// Turn one: five images; assistant reply; turn two (being answered): three images.
    private func sampleMessages(imageBytes: Int) -> [JSONValue] {
        func user(_ images: [Attachment], _ text: String) -> JSONValue {
            ["role": "user", "content": .array(images.flatMap { $0.contentBlocks() } + [["type": "text", "text": .string(text)]])]
        }
        let images = (0..<8).map { fakeImage(named: "shot\($0).png", base64Bytes: imageBytes) }
        return [
            user(Array(images[0..<5]), "turn one"),
            ["role": "assistant", "content": [["type": "text", "text": "Sure — \"quoted\"\n\\ and\u{1} control"]]],
            user(Array(images[5..<8]), "turn two"),
        ]
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func loadError(_ url: URL) async -> AttachmentError? {
        do {
            _ = try await AttachmentLoader.load(fileURL: url)
            return nil
        } catch {
            return error as? AttachmentError
        }
    }

    private func assertLoadFails(
        _ url: URL,
        with expected: AttachmentError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let error = await loadError(url)
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.jalenedusei.otto.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// Solid (or noisy) test image; with `alpha`, only a centered block is opaque.
    private func makeImage(width: Int, height: Int, alpha: Bool, noise: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 0x9E37_79B9
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let opaque = !alpha || (x > width / 4 && x < width * 3 / 4 && y > height / 4 && y < height * 3 / 4)
                if noise {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    pixels[offset] = UInt8(truncatingIfNeeded: seed >> 24)
                    pixels[offset + 1] = UInt8(truncatingIfNeeded: seed >> 16)
                    pixels[offset + 2] = UInt8(truncatingIfNeeded: seed >> 8)
                } else if opaque {
                    pixels[offset] = UInt8(x % 256)
                    pixels[offset + 1] = UInt8(y % 256)
                    pixels[offset + 2] = 180
                }
                pixels[offset + 3] = opaque ? 255 : 0
            }
        }
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func encode(_ image: CGImage, as type: UTType) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelSize(ofBase64 base64: String) throws -> (width: Int, height: Int) {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func makePDF(pages: Int) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: CGFloat(page) * 0.3, alpha: 1))
            context.fill(CGRect(x: 72, y: 72, width: 200, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// Counts TCP connections to a local port (to prove nothing is fetched).
private final class ConnectionCounter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private var ready = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock()
            self.count += 1
            self.lock.unlock()
            connection.cancel()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.lock.lock()
            self.ready = true
            self.lock.unlock()
        }
        listener.start(queue: DispatchQueue(label: "ContextTests.ConnectionCounter"))
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func waitUntilReady() async throws {
        for _ in 0..<100 {
            if isReady, port != 0 { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("Local listener didn't start")
    }

    func stop() {
        listener.cancel()
    }
}
