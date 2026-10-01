//
//  TestSupport.swift
//  OttoiOSTests
//
//  Waiting on the main actor, throwaway graphs and small fixtures shared by the iPhone tests.
//

import UIKit
import XCTest
@testable import Otto

@MainActor
func waitUntil(
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
extension XCTestCase {
    /// An inert graph (throwaway preferences, in-memory stores, the scripted client) torn down after the test.
    func makeGraph(latencyScale: Double = 0, isDemo: Bool = true) -> MobileComposition {
        let graph = MobileComposition.inert(latencyScale: latencyScale, isDemo: isDemo)
        addTeardownBlock {
            await graph.terminate()
        }
        return graph
    }

    /// Sends `text` and waits for the reply to settle.
    func ask(_ text: String, in graph: MobileComposition, file: StaticString = #filePath, line: UInt = #line) async {
        graph.model.composerText = text
        graph.model.send()
        await waitUntil(file: file, line: line) { !graph.chat.isStreaming }
    }
}

enum Fixtures {
    /// A small PNG: a warm square on near black.
    static func pngData(size: CGSize = CGSize(width: 64, height: 48)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(white: 0.04, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1).setFill()
            context.fill(CGRect(x: size.width * 0.25, y: size.height * 0.25, width: size.width / 2,
                                height: size.height / 2))
        }
        return image.pngData() ?? Data()
    }

    static func textAttachment(name: String, text: String = "Notes") -> Attachment {
        Attachment(kind: .text, displayName: name, badge: "TXT", payload: .text(text), byteCount: text.utf8.count)
    }

    static func imageAttachment(name: String) -> Attachment {
        let data = pngData(size: CGSize(width: 120, height: 90))
        return Attachment(kind: .image, displayName: name, badge: "PNG", thumbnail: UIImage(data: data),
                          payload: .image(mediaType: "image/png", base64: data.base64EncodedString()),
                          byteCount: data.count)
    }
}
