/*
 * probe-camera-winvcam: the media source DLL's COM server entry points
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

/* regsvr32 probe-camera-source.dll registers the class under HKLM (not HKCU: Frame Server,
 * Frame Server Monitor and every app that opens the camera load it, each as its own
 * account), as InprocServer32 with ThreadingModel Both: Frame Server calls from MTA
 * threads, and every object here has its own lock. */

#include "probe_common.h"
#include "dll_log.h"

#include <cstring>
#include <new>

namespace
{
	HMODULE g_module = nullptr;
	volatile LONG g_objects = 0;
	volatile LONG g_locks = 0;
	volatile LONG g_accountLogged = 0;

	/* the account by name, once: LookupAccountSid is kept out of DllMain */
	void LogAccountOnce()
	{
		if (InterlockedExchange(&g_accountLogged, 1) != 0)
			return;
		HANDLE token = nullptr;
		if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
			return;
		BYTE buffer[256];
		DWORD length = 0;
		if (GetTokenInformation(token, TokenUser, buffer, sizeof(buffer), &length))
		{
			wchar_t name[128];
			wchar_t domain[128];
			DWORD nameLength = ARRAYSIZE(name);
			DWORD domainLength = ARRAYSIZE(domain);
			SID_NAME_USE use;
			if (LookupAccountSidW(nullptr, reinterpret_cast<TOKEN_USER*>(buffer)->User.Sid, name,
			                      &nameLength, domain, &domainLength, &use))
			{
				char text[512];
				(void)WideCharToMultiByte(CP_UTF8, 0, domain, -1, text, 200, nullptr, nullptr);
				const size_t used = strlen(text);
				text[used] = '\\';
				(void)WideCharToMultiByte(CP_UTF8, 0, name, -1, text + used + 1, 200, nullptr, nullptr);
				probecam::Log("account %s", text);
			}
		}
		CloseHandle(token);
	}

	class ClassFactory final : public IClassFactory
	{
	  public:
		STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
		{
			if (!ppv)
				return E_POINTER;
			if ((riid == __uuidof(IUnknown)) || (riid == __uuidof(IClassFactory)))
			{
				*ppv = static_cast<IClassFactory*>(this);
				AddRef();
				return S_OK;
			}
			*ppv = nullptr;
			return E_NOINTERFACE;
		}
		/* one static instance: its references keep nothing alive */
		STDMETHODIMP_(ULONG) AddRef() override
		{
			return 2;
		}
		STDMETHODIMP_(ULONG) Release() override
		{
			return 1;
		}
		STDMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
		{
			char name[64];
			probecam::GuidText(riid, name, sizeof(name));
			char caller[MAX_PATH + 32];
			probecam::CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
			if (!ppv)
				return E_POINTER;
			*ppv = nullptr;
			if (outer)
				return probecam::LogIfFailed("CreateInstance (aggregation)", CLASS_E_NOAGGREGATION);
			const HRESULT hr = probecam::CreateSourceActivate(riid, ppv);
			probecam::Log("class factory CreateInstance(%s), called from %s: hr=0x%08lX activate %p",
			              name, caller, static_cast<unsigned long>(hr), *ppv);
			return hr;
		}
		STDMETHODIMP LockServer(BOOL lock) override
		{
			if (lock)
				InterlockedIncrement(&g_locks);
			else
				InterlockedDecrement(&g_locks);
			return S_OK;
		}
	};

	ClassFactory g_factory;

	LONG SetStringValue(HKEY key, const wchar_t* name, const wchar_t* value)
	{
		const DWORD bytes = static_cast<DWORD>((wcslen(value) + 1) * sizeof(wchar_t));
		return RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value), bytes);
	}
} // namespace

void probecam::ObjectCreated()
{
	InterlockedIncrement(&g_objects);
}

void probecam::ObjectDestroyed()
{
	InterlockedDecrement(&g_objects);
}

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
	if (reason == DLL_PROCESS_ATTACH)
	{
		g_module = instance;
		DisableThreadLibraryCalls(instance);
		probecam::LogOpen(instance);
	}
	else if (reason == DLL_PROCESS_DETACH)
	{
		probecam::Log("process detach (%s)", reserved ? "process exit" : "FreeLibrary");
		if (!reserved)
			probecam::LogClose();
	}
	return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* ppv)
{
	if (!ppv)
		return E_POINTER;
	*ppv = nullptr;
	char clsidText[64];
	char riidText[64];
	char caller[MAX_PATH + 32];
	probecam::GuidText(clsid, clsidText, sizeof(clsidText));
	probecam::GuidText(riid, riidText, sizeof(riidText));
	probecam::CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
	probecam::Log("DllGetClassObject(%s, %s), called from %s", clsidText, riidText, caller);
	LogAccountOnce();
	if (clsid != probecam::kSourceClsid)
		return probecam::LogIfFailed("DllGetClassObject", CLASS_E_CLASSNOTAVAILABLE);
	return probecam::LogIfFailed("DllGetClassObject", g_factory.QueryInterface(riid, ppv));
}

STDAPI DllCanUnloadNow()
{
	const HRESULT hr = ((g_objects == 0) && (g_locks == 0)) ? S_OK : S_FALSE;
	probecam::Log("DllCanUnloadNow: %s (objects %ld, locks %ld)", (hr == S_OK) ? "yes" : "no",
	              g_objects, g_locks);
	return hr;
}

STDAPI DllRegisterServer()
{
	wchar_t path[MAX_PATH];
	const DWORD length = GetModuleFileNameW(g_module, path, MAX_PATH);
	if ((length == 0) || (length >= MAX_PATH))
		return HRESULT_FROM_WIN32(GetLastError());

	HKEY classKey = nullptr;
	LONG rc = RegCreateKeyExW(HKEY_LOCAL_MACHINE, probecam::kSourceClassKey, 0, nullptr, 0, KEY_WRITE,
	                          nullptr, &classKey, nullptr);
	if (rc != ERROR_SUCCESS)
		return HRESULT_FROM_WIN32(rc);
	rc = SetStringValue(classKey, nullptr, L"probe-camera-winvcam media source");

	HKEY serverKey = nullptr;
	if (rc == ERROR_SUCCESS)
		rc = RegCreateKeyExW(classKey, L"InprocServer32", 0, nullptr, 0, KEY_WRITE, nullptr,
		                     &serverKey, nullptr);
	if (rc == ERROR_SUCCESS)
		rc = SetStringValue(serverKey, nullptr, path);
	if (rc == ERROR_SUCCESS)
		rc = SetStringValue(serverKey, L"ThreadingModel", L"Both");
	if (serverKey)
		RegCloseKey(serverKey);
	RegCloseKey(classKey);
	return HRESULT_FROM_WIN32(rc);
}

STDAPI DllUnregisterServer()
{
	const LONG rc = RegDeleteTreeW(HKEY_LOCAL_MACHINE, probecam::kSourceClassKey);
	if ((rc == ERROR_SUCCESS) || (rc == ERROR_FILE_NOT_FOUND))
		return S_OK;
	return HRESULT_FROM_WIN32(rc);
}
