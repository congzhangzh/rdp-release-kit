// Branch only (web-safari-av1-diag): VideoToolbox's own answer on this machine.
import VideoToolbox
import CoreMedia
for (name, type) in [("av01", kCMVideoCodecType_AV1), ("hvc1", kCMVideoCodecType_HEVC), ("avc1", kCMVideoCodecType_H264), ("vp09", kCMVideoCodecType_VP9)] {
    print("VTIsHardwareDecodeSupported(\(name)) = \(VTIsHardwareDecodeSupported(type))")
}
