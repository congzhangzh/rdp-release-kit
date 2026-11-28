/* camera-reader: an app that reads a camera, for windows-host-camera.ps1
 *
 *   camera-reader.exe <name part> <seconds> <out dir>
 *
 * Finds the video capture device whose friendly name contains <name part> ("FreeRDP Camera":
 * Windows shows it as "FreeRDP Camera (Windows Virtual Camera)"), reads it through Media Foundation
 * for <seconds> as any app would (through Frame Server) and says what it got, in lines
 * "READER <key> <value>": the device, the media type, the frames, how many differed from the one
 * before (a still repeats, a client's camera moves) and the mean luma of the first and last
 * frame (a black frame is 16). The first and last frames go to <out dir>\first.nv12, last.nv12.
 * Exit code 0 with frames, 2 without the device, 3 without frames, 1 on an error.
 *
 * Copyright 2026 Cong Zhang <congzhangzh@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static void save(const wchar_t* dir, const wchar_t* name, const BYTE* data, DWORD size)
{
	wchar_t path[MAX_PATH];
	_snwprintf_s(path, MAX_PATH, _TRUNCATE, L"%ls\\%ls", dir, name);
	FILE* f = NULL;
	if (_wfopen_s(&f, path, L"wb") == 0 && f)
	{
		fwrite(data, 1, size, f);
		fclose(f);
	}
}

static UINT64 fnv1a(const BYTE* data, DWORD size)
{
	UINT64 hash = 0xcbf29ce484222325ull;
	for (DWORD i = 0; i < size; i++)
	{
		hash ^= data[i];
		hash *= 0x100000001b3ull;
	}
	return hash;
}

static double mean_luma(const BYTE* data, UINT32 width, UINT32 height)
{
	UINT64 sum = 0;
	for (UINT32 i = 0; i < width * height; i++)
		sum += data[i];
	return (width && height) ? (double)sum / ((double)width * height) : 0.0;
}

int wmain(int argc, wchar_t** argv)
{
	if (argc < 4)
	{
		fprintf(stderr, "usage: camera-reader <name part> <seconds> <out dir>\n");
		return 1;
	}
	const wchar_t* want = argv[1];
	const DWORD seconds = (DWORD)_wtoi(argv[2]);
	const wchar_t* dir = argv[3];

	if (FAILED(CoInitializeEx(NULL, COINIT_MULTITHREADED)) || FAILED(MFStartup(MF_VERSION, MFSTARTUP_FULL)))
		return 1;

	IMFAttributes* filter = NULL;
	IMFActivate** devices = NULL;
	UINT32 count = 0;
	IMFActivate* device = NULL;
	if (FAILED(MFCreateAttributes(&filter, 1)) ||
	    FAILED(IMFAttributes_SetGUID(filter, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
	                                 &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) ||
	    FAILED(MFEnumDeviceSources(filter, &devices, &count)))
		count = 0;
	for (UINT32 i = 0; i < count; i++)
	{
		WCHAR* name = NULL;
		UINT32 length = 0;
		(void)IMFActivate_GetAllocatedString(devices[i], &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name,
		                                     &length);
		printf("READER device \"%ls\"\n", name ? name : L"?");
		if (!device && name && wcsstr(name, want))
		{
			device = devices[i];
			IMFActivate_AddRef(device);
		}
		CoTaskMemFree(name);
		IMFActivate_Release(devices[i]);
	}
	CoTaskMemFree(devices);
	if (filter)
		IMFAttributes_Release(filter);
	if (!device)
	{
		printf("READER found no\n");
		return 2;
	}
	printf("READER found yes\n");
	fflush(stdout);

	IMFMediaSource* source = NULL;
	IMFAttributes* options = NULL;
	IMFSourceReader* reader = NULL;
	IMFMediaType* type = NULL;
	HRESULT hr = IMFActivate_ActivateObject(device, &IID_IMFMediaSource, (void**)&source);
	if (SUCCEEDED(hr))
		hr = MFCreateAttributes(&options, 1);
	if (SUCCEEDED(hr))
		hr = IMFAttributes_SetUINT32(options, &MF_READWRITE_DISABLE_CONVERTERS, TRUE);
	if (SUCCEEDED(hr))
		hr = MFCreateSourceReaderFromMediaSource(source, options, &reader);
	if (SUCCEEDED(hr))
		hr = IMFSourceReader_GetCurrentMediaType(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &type);
	UINT32 width = 0;
	UINT32 height = 0;
	if (SUCCEEDED(hr))
	{
		GUID subtype = { 0 };
		UINT64 size = 0;
		(void)IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
		(void)IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &size);
		width = (UINT32)(size >> 32);
		height = (UINT32)size;
		char fourcc[5] = { (char)(subtype.Data1 & 0xFF), (char)((subtype.Data1 >> 8) & 0xFF),
			               (char)((subtype.Data1 >> 16) & 0xFF), (char)((subtype.Data1 >> 24) & 0xFF), 0 };
		printf("READER type %s %ux%u\n", fourcc, width, height);
	}
	else
		printf("READER error 0x%08lx\n", (unsigned long)hr);
	fflush(stdout);

	const ULONGLONG end = GetTickCount64() + 1000ull * seconds;
	UINT64 frames = 0;
	UINT64 changes = 0;
	UINT64 last = 0;
	double firstLuma = -1.0;
	double lastLuma = -1.0;
	while (SUCCEEDED(hr) && (GetTickCount64() < end))
	{
		DWORD index = 0;
		DWORD flags = 0;
		LONGLONG time = 0;
		IMFSample* sample = NULL;
		hr = IMFSourceReader_ReadSample(reader, (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &index,
		                                &flags, &time, &sample);
		if (FAILED(hr) || (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM)))
		{
			printf("READER error 0x%08lx flags 0x%lx\n", (unsigned long)hr, (unsigned long)flags);
			if (sample)
				IMFSample_Release(sample);
			break;
		}
		if (!sample)
			continue;
		IMFMediaBuffer* buffer = NULL;
		if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buffer)))
		{
			BYTE* data = NULL;
			DWORD length = 0;
			if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length)))
			{
				const UINT64 hash = fnv1a(data, length);
				if (frames == 0)
				{
					firstLuma = mean_luma(data, width, height);
					save(dir, L"first.nv12", data, length);
				}
				else if (hash != last)
					changes++;
				last = hash;
				lastLuma = mean_luma(data, width, height);
				if (GetTickCount64() + 100 >= end)
					save(dir, L"last.nv12", data, length);
				frames++;
				(void)IMFMediaBuffer_Unlock(buffer);
			}
			IMFMediaBuffer_Release(buffer);
		}
		IMFSample_Release(sample);
	}
	printf("READER frames %llu\nREADER changes %llu\nREADER luma-first %.1f\nREADER luma-last %.1f\n",
	       (unsigned long long)frames, (unsigned long long)changes, firstLuma, lastLuma);
	if (type)
		IMFMediaType_Release(type);
	if (reader)
		IMFSourceReader_Release(reader);
	if (options)
		IMFAttributes_Release(options);
	if (source)
	{
		(void)IMFMediaSource_Shutdown(source);
		IMFMediaSource_Release(source);
	}
	(void)IMFActivate_ShutdownObject(device);
	IMFActivate_Release(device);
	(void)MFShutdown();
	CoUninitialize();
	return frames ? 0 : 3;
}
