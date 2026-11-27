/*
 * probe-camera-winvcam: headers and identities shared by the media source and the probe
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

/* Built with the Windows SDK (10.0.22000 or later, for mfvirtualcamera.h) and these
 * defines on the command line: WINVER=0x0A00 _WIN32_WINNT=0x0A00 NTDDI_VERSION=0x0A00000C
 * (the Frame Server attributes of mfidl.h are declared only for Windows 10 RS-level
 * targets and later). initguid.h makes every GUID of the headers below a selectany
 * definition, so no uuid library is needed for the newer ones. */

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <initguid.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <ks.h>
#include <ksproxy.h>
#include <ksmedia.h>

#include "frame_producer.h"

namespace probecam
{
	/* The media source's COM class: {126FE889-6B3B-4B75-875E-B7B866BE7DB5}. A probe of
	 * its own; the shadow server's source will take a new CLSID. */
	static const CLSID kSourceClsid = { 0x126fe889,
		                                0x6b3b,
		                                0x4b75,
		                                { 0x87, 0x5e, 0xb7, 0xb8, 0x66, 0xbe, 0x7d, 0xb5 } };
#define PROBECAM_CLSID_TEXT L"{126FE889-6B3B-4B75-875E-B7B866BE7DB5}"
	static const wchar_t kSourceClsidString[] = PROBECAM_CLSID_TEXT;
	/* its registration, under HKEY_LOCAL_MACHINE */
	static const wchar_t kSourceClassKey[] = L"SOFTWARE\\Classes\\CLSID\\" PROBECAM_CLSID_TEXT;

	/* Windows appends "Windows Virtual Camera" to it */
	static const wchar_t kFriendlyName[] = L"probe-camera-winvcam";

	/* The class the CLSID makes: an IMFActivate whose ActivateObject creates the source
	 * (media_source.cpp). */
	HRESULT CreateSourceActivate(REFIID riid, void** ppv);

	/* Live COM objects and server locks, for DllCanUnloadNow */
	void ObjectCreated();
	void ObjectDestroyed();
} // namespace probecam
