/* probe-hevc-mac: list the VideoToolbox encoders of this machine (codec, id, hardware). */
#include <stdio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>

static void print_string(CFStringRef s)
{
	char buf[256] = { 0 };
	if (s && CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8))
		printf("%s", buf);
	else
		printf("?");
}

int main(void)
{
	CFArrayRef list = NULL;
	const OSStatus rc = VTCopyVideoEncoderList(NULL, &list);
	if ((rc != noErr) || !list)
	{
		printf("VTCopyVideoEncoderList failed: %d\n", (int)rc);
		return 1;
	}
	for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
	{
		CFDictionaryRef e = CFArrayGetValueAtIndex(list, i);
		SInt32 type = 0;
		CFNumberRef n = CFDictionaryGetValue(e, kVTVideoEncoderList_CodecType);
		if (n)
			CFNumberGetValue(n, kCFNumberSInt32Type, &type);
		printf("%c%c%c%c ", (char)(type >> 24), (char)(type >> 16), (char)(type >> 8), (char)type);
		print_string(CFDictionaryGetValue(e, kVTVideoEncoderList_EncoderID));
		CFBooleanRef hw = CFDictionaryGetValue(e, kVTVideoEncoderList_IsHardwareAccelerated);
		printf(" hardware=%s\n", hw ? (CFBooleanGetValue(hw) ? "yes" : "no") : "unknown");
	}
	CFRelease(list);
	return 0;
}
