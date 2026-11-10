import CoreMedia
import Foundation

/// Converts VideoToolbox output (length-prefixed NAL units, "AVCC") into the Annex B
/// byte stream that browsers' WebCodecs decoder accepts without extra configuration.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// An encoded frame, ready to send.
    struct Frame {
        let isKeyframe: Bool
        let bytes: [UInt8]
    }

    /// `avcc`: NAL units, each preceded by a 4-byte big-endian length.
    /// `parameterSets`: SPS and PPS to put first, which keyframes need.
    /// Stops at the first truncated unit.
    static func convert(avcc: [UInt8], parameterSets: [[UInt8]] = []) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(avcc.count + parameterSets.reduce(0) { $0 + $1.count + startCode.count })
        for parameterSet in parameterSets {
            out += startCode
            out += parameterSet
        }
        var offset = 0
        while offset + 4 <= avcc.count {
            let length = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16
                | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            offset += 4
            guard length > 0, offset + length <= avcc.count else { break }
            out += startCode
            out += avcc[offset..<(offset + length)]
            offset += length
        }
        return out
    }

    /// The frame inside an encoder output buffer, with parameter sets added to keyframes.
    static func frame(from sampleBuffer: CMSampleBuffer) -> Frame? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &avcc)
                == kCMBlockBufferNoErr else { return nil }
        let key = Self.isKeyframe(sampleBuffer)
        return Frame(isKeyframe: key,
                     bytes: convert(avcc: avcc, parameterSets: key ? parameterSets(format) : []))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }

    private static func parameterSets(_ format: CMFormatDescription) -> [[UInt8]] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: size))
        }
    }
}
