//
//  record_promo.swift
//  Otto
//
//  Records one scene of Otto's promo stage to a movie, without touching the visible screen.
//
//  The app is launched with `--promo <work dir> --promo-scene <scene>`. It opens a borderless stage
//  window *behind the desktop* (so nobody sees it), writes `ready.json` with the window's number, and
//  waits. This tool finds that window with ScreenCaptureKit, captures it on its own
//  (`SCContentFilter(desktopIndependentWindow:)` reads the window's own surface, covered or not),
//  and writes constant-frame-rate H.264 with AVAssetWriter. Once frames are flowing it drops a `go`
//  file; the app plays the scene, logs its key moments to `timeline.json` and drops `done`. The
//  recording stops there, and a sidecar `<movie>.json` holds the scene's timeline in movie time.
//
//  The stage flips one corner point every frame (an imperceptible "heartbeat"), so frames keep
//  arriving through still moments. That makes a stalled stage detectable: the window server stops
//  rendering a window behind the desktop while a full-screen app's Space is showing. The recorder
//  then waits (the scene hasn't started yet) until frames flow at full rate again, and if the stage
//  stalls mid-scene it discards the take and records it again.
//
//  The shell that runs this needs Screen Recording permission (Terminal/iTerm usually has it).
//
//    swiftc -O -o build/record_promo scripts/record_promo.swift
//    build/record_promo --app build/Build/Products/Debug/Otto.app/Contents/MacOS/Otto \
//        --scene hero --out /tmp/hero.mov [--width 3072 --height 1728] [--fps 60] [--preroll 0.6]
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - Arguments

struct Options {
    var app = ""
    var scene = "hero"
    var output = ""
    var width = 3072
    var height = 1728
    var fps = 60
    /// Seconds of the stage's first frame recorded before the scene starts (a clean handle).
    var preroll = 0.6
    /// Seconds recorded after the scene reports it is done.
    var tail = 0.0
    /// Longest a scene may run once started.
    var timeout = 120.0
    /// Longest to wait for the stage to render at full rate (e.g. while a full-screen app is up).
    var wait = 1800.0
    var attempts = 3
    var bitrate = 90_000_000
    /// Mid-scene, a capture rate under this share of `fps` (over half a second) counts as a stalled stage.
    /// A stage behind a full-screen Space drops to nearly 0; a busy moment (a long conversation laid out as
    /// the notch opens) dips into the high 20s at 60 fps, which the 30 fps film and 22 fps GIF never show.
    var stallRatio = 0.4

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        func next() -> String {
            index += 1
            guard index < arguments.count else { fail("missing value for \(arguments[index - 1])") }
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--app": options.app = next()
            case "--scene": options.scene = next()
            case "--out": options.output = next()
            case "--width": options.width = Int(next()) ?? options.width
            case "--height": options.height = Int(next()) ?? options.height
            case "--fps": options.fps = Int(next()) ?? options.fps
            case "--preroll": options.preroll = Double(next()) ?? options.preroll
            case "--tail": options.tail = Double(next()) ?? options.tail
            case "--timeout": options.timeout = Double(next()) ?? options.timeout
            case "--wait": options.wait = Double(next()) ?? options.wait
            case "--attempts": options.attempts = max(1, Int(next()) ?? options.attempts)
            case "--bitrate": options.bitrate = Int(next()) ?? options.bitrate
            case "--stall-ratio": options.stallRatio = Double(next()) ?? options.stallRatio
            case "-h", "--help":
                print("usage: record_promo --app <Otto binary> --scene <name> --out <file.mov> [--width px] [--height px] [--fps n] [--preroll s] [--tail s] [--wait s] [--attempts n] [--stall-ratio r]")
                exit(0)
            default: fail("unknown argument \(arguments[index])")
            }
            index += 1
        }
        guard !options.app.isEmpty, !options.output.isEmpty else {
            fail("--app and --out are required (see --help)")
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("record_promo: \(message)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("record_promo: \(message)\n".utf8))
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Writer

/// Receives captured frames, measures how fast they arrive, and — once armed — turns them into a
/// constant-frame-rate movie: every tick of the output clock gets the most recent captured frame.
final class ConstantRateWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int
    private let queue = DispatchQueue(label: "record_promo.writer")
    private var latest: CVPixelBuffer?
    private var arrivals: [Double] = []
    private var startHostTime: Double?
    private var framesWritten = 0
    private var capturedFrames = 0
    private var timer: DispatchSourceTimer?
    private var isFinished = false

    init(url: URL, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw NSError(domain: "record_promo", code: 1) }
        writer.add(input)
        self.fps = fps
        super.init()
    }

    /// Frames captured per second over the last `window` seconds.
    func captureRate(window: Double = 0.5) -> Double {
        queue.sync {
            let cutoff = now() - window
            return Double(arrivals.filter { $0 >= cutoff }.count) / window
        }
    }

    /// Seconds of movie time at this instant (nil until armed).
    func movieTime(atHostTime host: Double) -> Double? {
        queue.sync { startHostTime.map { host - $0 } }
    }

    var capturedFrameCount: Int { queue.sync { capturedFrames } }
    var writtenFrameCount: Int { queue.sync { framesWritten } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only frames with new content carry an image; idle/blank status frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let arrival = now()
        queue.async { [self] in
            guard !isFinished else { return }
            latest = pixelBuffer
            arrivals.append(arrival)
            if arrivals.count > 240 { arrivals.removeFirst(arrivals.count - 240) }
            if startHostTime != nil { capturedFrames += 1 }
        }
    }

    /// Starts writing: movie time zero is now.
    func arm() -> Bool {
        queue.sync {
            guard startHostTime == nil else { return true }
            guard latest != nil, writer.startWriting() else {
                log("writer failed to start: \(writer.error?.localizedDescription ?? "no frames yet")")
                return false
            }
            writer.startSession(atSourceTime: .zero)
            startHostTime = now()
            tick()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / (fps * 4)), leeway: .microseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            return true
        }
    }

    /// Queue-confined: writes the latest frame for every output tick that has come due.
    private func tick() {
        guard let start = startHostTime, let frame = latest, !isFinished else { return }
        let due = Int(((now() - start) * Double(fps)).rounded(.down))
        while framesWritten <= due {
            if input.isReadyForMoreMediaData {
                let time = CMTime(value: CMTimeValue(framesWritten), timescale: CMTimeScale(fps))
                if !adaptor.append(frame, withPresentationTime: time) {
                    log("append failed at frame \(framesWritten): \(writer.error?.localizedDescription ?? "unknown")")
                }
            }
            // If the encoder is behind, the tick is dropped (the previous frame holds) rather than blocking.
            framesWritten += 1
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                tick()
                isFinished = true
                timer?.cancel()
                timer = nil
                guard writer.status == .writing else {
                    continuation.resume()
                    return
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(value: CMTimeValue(framesWritten), timescale: CMTimeScale(fps)))
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        return writer.status == .completed
    }
}

// MARK: - Helpers

func waitForFile(_ url: URL, timeout: Double, process: Process) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        if !process.isRunning { return FileManager.default.fileExists(atPath: url.path) }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

func stopProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// The stage process currently running, so every exit path can kill it.
nonisolated(unsafe) var runningStagePID: pid_t = 0

enum TakeResult {
    case recorded(sidecar: [String: Any])
    /// The stage stopped rendering mid-scene; worth another try.
    case stalled(String)
}

// MARK: - One take

func recordTake(options: Options, outputURL: URL) async -> TakeResult {
    let workURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("otto-promo-\(options.scene)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
    } catch {
        fail("couldn't create \(workURL.path): \(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: workURL) }

    let app = Process()
    app.executableURL = URL(fileURLWithPath: options.app)
    app.arguments = ["--promo", workURL.path, "--promo-scene", options.scene]
    app.standardOutput = FileHandle.nullDevice
    do {
        try app.run()
    } catch {
        fail("couldn't launch \(options.app): \(error.localizedDescription)")
    }
    runningStagePID = app.processIdentifier
    defer {
        stopProcess(app)
        runningStagePID = 0
    }

    let readyURL = workURL.appendingPathComponent("ready.json")
    // The stage writes ready.json after its async prepare, which may play a turn off camera first.
    guard await waitForFile(readyURL, timeout: 90, process: app),
          let readyData = try? Data(contentsOf: readyURL),
          let ready = try? JSONSerialization.jsonObject(with: readyData) as? [String: Any],
          let windowNumber = ready["windowNumber"] as? Int else {
        fail("the stage didn't report ready (scene \(options.scene)); is the scene name valid, and did its prepare finish?")
    }

    // Find the stage window. It is behind the desktop, so ask for off-screen windows too.
    var stageWindow: SCWindow?
    for _ in 0..<50 {
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
           let window = content.windows.first(where: { Int($0.windowID) == windowNumber }) {
            stageWindow = window
            break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let stageWindow else {
        fail("ScreenCaptureKit can't see the stage window \(windowNumber). Does this shell have Screen Recording permission?")
    }

    let configuration = SCStreamConfiguration()
    configuration.width = options.width
    configuration.height = options.height
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = false
    configuration.queueDepth = 8
    configuration.backgroundColor = .black
    configuration.scalesToFit = true
    configuration.captureResolution = .best
    configuration.ignoreShadowsSingleWindow = true
    if #available(macOS 14.2, *) {
        configuration.shouldBeOpaque = true
    }

    let writer: ConstantRateWriter
    do {
        writer = try ConstantRateWriter(url: outputURL, width: options.width, height: options.height, fps: options.fps, bitrate: options.bitrate)
    } catch {
        fail("couldn't create the movie writer: \(error.localizedDescription)")
    }

    let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: stageWindow), configuration: configuration, delegate: nil)
    do {
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: DispatchQueue(label: "record_promo.capture"))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    } catch {
        fail("couldn't start capturing: \(error.localizedDescription)")
    }
    func stopStream() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.stopCapture { _ in continuation.resume() }
        }
    }

    // Healthy = the heartbeat comes through at (nearly) full rate for a whole second.
    let started = now()
    let healthyRate = Double(options.fps) * 0.8
    var healthySince: Double?
    var announcedWait = false
    while true {
        let rate = writer.captureRate(window: 0.5)
        if rate >= healthyRate {
            if healthySince == nil { healthySince = now() }
            if let since = healthySince, now() - since >= 1.0 { break }
        } else {
            healthySince = nil
            if !announcedWait && now() - started > 3 {
                announcedWait = true
                log("the stage isn't rendering (\(Int(rate)) fps): it pauses while a full-screen app's Space is showing. Waiting for a desktop Space…")
            }
        }
        if now() - started > options.wait {
            await stopStream()
            fail("the stage never rendered at full rate within \(Int(options.wait)) s")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if announcedWait { log("the stage is rendering again; recording \(options.scene)") }

    guard writer.arm() else {
        await stopStream()
        fail("couldn't start the movie")
    }
    try? await Task.sleep(nanoseconds: UInt64(options.preroll * 1_000_000_000))

    let goHost = now()
    FileManager.default.createFile(atPath: workURL.appendingPathComponent("go").path, contents: Data())
    let goMovieTime = writer.movieTime(atHostTime: goHost) ?? 0

    // Watch the heartbeat while the scene plays.
    let doneURL = workURL.appendingPathComponent("done")
    let sceneDeadline = now() + options.timeout
    var stall: String?
    var slowest = Double(options.fps)
    let settleUntil = now() + 0.6
    while !FileManager.default.fileExists(atPath: doneURL.path) {
        if !app.isRunning {
            stall = "the stage quit before finishing"
            break
        }
        if now() > sceneDeadline {
            await stopStream()
            _ = await writer.finish()
            fail("the scene didn't finish within \(Int(options.timeout)) s")
        }
        let rate = writer.captureRate(window: 0.5)
        if now() > settleUntil { slowest = min(slowest, rate) }
        if rate < Double(options.fps) * options.stallRatio {
            let sceneTime = (writer.movieTime(atHostTime: now()) ?? goMovieTime) - goMovieTime
            stall = "the stage stalled mid-scene (\(Int(rate)) fps at \(String(format: "%.1f", sceneTime)) s into the scene)"
            break
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if stall == nil, options.tail > 0 {
        try? await Task.sleep(nanoseconds: UInt64(options.tail * 1_000_000_000))
    }
    await stopStream()
    let finished = await writer.finish()
    if let stall {
        return .stalled(stall)
    }
    guard finished else { fail("couldn't finish the movie") }

    // Sidecar: the app's timeline shifted into movie time.
    var sidecar: [String: Any] = [
        "scene": options.scene,
        "file": outputURL.lastPathComponent,
        "width": options.width,
        "height": options.height,
        "fps": options.fps,
        "frames": writer.writtenFrameCount,
        "capturedFrames": writer.capturedFrameCount,
        "duration": Double(writer.writtenFrameCount) / Double(options.fps),
        "sceneStart": (goMovieTime * 1000).rounded() / 1000,
        // QA: the lowest capture rate (frames per second over half a second) while the scene played.
        "slowestCaptureRate": slowest.rounded(),
    ]
    let timelineURL = workURL.appendingPathComponent("timeline.json")
    if let data = try? Data(contentsOf: timelineURL),
       let timeline = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for (key, value) in timeline where key != "marks" {
            sidecar[key] = value
        }
        if let marks = timeline["marks"] as? [[String: Any]] {
            sidecar["marks"] = marks.map { mark -> [String: Any] in
                var shifted = mark
                if let time = mark["t"] as? Double {
                    shifted["t"] = ((time + goMovieTime) * 1000).rounded() / 1000
                }
                return shifted
            }
        }
    }
    return .recorded(sidecar: sidecar)
}

// MARK: - Main

let options = Options.parse(CommandLine.arguments)
// ScreenCaptureKit needs a CoreGraphics window-server connection, which a plain CLI doesn't open.
_ = CGMainDisplayID()
let outputURL = URL(fileURLWithPath: options.output).standardizedFileURL
do {
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
} catch {
    fail("couldn't create \(outputURL.deletingLastPathComponent().path): \(error.localizedDescription)")
}

// Never leave a stage process behind, whatever happens (the stage also quits if we disappear).
signal(SIGINT) { _ in exit(130) }
signal(SIGTERM) { _ in exit(143) }
atexit {
    if runningStagePID > 0 {
        kill(runningStagePID, SIGKILL)
    }
}

for attempt in 1...options.attempts {
    switch await recordTake(options: options, outputURL: outputURL) {
    case .recorded(let sidecar):
        let sidecarURL = outputURL.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: sidecarURL)
        }
        log("wrote \(outputURL.path) — \(sidecar["frames"] ?? 0) frames (\(sidecar["capturedFrames"] ?? 0) captured)")
        exit(0)
    case .stalled(let reason):
        log("take \(attempt) of \(options.scene) discarded: \(reason)")
    }
}
try? FileManager.default.removeItem(at: outputURL)
fail("couldn't record \(options.scene) in \(options.attempts) attempts")
