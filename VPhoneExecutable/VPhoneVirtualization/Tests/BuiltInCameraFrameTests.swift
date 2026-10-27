import AVFoundation
import CoreVideo
import Foundation

@main
struct BuiltInCameraFrameTests {
    static func main() {
        var image: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 4096] as CFDictionary
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attributes, &image) == kCVReturnSuccess)
        let buffer = image!
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        precondition(stride > 1280 * 4, "Exercise a padded camera buffer")
        memset(CVPixelBufferGetBaseAddress(buffer)!, 0x42, stride * 720)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = VPhoneBuiltInCameraProducer.frame(from: buffer)!
        precondition(frame.width == 1280 && frame.height == 720)
        precondition(frame.bytesPerRow == stride && frame.pixels.count == stride * 720)
        precondition(frame.timestampNS > 0)
        precondition(frame.pixels.first == 0x42 && frame.pixels.last == 0x42)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 0, stride * 720)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        precondition(frame.pixels.first == 0x42, "Published frames must own their bytes")
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0 ..< 720 {
            bytes[row * stride] = 17
            bytes[row * stride + 1279 * 4] = 239
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let mirrored = VPhoneBuiltInCameraProducer.frame(from: buffer)!
        for row in [0, 359, 719] {
            precondition(mirrored.pixels[row * stride] == 239)
            precondition(mirrored.pixels[row * stride + 1279 * 4] == 17,
                         "Mirror horizontally without changing row order")
        }
        for (width, height) in
 [(640, 480), (1920, 1080), (480, 640)] {
            var sourceBuffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &sourceBuffer) == kCVReturnSuccess)
            let source = sourceBuffer!
            CVPixelBufferLockBaseAddress(source, [])
            memset(CVPixelBufferGetBaseAddress(source)!, 255, CVPixelBufferGetBytesPerRow(source) * height)
            CVPixelBufferUnlockBaseAddress(source, [])
            let converted = VPhoneBuiltInCameraProducer.frame(from: source)!
            precondition(converted.width == 1280 && converted.height == 720)
            let center = 360 * converted.bytesPerRow + 640 * 4
            precondition(converted.pixels[center] >= 250 && converted.pixels[center + 3] == 255)
            if width * 720 < height * 1280 {
                let edge = 360 * converted.bytesPerRow
                precondition(converted.pixels[edge] == 0 && converted.pixels[edge + 3] == 255,
                             "Narrow sources must have opaque black side bars")
            }
        }
        var yuvBuffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &yuvBuffer) == kCVReturnSuccess)
        let yuv = yuvBuffer!
        CVPixelBufferLockBaseAddress(yuv, [])
        for plane in 0 ..< CVPixelBufferGetPlaneCount(yuv) {
            memset(CVPixelBufferGetBaseAddressOfPlane(yuv, plane)!, plane == 0 ? 16 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(yuv, plane) * CVPixelBufferGetHeightOfPlane(yuv, plane))
        }
        CVPixelBufferUnlockBaseAddress(yuv, [])
        let converted = VPhoneBuiltInCameraProducer.frame(from: yuv)!
        precondition(converted.width == 1280 && converted.height == 720)
        precondition(converted.pixels[0] <= 3 && converted.pixels[1] <= 3 && converted.pixels[2] <= 3)
        precondition(converted.pixels[3] == 255, "NV12 camera frames must convert to opaque BGRA")
        print("Camera frame checks passed: padded BGRA, owned bytes, resizing, letterboxing and NV12 conversion.")
    }
}
