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

/* Frame Server, Frame Server Monitor and every app that opens the camera load the DLL, each
 * in its own process and account, and none of them shows us what it did. So the DLL writes
 * dll-<pid>.log in its own folder (C:\ProgramData\probe-camera-winvcam\ in the probe, whose
 * ACL lets Local Service write): which process loaded it, as whom, and every COM call it
 * received, with the HRESULT of each one that failed. Append-only, flushed per line, so a
 * crash or a TerminateProcess loses nothing written before it. */

#pragma once

#include <windows.h>

#if defined(_MSC_VER)
#include <intrin.h>
#define PROBECAM_CALLER() _ReturnAddress()
#else
#define PROBECAM_CALLER() __builtin_return_address(0)
#endif

namespace probecam
{
	/* DllMain, process attach: opens the log and writes who loaded the DLL */
	void LogOpen(HMODULE module);
	/* DllMain, process detach */
	void LogClose();

	void Log(const char* format, ...);

	/* "<module>+0x<offset>" of a code address: which DLL called us */
	void CallerText(const void* address, char* text, size_t size);

	/* a known interface's name, else the GUID in registry form */
	void GuidText(REFGUID guid, char* text, size_t size);

	/* logs "<what> failed hr=0x..." when hr is a failure; returns hr */
	HRESULT LogIfFailed(const char* what, HRESULT hr);
} // namespace probecam
