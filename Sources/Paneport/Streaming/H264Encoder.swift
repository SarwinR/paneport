import CoreMedia
import Foundation
import VideoToolbox

/// The Mac's hardware H.264 encoder, set up for low latency: real-time mode, no frame
/// reordering, and keyframes only when asked for (a new viewer, or one that fell behind).
/// Not thread-safe: use it from one queue.
final class H264Encoder {
    private var session: VTCompressionSession?

    init(width: Int, height: Int, fps: Int, bitrateMbps: Int) throws {
        guard let session = Self.makeSession(width: width, height: height, lowLatency: true)
                ?? Self.makeSession(width: width, height: height, lowLatency: false)
        else { throw PaneportError.encoderUnavailable }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateMbps * 1_000_000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: fps * 60))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        invalidate()
    }

    /// Encodes one frame. `onOutput` runs on a VideoToolbox thread.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool,
                onOutput: @escaping (CMSampleBuffer) -> Void) {
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            onOutput(sampleBuffer)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func makeSession(width: Int, height: Int, lowLatency: Bool) -> VTCompressionSession? {
        let specification: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
            : nil
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        return status == noErr ? session : nil
    }
}
