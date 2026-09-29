//
//  AttachmentLoader.swift
//  Otto
//
//  Turns files, in-memory images, pasteboard contents and drag-and-drop item
//  providers into `Attachment`s the Messages API accepts. File IO, document
//  import and image encoding all run off the main actor, and loading a file
//  never touches the network (HTML goes through `HTMLText`, not WebKit).
//

import AppKit
import Foundation
import ImageIO
import os
import PDFKit
import UniformTypeIdentifiers

// MARK: - Errors

enum AttachmentError: LocalizedError, Equatable {
    case unsupportedType(name: String)
    case tooLarge(name: String, limit: String)
    case unreadable(name: String)
    case empty(name: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let name):
            return "\(name) isn't a supported file type."
        case .tooLarge(let name, let limit):
            return "\(name) is too large to attach (the limit is \(limit))."
        case .unreadable(let name):
            return "Otto couldn't read \(name)."
        case .empty(let name):
            return "\(name) is empty."
        }
    }
}

// MARK: - Pasteboard / drop result

struct PasteboardContent: Equatable, Sendable {
    var attachments: [Attachment]
    /// Short plain text that should go into the composer rather than become a document.
    var inlineText: String?
}

// MARK: - Loader

enum AttachmentLoader {
    static let maxImageBase64Bytes = 5 * 1024 * 1024 - 64 * 1024
    /// Raw PDF size limit. PDFs are sent base64-encoded (4/3 the size), so this keeps a single PDF's
    /// encoded payload (≈ 29.4 MB) inside `AttachmentBudget.maxRequestContentBytes` and the API's 32 MB
    /// request limit.
    static let maxPDFBytes = 21 * 1024 * 1024
    static let maxTextCharacters = 400_000

    /// Pasted or dropped text up to this length goes into the composer instead of becoming a document.
    static let maxInlineTextCharacters = 600
    static let maxPDFPages = 600
    /// Longest image edge (in pixels) sent to the API; larger images are downscaled.
    static let maxImageLongEdge = 2000
    /// Guard against decompression bombs before any pixel data is decoded.
    static let maxImagePixels = 200_000_000
    /// Thumbnails are at most this many points on their long edge (backed by 2× pixels).
    static let thumbnailMaxPointSize: CGFloat = 64

    static let clipboardTextName = "Clipboard.txt"
    static let droppedTextName = "Dropped Text.txt"

    private static let maxRichDocumentBytes = 64 * 1024 * 1024
    /// Largest HTML document (a file, or a web archive's main resource) converted to text.
    private static let maxHTMLBytes = 8 * 1024 * 1024
    /// Web archives also carry the page's images, scripts and stylesheets, which are never read.
    private static let maxWebArchiveBytes = 32 * 1024 * 1024
    /// No encoding needs more than 4 bytes per character (+ BOM), so bigger files can't fit the text limit.
    private static let maxTextFileBytes = maxTextCharacters * 4 + 4
    private static let binarySniffLength = 8 * 1024
    private static let minimumReencodeEdge = 64

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Attachments")
    private static let workQueue = DispatchQueue(
        label: "com.jalenedusei.otto.attachments",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: Public API

    /// Loads a file URL off the main thread (images, PDFs, text/source files, RTF/DOCX/DOC/ODT via
    /// NSAttributedString → plain text, HTML/web archives via `HTMLText` → plain text, with no network
    /// access). Throws AttachmentError.
    static func load(fileURL: URL) async throws -> Attachment {
        try await performOffMain { try loadFile(at: fileURL) }
    }

    static func load(image: NSImage, name: String) async throws -> Attachment {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Image" : trimmed
        return try await performOffMain {
            guard let cgImage = bestCGImage(from: image) else {
                throw AttachmentError.unreadable(name: displayName)
            }
            return try imageAttachment(cgImage: cgImage, displayName: displayName, sourceURL: nil)
        }
    }

    static func makeTextAttachment(_ text: String, name: String) throws -> Attachment {
        try textAttachment(text, name: name, sourceURL: nil)
    }

    static func makeWebPage(url: URL, title: String?, appBundleID: String?) -> Attachment {
        let cleanedTitle = title.map(collapsingWhitespace) ?? ""
        let displayName = cleanedTitle.isEmpty ? displayHost(for: url) : cleanedTitle
        return Attachment(
            kind: .webPage,
            displayName: displayName,
            badge: "WEB",
            sourceURL: url,
            appBundleID: appBundleID,
            payload: .webPage(title: displayName, url: url),
            byteCount: displayName.utf8.count + url.absoluteString.utf8.count
        )
    }

    /// Reads NSPasteboard: file URLs → load; image data → image; web URL string → webPage;
    /// text ≤ 600 chars → inlineText; longer text → "Clipboard.txt" text attachment.
    /// At most `limit` files or images are read (the caller passes the room it has left), so a large
    /// copied selection is not loaded in full only to be dropped afterwards.
    static func load(pasteboard: NSPasteboard, limit: Int = .max) async -> (PasteboardContent, [Error]) {
        let limit = max(0, limit)
        // The pasteboard is only touched inside the main-actor closure.
        nonisolated(unsafe) let mainActorPasteboard = pasteboard
        let snapshot = await MainActor.run { PasteboardSnapshot(pasteboard: mainActorPasteboard) }
        var content = PasteboardContent(attachments: [], inlineText: nil)
        var errors: [Error] = []

        if !snapshot.fileURLs.isEmpty {
            for result in await loadFiles(Array(snapshot.fileURLs.prefix(limit))) {
                switch result {
                case .success(let attachment): content.attachments.append(attachment)
                case .failure(let error): errors.append(error)
                }
            }
            return (content, errors)
        }

        let text = snapshot.string.flatMap { containsVisibleText($0) ? $0 : nil }
        let textLink = text.flatMap(webURL(from:))
        // Apps like Word and Excel put a picture of the copied text next to the text itself;
        // real prose wins over that rendering, a bare link does not.
        let hasProse = text != nil && textLink == nil

        if !snapshot.images.isEmpty && !hasProse {
            for (index, image) in snapshot.images.prefix(limit).enumerated() {
                let baseName = snapshot.images.count == 1 ? "Pasted Image" : "Pasted Image \(index + 1)"
                do {
                    let attachment = try await performOffMain {
                        try imageAttachment(data: image.data, typeIdentifier: image.typeIdentifier, displayName: baseName)
                    }
                    content.attachments.append(attachment)
                } catch {
                    errors.append(error)
                }
            }
            return (content, errors)
        }

        if !hasProse, let link = snapshot.urlString.flatMap(webURL(from:)) ?? textLink {
            content.attachments.append(makeWebPage(url: link, title: snapshot.urlTitle, appBundleID: nil))
            return (content, errors)
        }

        if let text {
            await applyTextRules(to: text, attachmentName: clipboardTextName, content: &content, errors: &errors)
        }
        return (content, errors)
    }

    /// Loads SwiftUI/AppKit drop providers (.fileURL, .image, .url, .plainText). Same rules as pasteboard.
    static func load(providers: [NSItemProvider]) async -> (PasteboardContent, [Error]) {
        let outcomes = await withTaskGroup(of: (Int, ProviderOutcome).self) { group -> [ProviderOutcome] in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, await loadProvider(provider)) }
            }
            var collected: [(Int, ProviderOutcome)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var content = PasteboardContent(attachments: [], inlineText: nil)
        var errors: [Error] = []
        var texts: [String] = []
        for outcome in outcomes {
            switch outcome {
            case .attachment(let attachment): content.attachments.append(attachment)
            case .text(let text): texts.append(text)
            case .failure(let error): errors.append(error)
            }
        }
        if !texts.isEmpty {
            let joined = texts.joined(separator: "\n\n")
            await applyTextRules(to: joined, attachmentName: droppedTextName, content: &content, errors: &errors)
        }
        return (content, errors)
    }

    // MARK: Shared helpers (internal for tests and sibling files)

    /// Chip badge for a file name: uppercased extension, at most 4 characters, "JPEG" → "JPG".
    /// Returns nil when the name has no usable extension.
    static func badge(forFileName name: String) -> String? {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty, pathExtension.count <= 12,
              pathExtension.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        let upper = pathExtension.uppercased()
        if upper == "JPEG" { return "JPG" }
        return String(upper.prefix(4))
    }

    /// An http(s) URL if `string` is nothing but a single web address.
    static func webURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// The most useful image flavor among `typeIdentifiers` (formats the API accepts first, TIFF last).
    static func preferredImageType(in typeIdentifiers: [String]) -> String? {
        let preference: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif, .tiff]
        var best: (identifier: String, rank: Int)?
        for identifier in typeIdentifiers {
            guard let type = UTType(identifier), type.conforms(to: .image) else { continue }
            let rank = preference.firstIndex(where: { type.conforms(to: $0) }) ?? preference.count
            if rank < (best?.rank ?? Int.max) {
                best = (identifier, rank)
            }
        }
        return best?.identifier
    }

    // MARK: - Off-main execution

    private static func performOffMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                continuation.resume(with: Result { try autoreleasepool { try work() } })
            }
        }
    }

    // MARK: - Files

    private static func loadFile(at fileURL: URL) throws -> Attachment {
        let name = fileURL.lastPathComponent.isEmpty ? "That file" : fileURL.lastPathComponent
        guard fileURL.isFileURL else { throw AttachmentError.unreadable(name: name) }

        // The caller's URL is the one that may carry a security scope (open panels, drops); aliases and
        // symlinks are resolved afterwards.
        let didStartAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { fileURL.stopAccessingSecurityScopedResource() } }
        let url = resolvedFileURL(fileURL)

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .fileSizeKey])
        } catch {
            logger.error("Couldn't read attachment attributes: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw AttachmentError.unreadable(name: name)
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let isDirectory = values.isDirectory ?? false
        let fileSize = values.fileSize

        // RTFD is a directory package, so rich documents are classified before folders are rejected.
        if let documentType = richTextDocumentType(for: type) {
            guard !isDirectory || documentType == .rtfd else { throw AttachmentError.unsupportedType(name: name) }
            if !isDirectory, fileSize == 0 { throw AttachmentError.empty(name: name) }
            return try loadRichDocument(
                at: url, name: name, sourceURL: fileURL,
                documentType: documentType, isDirectory: isDirectory, fileSize: fileSize
            )
        }
        if isDirectory { throw AttachmentError.unsupportedType(name: name) }
        if fileSize == 0 { throw AttachmentError.empty(name: name) }

        if type.conforms(to: .pdf) {
            return try loadPDF(at: url, name: name, sourceURL: fileURL, fileSize: fileSize)
        }
        if type.conforms(to: .image) {
            if let attachment = try loadImageFile(at: url, name: name, sourceURL: fileURL) {
                return attachment
            }
            // Neither ImageIO nor AppKit can decode it. Vector formats such as SVG are still useful as source.
            do {
                return try loadTextFile(
                    at: url, name: name, sourceURL: fileURL, type: type, fileSize: fileSize, allowLegacyEncodings: false
                )
            } catch AttachmentError.unsupportedType {
                throw AttachmentError.unreadable(name: name)
            }
        }
        // Known text types get legacy-encoding fallbacks; anything else must be clean UTF-8 without NUL bytes
        // (this is also what lets misclassified source files such as TypeScript's .ts through).
        return try loadTextFile(
            at: url, name: name, sourceURL: fileURL, type: type, fileSize: fileSize,
            allowLegacyEncodings: isTextType(type)
        )
    }

    private static func resolvedFileURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let isAlias = (try? standardized.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile ?? false
        if isAlias, let resolved = try? URL(resolvingAliasFileAt: standardized, options: [.withoutUI, .withoutMounting]) {
            return resolved
        }
        return standardized
    }

    private static func readData(at url: URL, name: String) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            logger.error("Couldn't read attachment: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            throw AttachmentError.unreadable(name: name)
        }
    }

    private static func loadFiles(_ urls: [URL]) async -> [Result<Attachment, Error>] {
        await withTaskGroup(of: (Int, Result<Attachment, Error>).self) { group -> [Result<Attachment, Error>] in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await load(fileURL: url)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<Attachment, Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Text

    private static let textTypes: [UTType] = [
        .text, .sourceCode, .json, .xml, .yaml, .propertyList, .commaSeparatedText,
    ]

    private static func isTextType(_ type: UTType) -> Bool {
        textTypes.contains { type.conforms(to: $0) }
    }

    private static var textLimitDescription: String {
        "\(maxTextCharacters.formatted()) characters"
    }

    private static func byteLimitDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func loadTextFile(
        at url: URL,
        name: String,
        sourceURL: URL,
        type: UTType,
        fileSize: Int?,
        allowLegacyEncodings: Bool
    ) throws -> Attachment {
        if let fileSize, fileSize > maxTextFileBytes {
            // Tell binaries apart from oversized text so the error says the right thing.
            if prefixLooksBinary(url) { throw AttachmentError.unsupportedType(name: name) }
            throw AttachmentError.tooLarge(name: name, limit: textLimitDescription)
        }
        let data = try readData(at: url, name: name)
        let converted = type.conforms(to: .propertyList) ? xmlPropertyList(fromBinary: data) : nil
        guard let text = decodeText(
            converted ?? data,
            fileURL: converted == nil ? url : nil,
            allowLegacyEncodings: allowLegacyEncodings
        ) else {
            throw AttachmentError.unsupportedType(name: name)
        }
        return try textAttachment(text, name: name, sourceURL: sourceURL)
    }

    private static func textAttachment(_ text: String, name: String, sourceURL: URL?) throws -> Attachment {
        let cleaned = text.contains("\0") ? text.replacingOccurrences(of: "\0", with: "") : text
        guard containsVisibleText(cleaned) else { throw AttachmentError.empty(name: name) }
        // utf8.count is O(1) and bounds the (O(n)) character count from above.
        if cleaned.utf8.count > maxTextCharacters, cleaned.count > maxTextCharacters {
            throw AttachmentError.tooLarge(name: name, limit: textLimitDescription)
        }
        return Attachment(
            kind: .text,
            displayName: name,
            badge: badge(forFileName: name) ?? "TXT",
            sourceURL: sourceURL,
            payload: .text(cleaned),
            byteCount: cleaned.utf8.count
        )
    }

    /// Decodes text, returning nil for binary data (NUL bytes outside BOM-marked UTF-16/32) or, when
    /// `allowLegacyEncodings` is false, for anything that isn't valid UTF-8.
    private static func decodeText(_ data: Data, fileURL: URL?, allowLegacyEncodings: Bool) -> String? {
        if hasUnicodeBOM(data) {
            guard let text = decodeWithBOM(data), !text.contains("\0") else { return nil }
            return text
        }
        if data.contains(0) { return nil }
        if allowLegacyEncodings, let fileURL {
            // Honors the com.apple.TextEncoding extended attribute written by TextEdit and friends.
            var encoding = String.Encoding.utf8
            if let text = try? String(contentsOf: fileURL, usedEncoding: &encoding), !text.contains("\0") {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard allowLegacyEncodings else { return nil }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func hasUnicodeBOM(_ data: Data) -> Bool {
        let prefix = [UInt8](data.prefix(4))
        return prefix.starts(with: [0xEF, 0xBB, 0xBF]) || prefix.starts(with: [0xFF, 0xFE])
            || prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF])
    }

    private static func decodeWithBOM(_ data: Data) -> String? {
        let prefix = [UInt8](data.prefix(4))
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: Data(data.dropFirst(3)), encoding: .utf8)
        }
        if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32LittleEndian)
        }
        if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32BigEndian)
        }
        if prefix.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
        }
        if prefix.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
        }
        return nil
    }

    private static func prefixLooksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: binarySniffLength) else { return false }
        return !hasUnicodeBOM(prefix) && prefix.contains(0)
    }

    /// Binary property lists become readable XML; returns nil for anything else.
    private static func xmlPropertyList(fromBinary data: Data) -> Data? {
        guard data.starts(with: Array("bplist".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func containsVisibleText(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func displayHost(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Short text goes into the composer; longer text becomes a document attachment.
    private static func applyTextRules(
        to text: String,
        attachmentName: String,
        content: inout PasteboardContent,
        errors: inout [Error]
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.count <= maxInlineTextCharacters {
            content.inlineText = trimmed
            return
        }
        do {
            let attachment = try await performOffMain { try makeTextAttachment(text, name: attachmentName) }
            content.attachments.append(attachment)
        } catch {
            errors.append(error)
        }
    }

    // MARK: - Rich documents

    private static func richTextDocumentType(for type: UTType) -> NSAttributedString.DocumentType? {
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .webArchive) { return .webArchive }
        if type.conforms(to: .html) { return .html }
        let officeTypes: [(identifier: String, documentType: NSAttributedString.DocumentType)] = [
            ("org.openxmlformats.wordprocessingml.document", .officeOpenXML),
            ("com.microsoft.word.doc", .docFormat),
            ("org.oasis-open.opendocument.text", .openDocument),
            ("com.microsoft.word.wordml", .wordML),
        ]
        for entry in officeTypes {
            if type.identifier == entry.identifier { return entry.documentType }
            if let officeType = UTType(entry.identifier), type.conforms(to: officeType) { return entry.documentType }
        }
        return nil
    }

    private static func loadRichDocument(
        at url: URL,
        name: String,
        sourceURL: URL,
        documentType: NSAttributedString.DocumentType,
        isDirectory: Bool,
        fileSize: Int?
    ) throws -> Attachment {
        switch documentType {
        case .html:
            // Never AppKit's HTML importer: it is WebKit-backed, must run on the main thread and fetches every
            // stylesheet, image and frame the page references (tracking pixels included).
            if let fileSize, fileSize > maxHTMLBytes {
                throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxHTMLBytes))
            }
            let data = try readData(at: url, name: name)
            return try htmlAttachment(data: data, declaredCharset: nil, fileURL: url, name: name, sourceURL: sourceURL)

        case .webArchive:
            if let fileSize, fileSize > maxWebArchiveBytes {
                throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxWebArchiveBytes))
            }
            let data = try readData(at: url, name: name)
            return try webArchiveAttachment(data: data, name: name, sourceURL: sourceURL)

        default:
            if let fileSize, fileSize > maxRichDocumentBytes {
                throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxRichDocumentBytes))
            }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: documentType]
            let attributed: NSAttributedString
            do {
                if isDirectory {
                    attributed = try NSAttributedString(url: url, options: options, documentAttributes: nil)
                } else {
                    let data = try readData(at: url, name: name)
                    attributed = try NSAttributedString(data: data, options: options, documentAttributes: nil)
                }
            } catch let error as AttachmentError {
                throw error
            } catch {
                logger.error("Rich text import failed: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                throw AttachmentError.unreadable(name: name)
            }
            return try textAttachment(plainText(from: attributed), name: name, sourceURL: sourceURL)
        }
    }

    /// HTML → readable text with `HTMLText` (no network, any thread). A page without readable text (all
    /// script, say) is attached as its source instead.
    private static func htmlAttachment(
        data: Data,
        declaredCharset: String?,
        fileURL: URL?,
        name: String,
        sourceURL: URL
    ) throws -> Attachment {
        guard data.count <= maxHTMLBytes else {
            throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxHTMLBytes))
        }
        guard let source = decodeHTML(data, declaredCharset: declaredCharset, fileURL: fileURL) else {
            throw AttachmentError.unsupportedType(name: name)
        }
        // Output past the text limit is rejected anyway, so conversion stops there.
        let text = HTMLText.plainText(fromHTML: source, maxOutputBytes: maxTextFileBytes)
        if containsVisibleText(text) {
            return try textAttachment(text, name: name, sourceURL: sourceURL)
        }
        return try textAttachment(source, name: name, sourceURL: sourceURL)
    }

    /// Decodes HTML bytes: a BOM wins, then the declared character set (web archive metadata or a
    /// `<meta charset>`), then the usual text detection.
    private static func decodeHTML(_ data: Data, declaredCharset: String?, fileURL: URL?) -> String? {
        if !hasUnicodeBOM(data),
           let encoding = declaredCharset.flatMap(HTMLText.encoding(ianaName:)) ?? HTMLText.declaredEncoding(in: data),
           !data.contains(0),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        return decodeText(data, fileURL: fileURL, allowLegacyEncodings: true)
    }

    /// Reads a Safari web archive's main resource from its property list. Subresources (images, scripts,
    /// stylesheets) and subframes are ignored, and nothing is loaded from the network.
    private static func webArchiveAttachment(data: Data, name: String, sourceURL: URL) throws -> Attachment {
        guard let archive = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let mainResource = archive["WebMainResource"] as? [String: Any],
              let resourceData = mainResource["WebResourceData"] as? Data
        else { throw AttachmentError.unreadable(name: name) }
        guard !resourceData.isEmpty else { throw AttachmentError.empty(name: name) }

        let mimeType = (mainResource["WebResourceMIMEType"] as? String)?.lowercased() ?? "text/html"
        let charset = mainResource["WebResourceTextEncodingName"] as? String
        if mimeType.contains("html") {
            return try htmlAttachment(data: resourceData, declaredCharset: charset, fileURL: nil, name: name, sourceURL: sourceURL)
        }
        if mimeType.hasPrefix("text/") || mimeType.hasSuffix("+xml") || mimeType.hasSuffix("/xml") || mimeType.hasSuffix("/json") {
            guard resourceData.count <= maxTextFileBytes else {
                throw AttachmentError.tooLarge(name: name, limit: textLimitDescription)
            }
            let encoding = charset.flatMap(HTMLText.encoding(ianaName:))
            let text = hasUnicodeBOM(resourceData) || resourceData.contains(0)
                ? nil
                : encoding.flatMap { String(data: resourceData, encoding: $0) }
            guard let decoded = text ?? decodeText(resourceData, fileURL: nil, allowLegacyEncodings: true) else {
                throw AttachmentError.unsupportedType(name: name)
            }
            return try textAttachment(decoded, name: name, sourceURL: sourceURL)
        }
        throw AttachmentError.unsupportedType(name: name)
    }

    private static func plainText(from attributed: NSAttributedString) -> String {
        attributed.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")  // inline attachment placeholders
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    // MARK: - PDF

    private static func loadPDF(at url: URL, name: String, sourceURL: URL, fileSize: Int?) throws -> Attachment {
        if let fileSize, fileSize > maxPDFBytes {
            throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxPDFBytes))
        }
        let data = try readData(at: url, name: name)
        guard data.count <= maxPDFBytes else {
            throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxPDFBytes))
        }
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw AttachmentError.unreadable(name: name)
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw AttachmentError.empty(name: name) }
        guard pageCount <= maxPDFPages else {
            throw AttachmentError.tooLarge(name: name, limit: "\(maxPDFPages) pages")
        }
        let base64 = data.base64EncodedString()
        let attachment = Attachment(
            kind: .pdf,
            displayName: name,
            badge: "PDF",
            sourceURL: sourceURL,
            thumbnail: pdfThumbnail(data: data),
            payload: .pdf(base64: base64),
            byteCount: base64.utf8.count
        )
        pdfPageCounts.set(pageCount, for: attachment.id)
        return attachment
    }

    /// Page counts of loaded PDFs by attachment id, so model limits can be checked without re-parsing.
    private static let pdfPageCounts = PageCountCache()

    /// Number of pages of a PDF attachment (nil for other kinds or an unreadable payload). Cached for PDFs
    /// this loader produced; anything else is parsed once (thread-safe Core Graphics parsing).
    static func pdfPageCount(of attachment: Attachment) -> Int? {
        guard case .pdf(let base64) = attachment.payload else { return nil }
        if let cached = pdfPageCounts.value(for: attachment.id) { return cached }
        guard let data = Data(base64Encoded: base64),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return nil }
        let count = document.numberOfPages
        pdfPageCounts.set(count, for: attachment.id)
        return count
    }

    private final class PageCountCache: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]

        func value(for id: UUID) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return counts[id]
        }

        func set(_ count: Int, for id: UUID) {
            lock.lock()
            defer { lock.unlock() }
            counts[id] = count
        }
    }

    /// Renders the first page with Core Graphics (thread-safe, unlike view-based PDFKit rendering).
    private static func pdfThumbnail(data: Data) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1)
        else { return nil }
        var size = page.getBoxRect(.cropBox).size
        if abs(page.rotationAngle) % 180 == 90 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard size.width > 0, size.height > 0 else { return nil }

        let maxPixels = thumbnailMaxPointSize * 2
        let scale = maxPixels / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        // The drawing transform never scales up, so apply the scale explicitly and fit the unscaled box.
        context.scaleBy(x: scale, y: scale)
        let unscaledBounds = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: unscaledBounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return makeThumbnailImage(image)
    }

    // MARK: - Images

    private struct EncodedImage {
        let mediaType: String
        let data: Data
    }

    private struct ImageInfo {
        let width: Int
        let height: Int
        let typeIdentifier: String?
        let frameCount: Int
        let isCMYK: Bool
        let isRotated: Bool

        var longEdge: Int { max(width, height) }
        var pixelCount: Int { width * height }

        init?(source: CGImageSource) {
            let count = CGImageSourceGetCount(source)
            guard count > 0 else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            if width <= 0 || height <= 0 {
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                width = image.width
                height = image.height
            }
            guard width > 0, height > 0 else { return nil }
            self.width = width
            self.height = height
            typeIdentifier = CGImageSourceGetType(source) as String?
            frameCount = count
            isCMYK = (properties[kCGImagePropertyColorModel] as? String) == (kCGImagePropertyColorModelCMYK as String)
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            isRotated = orientation != 1
        }

        /// Media type when the original bytes can be sent unchanged. EXIF-rotated and CMYK images are
        /// re-encoded so the model sees them upright and in a color model every decoder handles.
        var passthroughMediaType: String? {
            guard let typeIdentifier, let type = UTType(typeIdentifier), !isCMYK, !isRotated else { return nil }
            if type.conforms(to: .png) { return "image/png" }
            if type.conforms(to: .jpeg) { return "image/jpeg" }
            if type.conforms(to: .gif) { return "image/gif" }
            if type.conforms(to: .webP) { return "image/webp" }
            return nil
        }
    }

    private static func loadImageFile(at url: URL, name: String, sourceURL: URL) throws -> Attachment? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, options), ImageInfo(source: source) != nil {
            return try imageAttachment(
                source: source,
                originalData: { try readData(at: url, name: name) },
                displayName: name,
                sourceURL: sourceURL
            )
        }
        // Formats only AppKit understands.
        guard let image = NSImage(contentsOf: url), let cgImage = bestCGImage(from: image) else { return nil }
        return try imageAttachment(cgImage: cgImage, displayName: name, sourceURL: sourceURL)
    }

    /// Image bytes from the pasteboard or a drop.
    private static func imageAttachment(data: Data, typeIdentifier: String?, displayName: String) throws -> Attachment {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeIdentifier { options[kCGImageSourceTypeIdentifierHint] = typeIdentifier }
        if let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
           ImageInfo(source: source) != nil {
            return try imageAttachment(source: source, originalData: { data }, displayName: displayName, sourceURL: nil)
        }
        guard let image = NSImage(data: data), let cgImage = bestCGImage(from: image) else {
            throw AttachmentError.unreadable(name: displayName)
        }
        return try imageAttachment(cgImage: cgImage, displayName: displayName, sourceURL: nil)
    }

    /// Decoded pixels with no original file (NSImage, AppKit-only formats): normalized to PNG first.
    private static func imageAttachment(cgImage: CGImage, displayName: String, sourceURL: URL?) throws -> Attachment {
        let longEdge = max(cgImage.width, cgImage.height)
        let prepared = longEdge > maxImageLongEdge ? (resized(cgImage, maxPixelSize: maxImageLongEdge) ?? cgImage) : cgImage
        guard let png = encode(prepared, as: .png),
              let source = CGImageSourceCreateWithData(png as CFData, nil)
        else { throw AttachmentError.unreadable(name: displayName) }
        return try imageAttachment(source: source, originalData: { png }, displayName: displayName, sourceURL: sourceURL)
    }

    private static func imageAttachment(
        source: CGImageSource,
        originalData: () throws -> Data,
        displayName: String,
        sourceURL: URL?
    ) throws -> Attachment {
        guard let info = ImageInfo(source: source) else { throw AttachmentError.unreadable(name: displayName) }
        guard info.pixelCount <= maxImagePixels else {
            throw AttachmentError.tooLarge(name: displayName, limit: "\(maxImagePixels / 1_000_000) megapixels")
        }

        var encoded: EncodedImage?
        if let mediaType = info.passthroughMediaType, info.longEdge <= maxImageLongEdge {
            let data = try originalData()
            if base64Length(ofByteCount: data.count) <= maxImageBase64Bytes {
                encoded = EncodedImage(mediaType: mediaType, data: data)
            }
        }
        let final = try encoded ?? reencode(source: source, info: info, name: displayName)
        let base64 = final.data.base64EncodedString()
        return Attachment(
            kind: .image,
            displayName: nameEnsuringExtension(displayName, mediaType: final.mediaType),
            badge: badge(forFileName: displayName) ?? badge(forMediaType: final.mediaType),
            sourceURL: sourceURL,
            thumbnail: thumbnail(from: source),
            payload: .image(mediaType: final.mediaType, base64: base64),
            byteCount: base64.utf8.count
        )
    }

    /// Downscales to ≤ `maxImageLongEdge` and encodes PNG (alpha, if it fits) or JPEG, shrinking until the
    /// base64 payload fits `maxImageBase64Bytes`. Animated images keep only their first frame.
    private static func reencode(source: CGImageSource, info: ImageInfo, name: String) throws -> EncodedImage {
        let allowPNG = info.frameCount == 1
        var edge = min(info.longEdge, maxImageLongEdge)
        var quality = 0.85
        var hasTransparency: Bool?
        while edge >= minimumReencodeEdge {
            guard let image = downscaledImage(from: source, maxPixelSize: edge) else {
                throw AttachmentError.unreadable(name: name)
            }
            let transparent = hasTransparency ?? containsTransparency(image)
            hasTransparency = transparent
            if allowPNG, transparent, let png = encode(image, as: .png),
               base64Length(ofByteCount: png.count) <= maxImageBase64Bytes {
                return EncodedImage(mediaType: "image/png", data: png)
            }
            guard let jpeg = encode(transparent ? flattenedOnWhite(image) : image, as: .jpeg, quality: quality) else {
                throw AttachmentError.unreadable(name: name)
            }
            if base64Length(ofByteCount: jpeg.count) <= maxImageBase64Bytes {
                return EncodedImage(mediaType: "image/jpeg", data: jpeg)
            }
            edge = Int(Double(edge) * 0.75)
            quality = max(0.6, quality - 0.1)
        }
        throw AttachmentError.tooLarge(name: name, limit: byteLimitDescription(maxImageBase64Bytes))
    }

    private static func base64Length(ofByteCount count: Int) -> Int {
        ((count + 2) / 3) * 4
    }

    /// Oriented (EXIF-applied) image whose long edge is at most `maxPixelSize`; never upscales.
    private static func downscaledImage(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func resized(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: hasAlphaChannel(image)
                    ? CGImageAlphaInfo.premultipliedLast.rawValue
                    : CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }

    /// Whether any pixel is less than fully opaque. Decoders give many opaque images an alpha channel (HEIC
    /// photos, screenshots), so the pixels are checked on a rendition of at most 512 px — partially covered
    /// samples keep small transparent regions visible at that size.
    private static func containsTransparency(_ image: CGImage) -> Bool {
        guard hasAlphaChannel(image) else { return false }
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // If the check itself fails, err on the side of preserving transparency.
        guard rendered else { return true }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }

    /// JPEG has no alpha channel; composite on white so transparent areas don't turn black.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard hasAlphaChannel(image),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func thumbnail(from source: CGImageSource) -> NSImage? {
        guard let image = downscaledImage(from: source, maxPixelSize: Int(thumbnailMaxPointSize * 2)) else { return nil }
        return makeThumbnailImage(image)
    }

    /// Wraps pixels in an NSImage treated as 2× (so a 128 px image is 64 pt), capped at `thumbnailMaxPointSize`.
    private static func makeThumbnailImage(_ image: CGImage) -> NSImage {
        let longEdge = CGFloat(max(image.width, image.height, 1))
        let scale = min(0.5, thumbnailMaxPointSize / longEdge)
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSImage(cgImage: image, size: size)
    }

    /// The largest bitmap representation, or a rasterization at full pixel resolution (2× for vector images,
    /// capped at `maxImageLongEdge`). The proposed rect is in pixels because no context is supplied.
    private static func bestCGImage(from image: NSImage) -> CGImage? {
        let largest = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        if let bitmap = largest as? NSBitmapImageRep, let cgImage = bitmap.cgImage {
            return cgImage
        }
        var targetSize = image.size
        if let largest, largest.pixelsWide > 0, largest.pixelsHigh > 0 {
            targetSize = NSSize(width: largest.pixelsWide, height: largest.pixelsHigh)
        } else if image.size.width > 0, image.size.height > 0 {
            let scale = min(2, CGFloat(maxImageLongEdge) / max(image.size.width, image.size.height))
            targetSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        var rect = CGRect(origin: .zero, size: targetSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func badge(forMediaType mediaType: String) -> String {
        switch mediaType {
        case "image/jpeg": return "JPG"
        case "image/png": return "PNG"
        case "image/gif": return "GIF"
        case "image/webp": return "WEBP"
        default: return "IMG"
        }
    }

    private static func nameEnsuringExtension(_ name: String, mediaType: String) -> String {
        guard (name as NSString).pathExtension.isEmpty else { return name }
        let pathExtension: String
        switch mediaType {
        case "image/jpeg": pathExtension = "jpg"
        case "image/gif": pathExtension = "gif"
        case "image/webp": pathExtension = "webp"
        default: pathExtension = "png"
        }
        return "\(name).\(pathExtension)"
    }

    // MARK: - Pasteboard

    /// Everything we need from a pasteboard, read on the main actor in one pass.
    private struct PasteboardSnapshot: Sendable {
        var fileURLs: [URL] = []
        var images: [(data: Data, typeIdentifier: String)] = []
        var string: String?
        var urlString: String?
        var urlTitle: String?

        @MainActor
        init(pasteboard: NSPasteboard) {
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            fileURLs = urls ?? []
            guard fileURLs.isEmpty else { return }

            for item in pasteboard.pasteboardItems ?? [] {
                guard let identifier = AttachmentLoader.preferredImageType(in: item.types.map(\.rawValue)),
                      let data = item.data(forType: NSPasteboard.PasteboardType(identifier)),
                      !data.isEmpty
                else { continue }
                images.append((data, identifier))
            }
            string = pasteboard.string(forType: .string)
            urlString = pasteboard.string(forType: .URL)
            urlTitle = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
        }
    }

    // MARK: - Item providers

    private enum ProviderOutcome: Sendable {
        case attachment(Attachment)
        case text(String)
        case failure(Error)
    }

    private static func loadProvider(_ provider: NSItemProvider) async -> ProviderOutcome {
        let suggestedName = provider.suggestedName.flatMap { containsVisibleText($0) ? $0 : nil }
        let itemName = suggestedName ?? "The dropped item"
        do {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadFileURL(from: provider) {
                return .attachment(try await load(fileURL: url))
            }
            if let imageType = preferredImageType(in: provider.registeredTypeIdentifiers) {
                let data = try await loadData(from: provider, typeIdentifier: imageType, name: itemName)
                let baseName = suggestedName ?? "Dropped Image"
                return .attachment(try await performOffMain {
                    try imageAttachment(data: data, typeIdentifier: imageType, displayName: baseName)
                })
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadURLObject(from: provider) {
                if url.isFileURL {
                    return .attachment(try await load(fileURL: url))
                }
                if let link = webURL(from: url.absoluteString) {
                    return .attachment(makeWebPage(url: link, title: suggestedName, appBundleID: nil))
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let string = await loadString(from: provider), containsVisibleText(string) {
                if let link = webURL(from: string) {
                    return .attachment(makeWebPage(url: link, title: nil, appBundleID: nil))
                }
                return .text(string)
            }
            // File promises (Mail attachments, Photos, …) expose their content type without a file URL.
            if let dataType = provider.registeredTypeIdentifiers.first(where: { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .plainText)
            }) {
                return .attachment(try await loadFileRepresentation(from: provider, typeIdentifier: dataType, name: itemName))
            }
            return .failure(AttachmentError.unsupportedType(name: itemName))
        } catch {
            return .failure(error)
        }
    }

    /// File URLs arrive as URL, NSURL, Data (the URL's bytes) or a string depending on the source.
    static func fileURL(fromItem item: Any?) -> URL? {
        guard let item else { return nil }
        let url: URL?
        switch item {
        case let value as URL: url = value
        case let value as Data: url = URL(dataRepresentation: value, relativeTo: nil)
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url, url.isFileURL else { return nil }
        // Resolves file reference URLs (file:///.file/id=…) to a path.
        return (url as NSURL).filePathURL ?? url
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        let item: URL? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    logger.debug("File URL item failed to load: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                }
                continuation.resume(returning: fileURL(fromItem: item))
            }
        }
        if let item { return item }
        guard let object = await loadURLObject(from: provider), object.isFileURL else { return nil }
        return (object as NSURL).filePathURL ?? object
    }

    private static func loadURLObject(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private static func loadString(from provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                continuation.resume(returning: string)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String, name: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    if let error {
                        logger.error("Dropped data failed to load: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                    }
                    continuation.resume(throwing: AttachmentError.unreadable(name: name))
                }
            }
        }
    }

    /// The provided file only exists inside the completion handler, so it is copied to a private temporary
    /// folder, loaded, and removed again.
    private static func loadFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        name: String
    ) async throws -> Attachment {
        let copy: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    if let error {
                        logger.error("Dropped file failed to load: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                    }
                    continuation.resume(throwing: AttachmentError.unreadable(name: name))
                    return
                }
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("OttoDrops", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    logger.error("Couldn't copy dropped file: \(LoggedError(error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                    continuation.resume(throwing: AttachmentError.unreadable(name: name))
                }
            }
        }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        var attachment = try await load(fileURL: copy)
        attachment.sourceURL = nil
        return attachment
    }
}
