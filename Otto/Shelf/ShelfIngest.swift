//
//  ShelfIngest.swift
//  Otto
//
//  Turns what was dropped on the Shelf into shelf inputs. A file is kept by reference (a bookmark to
//  the user's own file, which Otto never moves or deletes); an image that arrives without a file (a
//  picture dragged out of a browser, a pasted screenshot) is copied into a private temporary folder
//  so the store can take ownership of the bytes.
//

import AppKit
import Foundation
import os
import UniformTypeIdentifiers

/// One thing to put on the Shelf.
enum ShelfInput: Equatable, Sendable {
    /// A file or folder the user already has; the Shelf keeps a bookmark to it.
    case reference(URL)
    /// Bytes with no file of their own, copied to a private temporary file; the store copies them into
    /// its `Owned` folder and `ShelfIngest.discard(_:)` removes the temporary copy.
    case owned(temporaryURL: URL, name: String)
}

enum ShelfIngest {
    /// What the Shelf can hold: files (and folders), and images that arrive as data.
    static let dropTypes: [UTType] = [.fileURL, .image]

    /// Name used when a dropped image carries no name of its own.
    static let fallbackImageName = "Dropped Image"

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Shelf")

    /// Any provider with a file URL or an image. Text and web links alone can't go on the Shelf.
    static func acceptsShelf(_ providers: [NSItemProvider]) -> Bool {
        providers.contains(where: accepts)
    }

    /// fileURL → `.reference`; an image without a fileURL → `loadFileRepresentation` of its preferred image
    /// type, COPIED inside the completion handler (the provider deletes its file when the handler returns)
    /// into a private temporary folder → `.owned`. Providers the Shelf can't hold are skipped silently;
    /// ones that fail to load add a `ShelfError.unreadable` to `errors`. Inputs keep the providers' order.
    static func load(_ providers: [NSItemProvider]) async -> (inputs: [ShelfInput], errors: [Error]) {
        var inputs: [ShelfInput] = []
        var errors: [Error] = []
        for provider in providers where accepts(provider) {
            do {
                if let input = try await input(from: provider) {
                    inputs.append(input)
                }
            } catch {
                errors.append(error)
            }
        }
        return (inputs, errors)
    }

    /// Removes the temporary copy behind an `.owned` input (and its private folder). References are never
    /// touched: they are the user's files.
    static func discard(_ input: ShelfInput) {
        guard case .owned(let temporaryURL, _) = input else { return }
        let folder = temporaryURL.deletingLastPathComponent()
        let target = folder.deletingLastPathComponent().standardizedFileURL == temporaryRoot.standardizedFileURL
            ? folder : temporaryURL
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            logger.debug("Couldn't remove a temporary shelf copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where dropped image data waits until the store has copied it: one 0700 folder per drop item.
    static var temporaryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OttoShelfDrops", isDirectory: true)
    }

    // MARK: - Private

    private static func accepts(_ provider: NSItemProvider) -> Bool {
        dropTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    private static func input(from provider: NSItemProvider) async throws -> ShelfInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(from: provider) {
            return .reference(url)
        }
        guard let imageType = preferredImageType(in: provider.registeredTypeIdentifiers) else { return nil }
        let name = displayName(for: provider, type: imageType)
        let temporaryURL = try await copyFileRepresentation(from: provider, typeIdentifier: imageType, name: name)
        return .owned(temporaryURL: temporaryURL, name: name)
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    logger.debug("A dropped file URL failed to load: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: AttachmentLoader.fileURL(fromItem: item))
            }
        }
    }

    /// The first registered image type in the provider's own order (its richest representation first),
    /// preferring a concrete type over the abstract `public.image`.
    private static func preferredImageType(in identifiers: [String]) -> String? {
        let images = identifiers.filter { UTType($0)?.conforms(to: .image) == true }
        return images.first(where: { $0 != UTType.image.identifier }) ?? images.first
    }

    private static func displayName(for provider: NSItemProvider, type identifier: String) -> String {
        let suggested = provider.suggestedName.map { DisplayText.sanitized($0, maxLength: 120) } ?? ""
        let base = suggested.isEmpty ? fallbackImageName : suggested
        guard let type = UTType(identifier), let fileExtension = type.preferredFilenameExtension else { return base }
        if let existing = UTType(filenameExtension: (base as NSString).pathExtension), existing.conforms(to: .image) {
            return base
        }
        return "\(base).\(fileExtension)"
    }

    private static func copyFileRepresentation(
        from provider: NSItemProvider,
        typeIdentifier: String,
        name: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    if let error {
                        logger.error("A dropped image failed to load: \(error.localizedDescription, privacy: .public)")
                    }
                    continuation.resume(throwing: ShelfError.unreadable(name: name))
                    return
                }
                do {
                    continuation.resume(returning: try copyToPrivateFolder(url, name: name))
                } catch {
                    logger.error("Couldn't keep a dropped image: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: ShelfError.unreadable(name: name))
                }
            }
        }
    }

    /// Copies the provider's short-lived file into `temporaryRoot/<uuid>/<name>`, 0700 folders and a 0600 file.
    private static func copyToPrivateFolder(_ source: URL, name: String) throws -> URL {
        let root = try AppSupport.secureDirectory(temporaryRoot)
        let folder = try AppSupport.secureDirectory(root.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let destination = folder.appendingPathComponent(ShelfStore.safeFileName(name))
        try ShelfStore.copyFileContents(from: source, to: destination)
        return destination
    }
}
