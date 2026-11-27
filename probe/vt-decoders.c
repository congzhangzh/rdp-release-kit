/* probe-hevc-client-vt: does this machine's VideoToolbox decode HEVC and H.264 in hardware? */
#include <stdio.h>
#include <VideoToolbox/VideoToolbox.h>

int main(void)
{
	printf("hvc1 hardware decode: %s\n", VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? "yes" : "no");
	printf("avc1 hardware decode: %s\n", VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) ? "yes" : "no");
	return 0;
}
