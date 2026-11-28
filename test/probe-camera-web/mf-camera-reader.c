/*
 * mf-camera-reader: the CI's camera app, run inside the RDP session (camera redirection test of
 * FreeRDP's rdpecam client, sys:mf). A test tool, never shipped; Apache-2.0.
 *
 * Copyright 2026 Cong Zhang <congzhangzh@gmail.com>
 *
 *   mf-camera-reader camera [--match <text>] [--frames N] [--min-seconds S] [--wait S]
 *                           [--timeout S] [--log <file>] [--only-user <name>]
 *       waits up to --wait seconds for a video capture device whose friendly name contains <text>
 *       (case-insensitive; default "Remote Desktop Camera", then any camera when --match ""),
 *       logs every camera, opens the one found, logs its native media types, reads N frames,
 *       and keeps reading until the camera was open --min-seconds, logging each frame (subtype,
 *       size, bytes, a hash of its first 4 KiB). Exit 0 when that came, 2 when no camera
 *       matched, 3 on the watchdog (--timeout), 1 on an error. --only-user: exit 0 at once, before
 *       --log touches its file, when another user runs it (a logon Run entry runs for everyone).
 *
 *   mf-camera-reader mjpeg <file.jpg> <width> <height>
 *       the Windows MJPEG decoder: MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MJPG in) lists the
 *       decoders and their CLSIDs, the first synchronous one gets the JPEG as one MJPG sample,
 *       its output types are logged, NV12 is set and one frame decoded; exit 0 when an NV12
 *       frame of width x height came out.
 *
 * Every line is flushed. --log <file> (any position, both commands) writes them to that file
 * instead of stdout: a scheduled task runs the program itself, with no cmd.exe to redirect (and
 * to strip quotes). Build (llvm-mingw):
 *   x86_64-w64-mingw32-clang -O2 -Wall -o mf-camera-reader.exe mf-camera-reader.c \
 *       -lmfplat -lmf -lmfreadwrite -lmfuuid -lole32 -luuid
 */

#ifndef COBJMACROS
#define COBJMACROS
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mftransform.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static void say(const char* fmt, ...)
{
	SYSTEMTIME t;
	GetLocalTime(&t);
	printf("%02u:%02u:%02u.%03u ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
	fflush(stdout);
}

static DWORD g_timeoutMs = 120000;

static DWORD WINAPI watchdog(LPVOID param)
{
	(void)param;
	Sleep(g_timeoutMs);
	say("RESULT timeout after %lu s", (unsigned long)(g_timeoutMs / 1000));
	ExitProcess(3);
	return 0;
}

/* "NV12", or the GUID for a subtype that is no FOURCC */
static const char* subtype_name(const GUID* g, char* buf, size_t size)
{
	static const GUID base = { 0, 0x0000, 0x0010, { 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
	if ((g->Data2 == base.Data2) && (g->Data3 == base.Data3) &&
	    (memcmp(g->Data4, base.Data4, sizeof(base.Data4)) == 0))
	{
		char c[4] = { (char)(g->Data1 & 0xff), (char)((g->Data1 >> 8) & 0xff),
			          (char)((g->Data1 >> 16) & 0xff), (char)((g->Data1 >> 24) & 0xff) };
		BOOL printable = TRUE;
		for (int i = 0; i < 4; i++)
			printable &= (c[i] >= 0x20) && (c[i] < 0x7f);
		if (printable)
		{
			snprintf(buf, size, "%c%c%c%c", c[0], c[1], c[2], c[3]);
			return buf;
		}
		snprintf(buf, size, "0x%08lx", (unsigned long)g->Data1);
		return buf;
	}
	snprintf(buf, size, "{%08lx-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}",
	         (unsigned long)g->Data1, g->Data2, g->Data3, g->Data4[0], g->Data4[1], g->Data4[2],
	         g->Data4[3], g->Data4[4], g->Data4[5], g->Data4[6], g->Data4[7]);
	return buf;
}

static void type_text(IMFMediaType* type, char* buf, size_t size)
{
	GUID subtype = GUID_NULL;
	UINT64 frameSize = 0;
	UINT64 rate = 0;
	char name[64];
	(void)IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
	(void)IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &frameSize);
	(void)IMFMediaType_GetUINT64(type, &MF_MT_FRAME_RATE, &rate);
	snprintf(buf, size, "%s %lux%lu %lu/%lu fps", subtype_name(&subtype, name, sizeof(name)),
	         (unsigned long)(frameSize >> 32), (unsigned long)(frameSize & 0xffffffff),
	         (unsigned long)(rate >> 32), (unsigned long)(rate & 0xffffffff));
}

static char* utf8(const WCHAR* w)
{
	if (!w)
		return _strdup("(none)");
	const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
	char* s = (char*)calloc((size_t)(n > 0 ? n : 1), 1);
	if (s && (n > 0))
		WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
	return s;
}

static BOOL contains_ci(const WCHAR* hay, const WCHAR* needle)
{
	if (!needle || !*needle)
		return TRUE;
	const size_t n = wcslen(needle);
	for (const WCHAR* p = hay; p && *p; p++)
	{
		if (_wcsnicmp(p, needle, n) == 0)
			return TRUE;
	}
	return FALSE;
}

static uint32_t fnv1a(const BYTE* p, size_t n)
{
	uint32_t h = 2166136261u;
	for (size_t i = 0; i < n; i++)
		h = (h ^ p[i]) * 16777619u;
	return h;
}

/* the first camera whose name contains match, all of them logged; NULL if none */
static IMFActivate* find_camera(const WCHAR* match, BOOL logAll)
{
	IMFAttributes* attrs = NULL;
	IMFActivate** devices = NULL;
	UINT32 count = 0;
	IMFActivate* found = NULL;

	HRESULT hr = MFCreateAttributes(&attrs, 1);
	if (SUCCEEDED(hr))
		hr = IMFAttributes_SetGUID(attrs, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
		                           &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
	if (SUCCEEDED(hr))
		hr = MFEnumDeviceSources(attrs, &devices, &count);
	if (FAILED(hr))
	{
		say("MFEnumDeviceSources failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}

	if (logAll)
		say("cameras: %u", count);
	for (UINT32 i = 0; i < count; i++)
	{
		WCHAR* name = NULL;
		WCHAR* link = NULL;
		UINT32 len = 0;
		(void)IMFActivate_GetAllocatedString(devices[i], &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
		                                     &name, &len);
		(void)IMFActivate_GetAllocatedString(
		    devices[i], &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &len);
		if (logAll)
		{
			char* n8 = utf8(name);
			char* l8 = utf8(link);
			say("camera %u: \"%s\" %s", i, n8, l8);
			free(n8);
			free(l8);
		}
		if (!found && name && contains_ci(name, match))
		{
			found = devices[i];
			IMFActivate_AddRef(found);
		}
		CoTaskMemFree(name);
		CoTaskMemFree(link);
	}

out:
	for (UINT32 i = 0; i < count; i++)
		IMFActivate_Release(devices[i]);
	CoTaskMemFree(devices);
	if (attrs)
		IMFAttributes_Release(attrs);
	return found;
}

static int run_camera(const WCHAR* match, unsigned frames, unsigned minSeconds, unsigned waitS)
{
	IMFActivate* camera = NULL;
	IMFMediaSource* source = NULL;
	IMFSourceReader* reader = NULL;
	int rc = 1;

	UINT32 lastCount = UINT32_MAX;
	for (DWORD start = GetTickCount();;)
	{
		/* log the list when it changed, by its size */
		IMFAttributes* a = NULL;
		IMFActivate** d = NULL;
		UINT32 n = 0;
		if (SUCCEEDED(MFCreateAttributes(&a, 1)) &&
		    SUCCEEDED(IMFAttributes_SetGUID(a, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
		                                    &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) &&
		    SUCCEEDED(MFEnumDeviceSources(a, &d, &n)))
		{
			for (UINT32 i = 0; i < n; i++)
				IMFActivate_Release(d[i]);
			CoTaskMemFree(d);
		}
		if (a)
			IMFAttributes_Release(a);

		camera = find_camera(match, n != lastCount);
		lastCount = n;
		if (camera)
			break;
		if (GetTickCount() - start > waitS * 1000u)
		{
			char* m8 = utf8(match);
			say("RESULT no camera matching \"%s\" within %u s", m8, waitS);
			free(m8);
			return 2;
		}
		Sleep(2000);
	}

	WCHAR* name = NULL;
	UINT32 len = 0;
	(void)IMFActivate_GetAllocatedString(camera, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &len);
	char* name8 = utf8(name);
	CoTaskMemFree(name);
	say("opening \"%s\"", name8);

	HRESULT hr = IMFActivate_ActivateObject(camera, &IID_IMFMediaSource, (void**)&source);
	if (FAILED(hr))
	{
		say("RESULT ActivateObject failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}
	hr = MFCreateSourceReaderFromMediaSource(source, NULL, &reader);
	if (FAILED(hr))
	{
		say("RESULT MFCreateSourceReaderFromMediaSource failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}

	char text[160];
	for (DWORD i = 0;; i++)
	{
		IMFMediaType* t = NULL;
		if (FAILED(IMFSourceReader_GetNativeMediaType(
		        reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &t)))
			break;
		type_text(t, text, sizeof(text));
		say("native type %lu: %s", (unsigned long)i, text);
		IMFMediaType_Release(t);
	}
	IMFMediaType* current = NULL;
	if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(
	        reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &current)))
	{
		type_text(current, text, sizeof(text));
		say("current type: %s", text);
		IMFMediaType_Release(current);
	}

	unsigned got = 0;
	unsigned distinct = 0;
	uint32_t lastHash = 0;
	LONGLONG firstTs = -1;
	LONGLONG lastTs = 0;
	const ULONGLONG opened = GetTickCount64();
	while ((got < frames) || (GetTickCount64() - opened < 1000ull * minSeconds))
	{
		DWORD flags = 0;
		LONGLONG ts = 0;
		IMFSample* sample = NULL;
		hr = IMFSourceReader_ReadSample(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, NULL,
		                                &flags, &ts, &sample);
		if (FAILED(hr) || (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM)))
		{
			say("RESULT ReadSample failed: 0x%08lx flags 0x%lx after %u frames", (unsigned long)hr,
			    (unsigned long)flags, got);
			goto out;
		}
		if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)
			say("media type changed");
		if (!sample)
			continue;

		IMFMediaBuffer* buffer = NULL;
		BYTE* data = NULL;
		DWORD length = 0;
		uint32_t h = 0;
		if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buffer)) &&
		    SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length)))
		{
			h = fnv1a(data, length < 4096 ? length : 4096);
			(void)IMFMediaBuffer_Unlock(buffer);
		}
		if (buffer)
			IMFMediaBuffer_Release(buffer);
		IMFSample_Release(sample);

		if (firstTs < 0)
			firstTs = ts;
		lastTs = ts;
		if ((got == 0) || (h != lastHash))
			distinct++;
		lastHash = h;
		say("frame %u: ts %.3f s, %lu bytes, hash %08x", got, (double)(ts - firstTs) / 1e7,
		    (unsigned long)length, h);
		got++;
	}

	if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(
	        reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &current)))
	{
		type_text(current, text, sizeof(text));
		IMFMediaType_Release(current);
	}
	say("RESULT ok camera=\"%s\" frames=%u distinct=%u span=%.3f s open=%.1f s type=%s", name8, got,
	    distinct, (double)(lastTs - firstTs) / 1e7, (double)(GetTickCount64() - opened) / 1000.0, text);
	rc = 0;

out:
	if (reader)
		IMFSourceReader_Release(reader);
	if (source)
	{
		(void)IMFMediaSource_Shutdown(source);
		IMFMediaSource_Release(source);
	}
	IMFActivate_Release(camera);
	free(name8);
	return rc;
}

static IMFMediaType* video_type(const GUID* subtype, UINT32 w, UINT32 h)
{
	IMFMediaType* t = NULL;
	if (FAILED(MFCreateMediaType(&t)))
		return NULL;
	(void)IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
	(void)IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, subtype);
	(void)IMFMediaType_SetUINT64(t, &MF_MT_FRAME_SIZE, ((UINT64)w << 32) | h);
	(void)IMFMediaType_SetUINT64(t, &MF_MT_FRAME_RATE, ((UINT64)30 << 32) | 1);
	(void)IMFMediaType_SetUINT32(t, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
	return t;
}

/* sets NV12 out of the decoder's available output types, logging them all */
static HRESULT set_nv12_output(IMFTransform* mft)
{
	HRESULT result = MF_E_INVALIDMEDIATYPE;
	char text[160];
	for (DWORD i = 0;; i++)
	{
		IMFMediaType* t = NULL;
		if (FAILED(IMFTransform_GetOutputAvailableType(mft, 0, i, &t)))
			break;
		GUID subtype = GUID_NULL;
		(void)IMFMediaType_GetGUID(t, &MF_MT_SUBTYPE, &subtype);
		type_text(t, text, sizeof(text));
		say("decoder output type %lu: %s", (unsigned long)i, text);
		if ((result != S_OK) && IsEqualGUID(&subtype, &MFVideoFormat_NV12))
			result = IMFTransform_SetOutputType(mft, 0, t, 0);
		IMFMediaType_Release(t);
	}
	return result;
}

static int run_mjpeg(const char* path, UINT32 w, UINT32 h)
{
	int rc = 1;
	IMFActivate** mfts = NULL;
	UINT32 count = 0;
	IMFTransform* mft = NULL;
	IMFSample* in = NULL;
	BYTE* jpeg = NULL;
	long size = 0;

	FILE* f = fopen(path, "rb");
	if (!f || fseek(f, 0, SEEK_END) || ((size = ftell(f)) <= 0) || fseek(f, 0, SEEK_SET) ||
	    !(jpeg = (BYTE*)malloc((size_t)size)) || (fread(jpeg, 1, (size_t)size, f) != (size_t)size))
	{
		say("RESULT cannot read %s", path);
		if (f)
			fclose(f);
		free(jpeg);
		return 1;
	}
	fclose(f);
	say("%s: %ld bytes, %ux%u", path, size, w, h);

	MFT_REGISTER_TYPE_INFO input = { MFMediaType_Video, MFVideoFormat_MJPG };
	HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
	                       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE |
	                           MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
	                       &input, NULL, &mfts, &count);
	if (FAILED(hr))
	{
		say("RESULT MFTEnumEx failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}
	say("MJPG decoders: %u", count);
	IMFActivate* chosen = NULL;
	for (UINT32 i = 0; i < count; i++)
	{
		WCHAR* name = NULL;
		UINT32 len = 0;
		GUID clsid = GUID_NULL;
		UINT32 flags = 0;
		char cl[64];
		(void)IMFActivate_GetAllocatedString(mfts[i], &MFT_FRIENDLY_NAME_Attribute, &name, &len);
		(void)IMFActivate_GetGUID(mfts[i], &MFT_TRANSFORM_CLSID_Attribute, &clsid);
		(void)IMFActivate_GetUINT32(mfts[i], &MF_TRANSFORM_FLAGS_Attribute, &flags);
		char* n8 = utf8(name);
		say("decoder %u: \"%s\" clsid %s flags 0x%x", i, n8, subtype_name(&clsid, cl, sizeof(cl)),
		    flags);
		free(n8);
		CoTaskMemFree(name);
		/* a synchronous one: an async (hardware) MFT needs its event model */
		if (!chosen && !(flags & (MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_HARDWARE)))
			chosen = mfts[i];
	}
	if (!chosen)
	{
		say("RESULT no synchronous MJPG decoder");
		goto out;
	}

	hr = IMFActivate_ActivateObject(chosen, &IID_IMFTransform, (void**)&mft);
	if (FAILED(hr))
	{
		say("RESULT ActivateObject(decoder) failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}

	IMFMediaType* inType = video_type(&MFVideoFormat_MJPG, w, h);
	hr = inType ? IMFTransform_SetInputType(mft, 0, inType, 0) : E_OUTOFMEMORY;
	if (inType)
		IMFMediaType_Release(inType);
	if (FAILED(hr))
	{
		say("RESULT SetInputType(MJPG) failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}
	hr = set_nv12_output(mft);
	if (FAILED(hr))
	{
		say("RESULT the decoder has no NV12 output (0x%08lx)", (unsigned long)hr);
		goto out;
	}
	(void)IMFTransform_ProcessMessage(mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
	(void)IMFTransform_ProcessMessage(mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

	IMFMediaBuffer* buf = NULL;
	BYTE* p = NULL;
	if (FAILED(MFCreateMemoryBuffer((DWORD)size, &buf)) ||
	    FAILED(IMFMediaBuffer_Lock(buf, &p, NULL, NULL)))
		goto out;
	memcpy(p, jpeg, (size_t)size);
	(void)IMFMediaBuffer_Unlock(buf);
	(void)IMFMediaBuffer_SetCurrentLength(buf, (DWORD)size);
	if (FAILED(MFCreateSample(&in)) || FAILED(IMFSample_AddBuffer(in, buf)))
	{
		IMFMediaBuffer_Release(buf);
		goto out;
	}
	IMFMediaBuffer_Release(buf);
	(void)IMFSample_SetSampleTime(in, 0);
	(void)IMFSample_SetSampleDuration(in, 333333);

	hr = IMFTransform_ProcessInput(mft, 0, in, 0);
	if (FAILED(hr))
	{
		say("RESULT ProcessInput failed: 0x%08lx", (unsigned long)hr);
		goto out;
	}
	(void)IMFTransform_ProcessMessage(mft, MFT_MESSAGE_COMMAND_DRAIN, 0);

	for (int attempt = 0; attempt < 4; attempt++)
	{
		MFT_OUTPUT_STREAM_INFO info = { 0 };
		(void)IMFTransform_GetOutputStreamInfo(mft, 0, &info);
		MFT_OUTPUT_DATA_BUFFER out = { 0 };
		IMFSample* outSample = NULL;
		if (!(info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
		                      MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)))
		{
			IMFMediaBuffer* ob = NULL;
			const DWORD cb = info.cbSize ? info.cbSize : w * h * 3 / 2;
			if (FAILED(MFCreateMemoryBuffer(cb, &ob)) || FAILED(MFCreateSample(&outSample)) ||
			    FAILED(IMFSample_AddBuffer(outSample, ob)))
				goto out;
			IMFMediaBuffer_Release(ob);
			out.pSample = outSample;
		}
		DWORD status = 0;
		hr = IMFTransform_ProcessOutput(mft, 0, 1, &out, &status);
		if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
		{
			say("stream change: setting NV12 again");
			if (outSample)
				IMFSample_Release(outSample);
			if (FAILED(set_nv12_output(mft)))
				goto out;
			continue;
		}
		if (FAILED(hr))
		{
			say("RESULT ProcessOutput failed: 0x%08lx", (unsigned long)hr);
			if (outSample)
				IMFSample_Release(outSample);
			goto out;
		}

		IMFMediaBuffer* ob = NULL;
		BYTE* d = NULL;
		DWORD len = 0;
		double yMean = 0;
		if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(out.pSample, &ob)) &&
		    SUCCEEDED(IMFMediaBuffer_Lock(ob, &d, NULL, &len)))
		{
			const size_t luma = (size_t)w * h;
			uint64_t sum = 0;
			for (size_t i = 0; i < luma && i < len; i++)
				sum += d[i];
			yMean = luma ? (double)sum / (double)luma : 0;
			(void)IMFMediaBuffer_Unlock(ob);
		}
		if (ob)
			IMFMediaBuffer_Release(ob);
		IMFMediaType* ot = NULL;
		char text[160] = "?";
		if (SUCCEEDED(IMFTransform_GetOutputCurrentType(mft, 0, &ot)))
		{
			type_text(ot, text, sizeof(text));
			IMFMediaType_Release(ot);
		}
		IMFSample_Release(out.pSample);
		if (out.pEvents)
			IMFCollection_Release(out.pEvents);
		const DWORD want = w * h * 3 / 2;
		say("RESULT %s decoded=%s bytes=%lu (NV12 %ux%u = %lu) luma-mean=%.1f",
		    (len >= want) ? "ok" : "short", text, (unsigned long)len, w, h, (unsigned long)want,
		    yMean);
		rc = (len >= want) ? 0 : 1;
		goto out;
	}
	say("RESULT no frame out of the decoder");

out:
	if (in)
		IMFSample_Release(in);
	if (mft)
		IMFTransform_Release(mft);
	for (UINT32 i = 0; i < count; i++)
		IMFActivate_Release(mfts[i]);
	CoTaskMemFree(mfts);
	free(jpeg);
	return rc;
}

int wmain(int argc, WCHAR** argv)
{
	if (argc < 2)
	{
		fprintf(stderr, "usage: mf-camera-reader camera [--match <text>] [--frames N] [--wait S] "
		                "[--min-seconds S] [--timeout S] [--log <file>] [--only-user <name>] | mjpeg <file.jpg> "
		                "<width> <height> [--log <file>]\n");
		return 1;
	}

	for (int i = 2; i + 1 < argc; i++)
	{
		if (!wcscmp(argv[i], L"--only-user"))
		{
			WCHAR me[256] = L"";
			DWORD n = ARRAYSIZE(me);
			if (GetUserNameW(me, &n) && _wcsicmp(me, argv[i + 1]))
				return 0;
		}
	}
	for (int i = 2; i + 1 < argc; i++)
	{
		if (!wcscmp(argv[i], L"--log") && !_wfreopen(argv[i + 1], L"w", stdout))
			return 1;
	}

	const WCHAR* match = L"Remote Desktop Camera";
	unsigned frames = 60;
	unsigned waitS = 60;
	unsigned minSeconds = 0;
	for (int i = 2; i + 1 < argc; i++)
	{
		if (!wcscmp(argv[i], L"--match"))
			match = argv[++i];
		else if (!wcscmp(argv[i], L"--frames"))
			frames = (unsigned)_wtoi(argv[++i]);
		else if (!wcscmp(argv[i], L"--wait"))
			waitS = (unsigned)_wtoi(argv[++i]);
		else if (!wcscmp(argv[i], L"--timeout"))
			g_timeoutMs = 1000u * (unsigned)_wtoi(argv[++i]);
		else if (!wcscmp(argv[i], L"--min-seconds"))
			minSeconds = (unsigned)_wtoi(argv[++i]);
		else if (!wcscmp(argv[i], L"--log") || !wcscmp(argv[i], L"--only-user"))
			++i;
	}
	HANDLE dog = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
	(void)dog;

	HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
	if (FAILED(hr))
	{
		say("RESULT CoInitializeEx failed: 0x%08lx", (unsigned long)hr);
		return 1;
	}
	hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
	if (FAILED(hr))
	{
		say("RESULT MFStartup failed: 0x%08lx (is Media Foundation installed?)", (unsigned long)hr);
		return 1;
	}
	char user[256] = "?";
	DWORD n = sizeof(user);
	GetUserNameA(user, &n);
	DWORD session = 0;
	ProcessIdToSessionId(GetCurrentProcessId(), &session);
	say("mf-camera-reader: user %s, session %lu", user, (unsigned long)session);

	int rc = 1;
	if (!wcscmp(argv[1], L"camera"))
		rc = run_camera(match, frames, minSeconds, waitS);
	else if (!wcscmp(argv[1], L"mjpeg") && (argc >= 5))
	{
		char* path = utf8(argv[2]);
		rc = run_mjpeg(path, (UINT32)_wtoi(argv[3]), (UINT32)_wtoi(argv[4]));
		free(path);
	}
	else
		say("RESULT unknown command");

	MFShutdown();
	CoUninitialize();
	return rc;
}
