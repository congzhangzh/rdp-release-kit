/*
 * probe-camera-winvcam: can this Windows register a virtual camera, and does an app read it?
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

/*   probe-camera-winvcam.exe run <full path of probe-camera-source.dll>
 *   probe-camera-winvcam.exe remove
 *
 * run:
 *   api     mfsensorgroup.dll loads and exports MFCreateVirtualCamera (looked up at run
 *           time, so this program starts on a Windows without it)
 *   inproc  our media source, created through COM (its HKLM registration) and read by a
 *           source reader in this process: 30 frames, the pattern checked bit for bit.
 *           Proves the source itself, without Frame Server.
 *   vcam[<access>/<lifetime>]  MFCreateVirtualCamera with our CLSID, Start, then
 *           MFEnumDeviceSources finds it by its friendly name, a source reader reads 30
 *           frames through Frame Server, then Remove. Tried as AllUsers/Session, then
 *           CurrentUser/Session, then AllUsers/System, until one passes.
 * remove: creates each of those cameras again and removes it (a System-lifetime camera
 *         left by a run that was killed).
 *
 * Every result is a line "PROBE <step> <PASS|FAIL|SKIP|INFO> <detail>". Exit code 1 only
 * for a failure of our own code (the in-process read, COM or Media Foundation start-up);
 * a missing API or a camera Windows refuses is a result, exit code 0. A step that hangs is
 * ended by a watchdog: exit code 3 in a vcam step (a result), 1 in our own. */

#include "probe_common.h"

#include <mfreadwrite.h>
#include <mfvirtualcamera.h>

#include <cstdarg>
#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>

namespace
{
	using probecam::kFrameBytes;
	using probecam::kHeight;
	using probecam::kWidth;

	constexpr UINT32 kFramesToRead = 30;

	void Line(const char* step, const char* verdict, const char* format, ...)
	{
		char detail[1024];
		va_list args;
		va_start(args, format);
		(void)vsnprintf(detail, sizeof(detail), format, args);
		va_end(args);
		printf("PROBE %s %s %s\n", step, verdict, detail);
		fflush(stdout);
	}

	std::string Narrow(const wchar_t* text)
	{
		if (!text)
			return std::string();
		const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
		if (size <= 0)
			return std::string();
		std::string out(static_cast<size_t>(size), '\0');
		(void)WideCharToMultiByte(CP_UTF8, 0, text, -1, &out[0], size, nullptr, nullptr);
		out.resize(static_cast<size_t>(size - 1));
		return out;
	}

	std::string FourCC(const GUID& subtype)
	{
		char text[5] = { 0 };
		for (int i = 0; i < 4; i++)
		{
			const char c = static_cast<char>((subtype.Data1 >> (8 * i)) & 0xFF);
			text[i] = ((c >= 32) && (c < 127)) ? c : '?';
		}
		return text;
	}

	/* ------------------------------------------------------------- the watchdog */

	struct Watchdog
	{
		CRITICAL_SECTION cs;
		HANDLE wake = nullptr;
		ULONGLONG deadline = 0; /* 0: disarmed */
		char step[64] = { 0 };
		int exitCode = 1;
	} g_watchdog;

	DWORD WINAPI WatchdogThread(LPVOID)
	{
		for (;;)
		{
			(void)WaitForSingleObject(g_watchdog.wake, 500);
			EnterCriticalSection(&g_watchdog.cs);
			const ULONGLONG deadline = g_watchdog.deadline;
			const int code = g_watchdog.exitCode;
			char step[64];
			memcpy(step, g_watchdog.step, sizeof(step));
			LeaveCriticalSection(&g_watchdog.cs);
			if (deadline && (GetTickCount64() > deadline))
			{
				Line(step, "FAIL", "timed out (watchdog), exit code %d", code);
				TerminateProcess(GetCurrentProcess(), static_cast<UINT>(code));
			}
		}
	}

	void Arm(const char* step, DWORD seconds, int exitCode)
	{
		EnterCriticalSection(&g_watchdog.cs);
		(void)snprintf(g_watchdog.step, sizeof(g_watchdog.step), "%s", step);
		g_watchdog.deadline = GetTickCount64() + 1000ull * seconds;
		g_watchdog.exitCode = exitCode;
		LeaveCriticalSection(&g_watchdog.cs);
	}

	void Disarm()
	{
		EnterCriticalSection(&g_watchdog.cs);
		g_watchdog.deadline = 0;
		LeaveCriticalSection(&g_watchdog.cs);
	}

	/* ------------------------------------------------------------- reading frames */

	struct ReadResult
	{
		HRESULT hr = S_OK;
		std::string subtype;
		UINT32 width = 0;
		UINT32 height = 0;
		UINT32 frames = 0;
		UINT32 exact = 0;        /* frames equal to the pattern of the number they carry */
		UINT32 firstIndex = 0;
		UINT32 lastIndex = 0;
		UINT64 checksum = 0;     /* of the 15th frame */
		DWORD checksumBytes = 0;
	};

	ReadResult ReadFrames(IMFMediaSource* source)
	{
		ReadResult result;
		IMFAttributes* options = nullptr;
		IMFSourceReader* reader = nullptr;
		IMFMediaType* type = nullptr;
		std::vector<BYTE> expected(kFrameBytes);

		HRESULT hr = MFCreateAttributes(&options, 1);
		/* what the source gives, unconverted */
		if (SUCCEEDED(hr))
			hr = options->SetUINT32(MF_READWRITE_DISABLE_CONVERTERS, TRUE);
		if (SUCCEEDED(hr))
			hr = MFCreateSourceReaderFromMediaSource(source, options, &reader);
		if (SUCCEEDED(hr))
			hr = reader->GetCurrentMediaType(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM),
			                                 &type);
		if (SUCCEEDED(hr))
		{
			GUID subtype = GUID_NULL;
			if (SUCCEEDED(type->GetGUID(MF_MT_SUBTYPE, &subtype)))
				result.subtype = FourCC(subtype);
			(void)MFGetAttributeSize(type, MF_MT_FRAME_SIZE, &result.width, &result.height);
		}

		for (UINT32 attempt = 0; SUCCEEDED(hr) && (result.frames < kFramesToRead) && (attempt < 300);
		     attempt++)
		{
			DWORD stream = 0;
			DWORD flags = 0;
			LONGLONG timestamp = 0;
			IMFSample* sample = nullptr;
			hr = reader->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM), 0,
			                        &stream, &flags, &timestamp, &sample);
			if (FAILED(hr))
				break;
			if (flags & (MF_SOURCE_READERF_ERROR | MF_SOURCE_READERF_ENDOFSTREAM))
			{
				hr = (flags & MF_SOURCE_READERF_ERROR) ? E_FAIL : MF_E_END_OF_STREAM;
				if (sample)
					sample->Release();
				break;
			}
			if (!sample)
				continue; /* a stream tick or a type change */

			IMFMediaBuffer* buffer = nullptr;
			if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer)))
			{
				BYTE* data = nullptr;
				DWORD length = 0;
				if (SUCCEEDED(buffer->Lock(&data, nullptr, &length)))
				{
					UINT32 index = 0;
					if ((length >= kFrameBytes) && (result.width == kWidth) &&
					    (result.height == kHeight) &&
					    probecam::PatternReadIndex(data, static_cast<LONG>(kWidth), kWidth, kHeight,
					                               &index))
					{
						probecam::PatternFillNV12(expected.data(), static_cast<LONG>(kWidth), kWidth,
						                          kHeight, index);
						if (memcmp(expected.data(), data, kFrameBytes) == 0)
							result.exact++;
						if (result.frames == 0)
							result.firstIndex = index;
						result.lastIndex = index;
					}
					if (result.frames == 14)
					{
						result.checksum = probecam::Fnv1a64(data, length);
						result.checksumBytes = length;
					}
					buffer->Unlock();
				}
				buffer->Release();
			}
			sample->Release();
			result.frames++;
		}

		if (SUCCEEDED(hr) && (result.frames < kFramesToRead))
			hr = MF_E_NO_SAMPLE_TIMESTAMP; /* gave up after 300 reads without enough frames */
		result.hr = hr;
		if (type)
			type->Release();
		if (reader)
			reader->Release();
		if (options)
			options->Release();
		return result;
	}

	bool Report(const char* step, const ReadResult& r)
	{
		const bool pass = SUCCEEDED(r.hr) && (r.frames == kFramesToRead) && (r.exact == r.frames);
		Line(step, pass ? "PASS" : "FAIL",
		     "hr=0x%08lX subtype=%s size=%ux%u frames=%u exact=%u index=%u..%u "
		     "fnv1a64(frame 15, %lu bytes)=%016llx",
		     static_cast<unsigned long>(r.hr), r.subtype.empty() ? "-" : r.subtype.c_str(),
		     r.width, r.height, r.frames, r.exact, r.firstIndex, r.lastIndex,
		     static_cast<unsigned long>(r.checksumBytes),
		     static_cast<unsigned long long>(r.checksum));
		return pass;
	}

	/* ------------------------------------------------------------- the steps */

	using CreateVirtualCameraFn = HRESULT(WINAPI*)(MFVirtualCameraType, MFVirtualCameraLifetime,
	                                               MFVirtualCameraAccess, LPCWSTR, LPCWSTR,
	                                               const GUID*, ULONG, IMFVirtualCamera**);

	CreateVirtualCameraFn ProbeApi()
	{
		HMODULE module = LoadLibraryExW(L"mfsensorgroup.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
		if (!module)
		{
			Line("api", "FAIL", "mfsensorgroup.dll does not load: error %lu", GetLastError());
			return nullptr;
		}
		auto fn = reinterpret_cast<CreateVirtualCameraFn>(
		    reinterpret_cast<void*>(GetProcAddress(module, "MFCreateVirtualCamera")));
		if (!fn)
			Line("api", "FAIL", "mfsensorgroup.dll has no MFCreateVirtualCamera: error %lu",
			     GetLastError());
		else
			Line("api", "PASS", "mfsensorgroup.dll exports MFCreateVirtualCamera");
		return fn;
	}

	/* the in-process read: our code alone; false means our code is wrong */
	bool ProbeInProcess(const wchar_t* dllPath)
	{
		Arm("inproc", 60, 1);
		IMFActivate* activate = nullptr;
		HRESULT hr = CoCreateInstance(probecam::kSourceClsid, nullptr, CLSCTX_INPROC_SERVER,
		                              IID_PPV_ARGS(&activate));
		if (SUCCEEDED(hr))
			Line("inproc-com", "PASS", "CoCreateInstance(%s) found the HKLM registration",
			     Narrow(probecam::kSourceClsidString).c_str());
		else
		{
			Line("inproc-com", "FAIL", "CoCreateInstance hr=0x%08lX; loading %s directly",
			     static_cast<unsigned long>(hr), Narrow(dllPath).c_str());
			HMODULE module = dllPath ? LoadLibraryW(dllPath) : nullptr;
			using GetClassObjectFn = HRESULT(STDAPICALLTYPE*)(REFCLSID, REFIID, LPVOID*);
			auto getClassObject =
			    module ? reinterpret_cast<GetClassObjectFn>(reinterpret_cast<void*>(
			                 GetProcAddress(module, "DllGetClassObject")))
			           : nullptr;
			IClassFactory* factory = nullptr;
			hr = getClassObject ? getClassObject(probecam::kSourceClsid, IID_PPV_ARGS(&factory))
			                    : HRESULT_FROM_WIN32(GetLastError());
			if (SUCCEEDED(hr))
			{
				hr = factory->CreateInstance(nullptr, IID_PPV_ARGS(&activate));
				factory->Release();
			}
		}

		IMFMediaSource* source = nullptr;
		if (SUCCEEDED(hr))
			hr = activate->ActivateObject(IID_PPV_ARGS(&source));
		bool pass = false;
		if (SUCCEEDED(hr))
		{
			pass = Report("inproc", ReadFrames(source));
			(void)source->Shutdown();
			source->Release();
		}
		else
			Line("inproc", "FAIL", "no media source: hr=0x%08lX", static_cast<unsigned long>(hr));
		if (activate)
		{
			(void)activate->ShutdownObject();
			activate->Release();
		}
		Disarm();
		return pass;
	}

	const char* AccessName(MFVirtualCameraAccess access)
	{
		return (access == MFVirtualCameraAccess_AllUsers) ? "AllUsers" : "CurrentUser";
	}

	const char* LifetimeName(MFVirtualCameraLifetime lifetime)
	{
		return (lifetime == MFVirtualCameraLifetime_System) ? "System" : "Session";
	}

	/* finds the camera among the video capture devices, by friendly name; logs them all */
	IMFActivate* FindCamera(const char* step, bool logAll)
	{
		IMFAttributes* filter = nullptr;
		IMFActivate** devices = nullptr;
		UINT32 count = 0;
		IMFActivate* found = nullptr;
		HRESULT hr = MFCreateAttributes(&filter, 1);
		if (SUCCEEDED(hr))
			hr = filter->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
			                     MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
		if (SUCCEEDED(hr))
			hr = MFEnumDeviceSources(filter, &devices, &count);
		if (FAILED(hr))
			Line(step, "INFO", "MFEnumDeviceSources hr=0x%08lX", static_cast<unsigned long>(hr));
		for (UINT32 i = 0; i < count; i++)
		{
			WCHAR* name = nullptr;
			WCHAR* link = nullptr;
			UINT32 length = 0;
			(void)devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length);
			(void)devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
			                                     &link, &length);
			if (logAll)
				Line(step, "INFO", "video capture device %u: \"%s\" %s", i, Narrow(name).c_str(),
				     Narrow(link).c_str());
			if (!found && name && wcsstr(name, probecam::kFriendlyName))
			{
				found = devices[i];
				found->AddRef();
			}
			CoTaskMemFree(name);
			CoTaskMemFree(link);
			devices[i]->Release();
		}
		CoTaskMemFree(devices);
		if (filter)
			filter->Release();
		if (logAll)
			Line(step, "INFO", "%u video capture device(s)", count);
		return found;
	}

	bool ProbeVirtualCamera(CreateVirtualCameraFn create, MFVirtualCameraAccess access,
	                        MFVirtualCameraLifetime lifetime)
	{
		char step[64];
		(void)snprintf(step, sizeof(step), "vcam[%s/%s]", AccessName(access), LifetimeName(lifetime));
		Arm(step, 120, 3);

		IMFVirtualCamera* camera = nullptr;
		HRESULT hr = create(MFVirtualCameraType_SoftwareCameraSource, lifetime, access,
		                    probecam::kFriendlyName, probecam::kSourceClsidString, nullptr, 0,
		                    &camera);
		Line(step, SUCCEEDED(hr) ? "PASS" : "FAIL", "MFCreateVirtualCamera hr=0x%08lX",
		     static_cast<unsigned long>(hr));
		if (FAILED(hr))
		{
			Disarm();
			return false;
		}

		bool pass = false;
		hr = camera->Start(nullptr);
		Line(step, SUCCEEDED(hr) ? "PASS" : "FAIL", "Start hr=0x%08lX", static_cast<unsigned long>(hr));
		if (SUCCEEDED(hr))
		{
			WCHAR* link = nullptr;
			UINT32 length = 0;
			if (SUCCEEDED(camera->GetAllocatedString(
			        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &length)))
			{
				Line(step, "INFO", "symbolic link %s", Narrow(link).c_str());
				CoTaskMemFree(link);
			}

			/* the device interface can take a moment to appear */
			IMFActivate* device = nullptr;
			for (int attempt = 0; !device && (attempt < 20); attempt++)
			{
				device = FindCamera(step, attempt == 0);
				if (!device)
					Sleep(500);
			}
			if (!device)
			{
				(void)FindCamera(step, true);
				Line(step, "FAIL", "enumerate: no video capture device named \"%s...\"",
				     Narrow(probecam::kFriendlyName).c_str());
			}
			else
			{
				Line(step, "PASS", "enumerate: found by friendly name");
				IMFMediaSource* source = nullptr;
				hr = device->ActivateObject(IID_PPV_ARGS(&source));
				if (SUCCEEDED(hr))
				{
					pass = Report(step, ReadFrames(source));
					(void)source->Shutdown();
					source->Release();
				}
				else
					Line(step, "FAIL", "ActivateObject hr=0x%08lX", static_cast<unsigned long>(hr));
				(void)device->ShutdownObject();
				device->Release();
			}
		}

		hr = camera->Remove();
		Line(step, SUCCEEDED(hr) ? "PASS" : "FAIL", "Remove hr=0x%08lX", static_cast<unsigned long>(hr));
		(void)camera->Shutdown();
		camera->Release();
		Disarm();
		return pass;
	}

	struct Config
	{
		MFVirtualCameraAccess access;
		MFVirtualCameraLifetime lifetime;
	};

	const Config kConfigs[] = {
		{ MFVirtualCameraAccess_AllUsers, MFVirtualCameraLifetime_Session },
		{ MFVirtualCameraAccess_CurrentUser, MFVirtualCameraLifetime_Session },
		{ MFVirtualCameraAccess_AllUsers, MFVirtualCameraLifetime_System },
	};

	int Run(const wchar_t* dllPath)
	{
		const bool inproc = ProbeInProcess(dllPath);

		CreateVirtualCameraFn create = ProbeApi();
		if (!create)
		{
			Line("vcam", "SKIP", "no MFCreateVirtualCamera on this Windows");
		}
		else
		{
			bool any = false;
			for (const Config& config : kConfigs)
			{
				if (ProbeVirtualCamera(create, config.access, config.lifetime))
				{
					any = true;
					break;
				}
			}
			Line("vcam", any ? "PASS" : "FAIL",
			     any ? "an app read the virtual camera through Frame Server"
			         : "no configuration gave readable frames");
		}
		return inproc ? 0 : 1;
	}

	int Remove()
	{
		CreateVirtualCameraFn create = ProbeApi();
		if (!create)
			return 0;
		for (const Config& config : kConfigs)
		{
			char step[64];
			(void)snprintf(step, sizeof(step), "remove[%s/%s]", AccessName(config.access),
			               LifetimeName(config.lifetime));
			IMFVirtualCamera* camera = nullptr;
			HRESULT hr = create(MFVirtualCameraType_SoftwareCameraSource, config.lifetime,
			                    config.access, probecam::kFriendlyName,
			                    probecam::kSourceClsidString, nullptr, 0, &camera);
			if (SUCCEEDED(hr))
			{
				hr = camera->Remove();
				(void)camera->Shutdown();
				camera->Release();
			}
			Line(step, "INFO", "hr=0x%08lX", static_cast<unsigned long>(hr));
		}
		return 0;
	}
} // namespace

int wmain(int argc, wchar_t** argv)
{
	if ((argc < 2) || ((wcscmp(argv[1], L"run") == 0) && (argc < 3)))
	{
		fprintf(stderr, "usage: probe-camera-winvcam run <dll path> | remove\n");
		return 2;
	}

	InitializeCriticalSection(&g_watchdog.cs);
	g_watchdog.wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	HANDLE watchdog = CreateThread(nullptr, 0, WatchdogThread, nullptr, 0, nullptr);
	if (!g_watchdog.wake || !watchdog)
	{
		Line("setup", "FAIL", "watchdog: error %lu", GetLastError());
		return 1;
	}

	HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
	if (FAILED(hr))
	{
		Line("setup", "FAIL", "CoInitializeEx hr=0x%08lX", static_cast<unsigned long>(hr));
		return 1;
	}
	hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
	if (FAILED(hr))
	{
		Line("setup", "FAIL", "MFStartup hr=0x%08lX", static_cast<unsigned long>(hr));
		CoUninitialize();
		return 1;
	}

	const int code = (wcscmp(argv[1], L"remove") == 0) ? Remove() : Run(argv[2]);

	(void)MFShutdown();
	CoUninitialize();
	return code;
}
