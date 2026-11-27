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
#include <new>
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

	/* ------------------------------------------------------------- Start's callback */

	std::string GuidString(const GUID& g)
	{
		char text[64];
		(void)snprintf(text, sizeof(text), "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
		               static_cast<unsigned long>(g.Data1), g.Data2, g.Data3, g.Data4[0], g.Data4[1],
		               g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
		return text;
	}

	/* IMFVirtualCamera::Start's callback: logs every event the pipeline sends (an
	 * MEExtendedType with MF_FRAMESERVER_VCAMEVENT_EXTENDED_*, or an MEError) */
	class StartCallback final : public IMFAsyncCallback
	{
	  public:
		explicit StartCallback(const char* step)
		{
			(void)snprintf(step_, sizeof(step_), "%s", step);
		}
		STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
		{
			if (!ppv)
				return E_POINTER;
			if ((riid == __uuidof(IUnknown)) || (riid == __uuidof(IMFAsyncCallback)))
			{
				*ppv = static_cast<IMFAsyncCallback*>(this);
				AddRef();
				return S_OK;
			}
			*ppv = nullptr;
			return E_NOINTERFACE;
		}
		STDMETHODIMP_(ULONG) AddRef() override
		{
			return static_cast<ULONG>(InterlockedIncrement(&refs_));
		}
		STDMETHODIMP_(ULONG) Release() override
		{
			const LONG refs = InterlockedDecrement(&refs_);
			if (refs == 0)
				delete this;
			return static_cast<ULONG>(refs);
		}
		STDMETHODIMP GetParameters(DWORD*, DWORD*) override
		{
			return E_NOTIMPL;
		}
		STDMETHODIMP Invoke(IMFAsyncResult* result) override
		{
			if (!result)
				return S_OK;
			IUnknown* unknown = nullptr;
			IMFMediaEvent* event = nullptr;
			if (SUCCEEDED(result->GetObject(&unknown)) && unknown)
				(void)unknown->QueryInterface(IID_PPV_ARGS(&event));
			if (!event && unknown)
				unknown->Release(), unknown = nullptr;
			if (!event && SUCCEEDED(result->GetState(&unknown)) && unknown)
				(void)unknown->QueryInterface(IID_PPV_ARGS(&event));
			if (unknown)
				unknown->Release();
			if (!event)
			{
				Line(step_, "INFO", "Start callback: result status 0x%08lX, no IMFMediaEvent",
				     static_cast<unsigned long>(result->GetStatus()));
				return S_OK;
			}
			MediaEventType type = 0;
			GUID extended = GUID_NULL;
			HRESULT status = S_OK;
			(void)event->GetType(&type);
			(void)event->GetExtendedType(&extended);
			(void)event->GetStatus(&status);
			Line(step_, "INFO", "Start callback: event type %lu extended %s status 0x%08lX",
			     static_cast<unsigned long>(type), GuidString(extended).c_str(),
			     static_cast<unsigned long>(status));
			event->Release();
			return S_OK;
		}

	  private:
		volatile LONG refs_ = 1;
		char step_[64];
	};

	/* PROBECAM_ON_START_FAIL: a command line run (and waited for, 90 s at most) while a
	 * camera whose Start failed still exists, "{step}" replaced by the step's name; the
	 * workflow snapshots PnP devices and event logs with it */
	void RunStartFailHook(const char* step)
	{
		wchar_t command[4096];
		const DWORD length = GetEnvironmentVariableW(L"PROBECAM_ON_START_FAIL", command, ARRAYSIZE(command));
		if ((length == 0) || (length >= ARRAYSIZE(command)))
			return;
		std::wstring line(command);
		wchar_t tag[64];
		size_t n = 0;
		for (const char* p = step; *p && (n + 1 < ARRAYSIZE(tag)); p++)
			tag[n++] = ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9'))
			               ? static_cast<wchar_t>(*p)
			               : L'-';
		tag[n] = L'\0';
		for (size_t at = line.find(L"{step}"); at != std::wstring::npos; at = line.find(L"{step}"))
			line.replace(at, 6, tag);
		STARTUPINFOW si = {};
		si.cb = sizeof(si);
		PROCESS_INFORMATION pi = {};
		std::vector<wchar_t> buffer(line.begin(), line.end());
		buffer.push_back(L'\0');
		if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi))
		{
			Line(step, "INFO", "start-fail hook did not start: error %lu", GetLastError());
			return;
		}
		const DWORD wait = WaitForSingleObject(pi.hProcess, 90000);
		DWORD code = 0;
		(void)GetExitCodeProcess(pi.hProcess, &code);
		CloseHandle(pi.hThread);
		CloseHandle(pi.hProcess);
		Line(step, "INFO", "start-fail hook ran: %s, exit code %lu",
		     (wait == WAIT_OBJECT_0) ? "finished" : "timed out", code);
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
		Arm(step, 300, 3); /* the start-fail hook may take 90 s */

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
		StartCallback* callback = new (std::nothrow) StartCallback(step);
		hr = camera->Start(callback);
		Line(step, SUCCEEDED(hr) ? "PASS" : "FAIL", "Start hr=0x%08lX", static_cast<unsigned long>(hr));
		if (FAILED(hr))
		{
			RunStartFailHook(step);
			/* transient? one more try after the snapshot */
			Sleep(3000);
			hr = camera->Start(callback);
			Line(step, SUCCEEDED(hr) ? "PASS" : "FAIL", "Start again (after 3 s) hr=0x%08lX",
			     static_cast<unsigned long>(hr));
		}
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
		if (callback)
			callback->Release();
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
