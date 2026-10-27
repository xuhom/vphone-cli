import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// A single BGRA frame produced by a frame source.
struct VPhoneCameraFrame: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let timestampNS: UInt64
    let pixels: Data
}

/// Frame source for the host-side virtual camera server.
///
/// Pull-based producers run on the server's serial producer queue. Live
/// capture also uses a private session queue and locks its latest frame.
protocol VPhoneFrameProducer: AnyObject, Sendable {
    func nextFrame() -> VPhoneCameraFrame?
    func start()
    func stop()
}

extension VPhoneFrameProducer {
    func start() {}
    func stop() {}
}

// MARK: - Test pattern

/// Generates a smoothly-animating BGRA pattern: a moving vertical gradient
/// modulated by a sin wave, plus a frame counter overlay in the corner so
/// the receiver can verify that frames are advancing. No external assets
/// required.
final class VPhoneTestPatternProducer: VPhoneFrameProducer, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let startedAt: TimeInterval

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        // Round bytesPerRow up to 16-byte alignment — common requirement for
        // IOSurfaces and BGRA hardware paths. For 1280 width: 1280*4 = 5120
        // (already 16-aligned).
        let stride = ((width * 4) + 15) & ~15
        bytesPerRow = stride
        startedAt = ProcessInfo.processInfo.systemUptime
    }

    func nextFrame() -> VPhoneCameraFrame? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - startedAt
        let pixelCount = bytesPerRow * height
        var bytes = [UInt8](repeating: 0, count: pixelCount)

        // Vertical gradient. Hue rolls with time.
        let hueOffset = elapsed * 0.4 // turns per second
        for y in 0 ..< height {
            let v = Double(y) / Double(height)
            // Simple HSV → RGB on hue, full sat/val.
            let h = (v + hueOffset).truncatingRemainder(dividingBy: 1.0)
            let (r, g, b) = Self.hsvToRGB(h: h, s: 0.85, v: 0.85)
            let rB = UInt8(min(255, max(0, Int(r * 255))))
            let gB = UInt8(min(255, max(0, Int(g * 255))))
            let bB = UInt8(min(255, max(0, Int(b * 255))))

            let rowStart = y * bytesPerRow
            var idx = rowStart
            // BGRA order on little-endian Apple platforms.
            for _ in 0 ..< width {
                bytes[idx + 0] = bB // B
                bytes[idx + 1] = gB // G
                bytes[idx + 2] = rB // R
                bytes[idx + 3] = 255 // A
                idx += 4
            }
        }

        // Counter overlay: a moving small white square (poor man's frame
        // counter — the receiver can eyeball motion to confirm fps).
        let sqSize = 32
        let xPos = Int(elapsed * 200) % max(1, width - sqSize)
        let yPos = max(8, (height - sqSize) / 8)
        for dy in 0 ..< sqSize {
            let row = (yPos + dy) * bytesPerRow
            for dx in 0 ..< sqSize {
                let off = row + (xPos + dx) * 4
                bytes[off + 0] = 255
                bytes[off + 1] = 255
                bytes[off + 2] = 255
                bytes[off + 3] = 255
            }
        }

        let ts = UInt64(now * 1_000_000_000)
        return VPhoneCameraFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestampNS: ts,
            pixels: Data(bytes),
        )
    }

    // MARK: - HSV helpers

    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = floor(h * 6.0)
        let f = h * 6.0 - i
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}

// MARK: - Video file (.mov / .mp4 / .m4v via AVAssetReader)

/// Plays a video file in a loop. Decode is delegated to
/// `AVAssetReaderVideoCompositionOutput`, so anything AVFoundation can demux
/// on macOS works (`.mov`, `.mp4`, `.m4v`). For unsupported containers
/// (`.mkv`, `.webm`, `.avi`) convert externally first
/// (e.g. `ffmpeg -i in.mkv -c copy out.mov` if codecs are compatible).
///
/// A letterbox video composition renders every frame at the configured
/// camera width/height, so full-resolution BGRA frames of a large source
/// (a 2160x3840 portrait clip is about 33 MB per frame) are never
/// materialized. The aspect ratio is preserved with black bars, and the
/// track's preferred transform is applied so rotated portrait clips stay
/// upright. Output is always 8-bit BGRA, top-down, 16-byte aligned
/// bytesPerRow.
final class VPhoneVideoFileProducer: VPhoneFrameProducer, @unchecked Sendable {
    private let url: URL
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let composition: AVMutableVideoComposition
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderVideoCompositionOutput?

    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        self.width = width
        self.height = height
        bytesPerRow = ((width * 4) + 15) & ~15
        asset = AVURLAsset(url: url)
        // The track and its geometry are invariant for the asset, so they
        // are loaded once and the composition is reused on every loop.
        let loaded = try Self.loadVideoTrack(from: asset, url: url)
        videoTrack = loaded.track
        composition = Self.letterboxComposition(loaded, width: width, height: height)
        try restartReader()
    }

    private struct LoadedTrack {
        let track: AVAssetTrack
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let duration: CMTime
    }

    /// Bridges the async AVFoundation loaders into this synchronous,
    /// throwing initializer. AVFoundation runs the load on its own queue, so
    /// the caller's thread just parks on the semaphore until it resolves.
    private static func loadVideoTrack(from asset: AVURLAsset, url: URL) throws -> LoadedTrack {
        let box = LoadedTrackBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
                    let duration = try await asset.load(.duration)
                    box.result = .success(LoadedTrack(
                        track: track,
                        naturalSize: size,
                        preferredTransform: transform,
                        duration: duration,
                    ))
                } else {
                    box.result = .success(nil)
                }
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.result {
        case let .success(loaded?):
            return loaded
        case .success(nil), .none:
            throw NSError(
                domain: "VPhoneVideoFileProducer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent): no video track"],
            )
        case let .failure(error):
            throw error
        }
    }

    /// Carries the async load result across the semaphore hand-off.
    private final class LoadedTrackBox: @unchecked Sendable {
        var result: Result<LoadedTrack?, Error>?
    }

    /// Aspect-fit letterbox composition at the camera size.
    private static func letterboxComposition(_ loaded: LoadedTrack, width: Int, height: Int) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let bounds = CGRect(origin: .zero, size: loaded.naturalSize)
            .applying(loaded.preferredTransform)
        let boundsWidth = abs(bounds.width)
        let boundsHeight = abs(bounds.height)
        let scale = min(CGFloat(width) / boundsWidth, CGFloat(height) / boundsHeight)
        let tx = (CGFloat(width) - boundsWidth * scale) / 2 - bounds.minX * scale
        let ty = (CGFloat(height) - boundsHeight * scale) / 2 - bounds.minY * scale
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: loaded.track)
        layer.setTransform(
            loaded.preferredTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty)),
            at: .zero,
        )
        // The layer instruction must sit inside a composition instruction.
        // Assigning it to `instructions` directly raises an unrecognized
        // selector (`timeRange`) when the reader validates the composition.
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: loaded.duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        return composition
    }

    private func restartReader() throws {
        let track = videoTrack
        let r = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_32BGRA),
            ],
        )
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        r.add(output)
        guard r.startReading() else {
            throw NSError(
                domain: "VPhoneVideoFileProducer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "AVAssetReader.startReading failed: \(r.error?.localizedDescription ?? "?")"],
            )
        }
        reader = r
        readerOutput = output
    }

    func nextFrame() -> VPhoneCameraFrame? {
        if reader?.status != .reading {
            // Loop on EOF (or after an error)
            do { try restartReader() } catch { print("[camera] mov restart failed: \(error)"); return nil }
        }
        guard let sb = readerOutput?.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb)
        else {
            // EOF — restart on next call.
            do { try restartReader() } catch {}
            return nil
        }

        let srcWidth = CVPixelBufferGetWidth(pb)
        let srcHeight = CVPixelBufferGetHeight(pb)

        // The composition output already has the camera size and BGRA
        // format; copy it row by row into the 16-byte aligned wire stride.
        if srcWidth == width, srcHeight == height,
           CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA
        {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let srcBPR = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            var out = Data(count: bytesPerRow * height)
            out.withUnsafeMutableBytes { dst in
                let dstBase = dst.baseAddress!
                for y in 0 ..< height {
                    let dstRow = dstBase.advanced(by: y * bytesPerRow)
                    let srcRow = base.advanced(by: y * srcBPR)
                    let copyLen = min(srcBPR, bytesPerRow)
                    memcpy(dstRow, srcRow, copyLen)
                }
            }
            return VPhoneCameraFrame(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1e9),
                pixels: out,
            )
        }

        // The composition renders every frame at the camera size in BGRA,
        // so the copy above always applies. Any other size means the
        // composition was ignored; drop the frame instead of sending a
        // malformed payload.
        print("[camera] video frame mismatch: \(srcWidth)x\(srcHeight) "
            + "format \(CVPixelBufferGetPixelFormatType(pb))")
        return nil
    }
}

// MARK: - Mac built-in camera

/// A single physical source feeds both guest camera aliases over port 1338.
/// Session lifecycle and sample delivery share captureQueue; the server reads
/// the latest immutable frame under a lock, with no accumulating frame queue.
final class VPhoneBuiltInCameraProducer: NSObject, VPhoneFrameProducer,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.vphone.camera.capture")
    private let lock = NSLock()
    private var latestFrame: VPhoneCameraFrame?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private let onError: @Sendable (String) -> Void
    private static let frameContext = CIContext(options: [.cacheIntermediates: false])

    init(onError: @escaping @Sendable (String) -> Void) throws {
        self.onError = onError
        super.init()
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first else {
            throw Self.error("No Mac built-in camera was found.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw Self.error("Unable to open the Mac built-in camera.")
        }
        session.addInput(input)
        // A preset is a preference, not a guarantee about delivered buffers.
        // Normalize the actual frames below, including Center Stage outputs.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw Self.error("Unable to read frames from the Mac built-in camera.")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: session, queue: nil
            ) { [weak self] notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? "Mac camera capture was interrupted. Stop and start streaming to retry."
                self?.onError(message)
            })
        }
        print("[camera] built-in source = \(device.localizedName)")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        captureQueue.async { [self] in
            running = true
            session.startRunning()
            if !session.isRunning {
                running = false
                onError("The Mac built-in camera could not start. Check Camera access in System Settings.")
            }
        }
    }

    func stop() {
        captureQueue.async { [self] in
            running = false
            session.stopRunning()
            lock.lock()
            latestFrame = nil
            lock.unlock()
        }
    }

    func nextFrame() -> VPhoneCameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard running, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let frame = Self.frame(from: buffer) else {
            running = false
            onError("Unable to convert the Mac camera frame (\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer)), pixel format \(CVPixelBufferGetPixelFormatType(buffer)).")
            return
        }
        lock.lock()
        latestFrame = frame
        lock.unlock()
    }

    static func frame(from buffer: CVPixelBuffer) -> VPhoneCameraFrame? {
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        if sourceWidth == 1280, sourceHeight == 720,
           CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            return copyFrame(from: buffer)
        }

        // AVFoundation may deliver native dimensions or YUV despite the
        // requested preset/settings. Convert to the guest's fixed format,
        // preserving aspect ratio and filling unused space with opaque black.
        var destination: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                                  attributes, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1280 / image.extent.width, 720 / image.extent.height)
        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX, y: -image.extent.minY
        )).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = normalized.transformed(by: CGAffineTransform(
            translationX: (1280 - normalized.extent.width) / 2,
            y: (720 - normalized.extent.height) / 2
        ))
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let background = CIImage(color: .black).cropped(to: bounds)
        frameContext.render(centered.composited(over: background), to: destination,
                            bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return copyFrame(from: destination)
    }

    private static func copyFrame(from buffer: CVPixelBuffer) -> VPhoneCameraFrame? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width == 1280, height == 720, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Mirror the normalized BGRA frame once before transport, so both
        // guest camera aliases receive the same Mac self-view orientation.
        var pixels = Data(bytes: base, count: stride * height)
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: stride)
        let status = pixels.withUnsafeMutableBytes { bytes -> vImage_Error in
            var destination = vImage_Buffer(data: bytes.baseAddress,
                                            height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: stride)
            return vImageHorizontalReflect_ARGB8888(&source, &destination, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { return nil }
        return VPhoneCameraFrame(
            width: width, height: height, bytesPerRow: stride,
            timestampNS: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
            pixels: pixels
        )
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "VPhoneBuiltInCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
