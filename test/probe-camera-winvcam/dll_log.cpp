/*
 * probe-camera-winvcam: a file log from inside the media source DLL
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

#include "probe_common.h"
#include "dll_log.h"

#include <sddl.h>

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <cwchar>

namespace probecam
{
	namespace
	{
		CRITICAL_SECTION g_logLock;
		bool g_logLockReady = false;
		HANDLE g_logFile = INVALID_HANDLE_VALUE;

		void Write(const char* line)
		{
			if (!g_logLockReady)
				return;
			EnterCriticalSection(&g_logLock);
			if (g_logFile != INVALID_HANDLE_VALUE)
			{
				DWORD written = 0;
				(void)WriteFile(g_logFile, line, static_cast<DWORD>(strlen(line)), &written, nullptr);
				(void)FlushFileBuffers(g_logFile);
			}
			else
				OutputDebugStringA(line);
			LeaveCriticalSection(&g_logLock);
		}

		void Narrow(const wchar_t* text, char* out, size_t size)
		{
			if (!out || (size == 0))
				return;
			out[0] = '\0';
			if (text)
				(void)WideCharToMultiByte(CP_UTF8, 0, text, -1, out, static_cast<int>(size), nullptr,
				                          nullptr);
			out[size - 1] = '\0';
		}

		const wchar_t* BaseName(const wchar_t* path)
		{
			const wchar_t* slash = wcsrchr(path, L'\\');
			return slash ? slash + 1 : path;
		}

		/* the token's user as a SID string; LookupAccountSid is left out of DllMain */
		void TokenUserText(char* text, size_t size)
		{
			(void)snprintf(text, size, "?");
			HANDLE token = nullptr;
			if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
				return;
			BYTE buffer[256];
			DWORD length = 0;
			if (GetTokenInformation(token, TokenUser, buffer, sizeof(buffer), &length))
			{
				LPWSTR sid = nullptr;
				if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer)->User.Sid, &sid))
				{
					Narrow(sid, text, size);
					LocalFree(sid);
				}
			}
			CloseHandle(token);
		}

		struct KnownGuid
		{
			GUID guid;
			const char* name;
		};
	} // namespace

	void LogOpen(HMODULE module)
	{
		InitializeCriticalSection(&g_logLock);
		g_logLockReady = true;

		/* beside the DLL; where that is not writable (custom media sources may be denied
		 * writes), in the process's temp folder (Local Service:
		 * C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp) */
		wchar_t path[MAX_PATH + 64];
		DWORD besideError = 0;
		const DWORD length = GetModuleFileNameW(module, path, MAX_PATH);
		if ((length > 0) && (length < MAX_PATH))
		{
			wchar_t* slash = wcsrchr(path, L'\\');
			if (slash)
			{
				(void)swprintf(slash + 1, 31, L"dll-%lu.log", GetCurrentProcessId());
				g_logFile = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
				                        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				if (g_logFile == INVALID_HANDLE_VALUE)
					besideError = GetLastError();
			}
		}
		bool inTemp = false;
		if (g_logFile == INVALID_HANDLE_VALUE)
		{
			const DWORD temp = GetTempPathW(MAX_PATH, path);
			if ((temp > 0) && (temp < MAX_PATH))
			{
				(void)swprintf(path + temp, 63, L"probe-camera-winvcam-dll-%lu.log", GetCurrentProcessId());
				g_logFile = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
				                        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				inTemp = (g_logFile != INVALID_HANDLE_VALUE);
			}
		}
		char logPath[MAX_PATH * 2];
		Narrow(path, logPath, sizeof(logPath));

		wchar_t image[MAX_PATH];
		if (!GetModuleFileNameW(nullptr, image, MAX_PATH))
			image[0] = L'\0';
		char imageText[MAX_PATH * 2];
		Narrow(image, imageText, sizeof(imageText));
		DWORD session = 0;
		(void)ProcessIdToSessionId(GetCurrentProcessId(), &session);
		char user[128];
		TokenUserText(user, sizeof(user));
		Log("attach: process %s pid %lu session %lu user %s (S-1-5-19 Local Service, S-1-5-18 "
		    "Local System)",
		    imageText, GetCurrentProcessId(), session, user);
		if (inTemp)
			Log("log beside the DLL not writable (error %lu): this log is %s", besideError, logPath);
		else if (g_logFile == INVALID_HANDLE_VALUE)
			Log("no log file (beside the DLL: error %lu): OutputDebugString only", besideError);
	}

	void LogClose()
	{
		Log("detach");
		if (!g_logLockReady)
			return;
		EnterCriticalSection(&g_logLock);
		if (g_logFile != INVALID_HANDLE_VALUE)
			CloseHandle(g_logFile);
		g_logFile = INVALID_HANDLE_VALUE;
		LeaveCriticalSection(&g_logLock);
	}

	void Log(const char* format, ...)
	{
		SYSTEMTIME now;
		GetLocalTime(&now);
		char line[1536];
		int used = snprintf(line, sizeof(line), "%02u:%02u:%02u.%03u pid %lu tid %lu ", now.wHour,
		                    now.wMinute, now.wSecond, now.wMilliseconds, GetCurrentProcessId(),
		                    GetCurrentThreadId());
		if ((used < 0) || (static_cast<size_t>(used) >= sizeof(line)))
			used = 0;
		va_list args;
		va_start(args, format);
		(void)vsnprintf(line + used, sizeof(line) - static_cast<size_t>(used) - 2, format, args);
		va_end(args);
		const size_t end = strlen(line);
		line[end] = '\n';
		line[end + 1] = '\0';
		Write(line);
	}

	void CallerText(const void* address, char* text, size_t size)
	{
		HMODULE module = nullptr;
		wchar_t path[MAX_PATH];
		if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
		                           GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
		                       static_cast<LPCWSTR>(address), &module) &&
		    GetModuleFileNameW(module, path, MAX_PATH))
		{
			char name[MAX_PATH];
			Narrow(BaseName(path), name, sizeof(name));
			(void)snprintf(text, size, "%s+0x%llx", name,
			               static_cast<unsigned long long>(reinterpret_cast<const BYTE*>(address) -
			                                               reinterpret_cast<const BYTE*>(module)));
		}
		else
			(void)snprintf(text, size, "%p", address);
	}

	void GuidText(REFGUID guid, char* text, size_t size)
	{
		static const KnownGuid known[] = {
			{ __uuidof(IUnknown), "IUnknown" },
			{ __uuidof(IClassFactory), "IClassFactory" },
			{ __uuidof(IMFAttributes), "IMFAttributes" },
			{ __uuidof(IMFActivate), "IMFActivate" },
			{ __uuidof(IMFMediaEventGenerator), "IMFMediaEventGenerator" },
			{ __uuidof(IMFMediaSource), "IMFMediaSource" },
			{ __uuidof(IMFMediaSourceEx), "IMFMediaSourceEx" },
			{ __uuidof(IMFMediaStream), "IMFMediaStream" },
			{ __uuidof(IMFMediaStream2), "IMFMediaStream2" },
			{ __uuidof(IMFGetService), "IMFGetService" },
			{ __uuidof(IMFSampleAllocatorControl), "IMFSampleAllocatorControl" },
			{ { 0x28F54685, 0x06FD, 0x11D2, { 0xB2, 0x7A, 0x00, 0xA0, 0xC9, 0x22, 0x31, 0x96 } },
			  "IKsControl" },
			{ { 0x00000003, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } },
			  "IMarshal" },
			{ { 0xECC8691B, 0xC1DB, 0x4DC0, { 0x85, 0x5E, 0x65, 0xF6, 0xC5, 0x51, 0xAF, 0x49 } },
			  "INoMarshal" },
			{ { 0x94EA2B94, 0xE9CC, 0x49E0, { 0xC0, 0xFF, 0xEE, 0x64, 0xCA, 0x8F, 0x5B, 0x90 } },
			  "IAgileObject" },
			{ { 0x00000019, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } },
			  "IExternalConnection" },
			{ { 0x0000001B, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } },
			  "IIdentityUnmarshal" },
			{ { 0x00000018, 0x0000, 0x0000, { 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } },
			  "IStdMarshalInfo" },
		};
		for (const KnownGuid& k : known)
		{
			if (IsEqualGUID(k.guid, guid))
			{
				(void)snprintf(text, size, "%s", k.name);
				return;
			}
		}
		(void)snprintf(text, size, "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
		               static_cast<unsigned long>(guid.Data1), guid.Data2, guid.Data3, guid.Data4[0],
		               guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4], guid.Data4[5],
		               guid.Data4[6], guid.Data4[7]);
	}

	HRESULT LogIfFailed(const char* what, HRESULT hr)
	{
		if (FAILED(hr))
			Log("%s failed hr=0x%08lX", what, static_cast<unsigned long>(hr));
		return hr;
	}
} // namespace probecam
