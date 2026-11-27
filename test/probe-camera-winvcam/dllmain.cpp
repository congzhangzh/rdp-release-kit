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

#include <new>

namespace
{
	HMODULE g_module = nullptr;
	volatile LONG g_objects = 0;
	volatile LONG g_locks = 0;

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
			if (!ppv)
				return E_POINTER;
			*ppv = nullptr;
			if (outer)
				return CLASS_E_NOAGGREGATION;
			return probecam::CreateSourceActivate(riid, ppv);
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

extern "C" BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID)
{
	if (reason == DLL_PROCESS_ATTACH)
	{
		g_module = instance;
		DisableThreadLibraryCalls(instance);
	}
	return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* ppv)
{
	if (!ppv)
		return E_POINTER;
	*ppv = nullptr;
	if (clsid != probecam::kSourceClsid)
		return CLASS_E_CLASSNOTAVAILABLE;
	return g_factory.QueryInterface(riid, ppv);
}

STDAPI DllCanUnloadNow()
{
	return ((g_objects == 0) && (g_locks == 0)) ? S_OK : S_FALSE;
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
