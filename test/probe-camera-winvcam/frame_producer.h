/*
 * probe-camera-winvcam: what feeds the virtual camera's media source
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

/* The media source does not know where its pictures come from: it asks a FrameProducer
 * for each one. For the probe that is a moving NV12 test pattern. The shadow server will
 * replace it with a reader of its shared-memory ring of decoded camera frames, and the
 * source itself will stay as it is. */

#pragma once

#include <windows.h>

#include <cstddef>

namespace probecam
{
	constexpr UINT32 kWidth = 640;
	constexpr UINT32 kHeight = 480;
	constexpr UINT32 kFpsNumerator = 30;
	constexpr UINT32 kFpsDenominator = 1;
	/* NV12: a full-size Y plane, then one plane of interleaved U and V at half size */
	constexpr DWORD kFrameBytes = kWidth * kHeight * 3 / 2;

	class FrameProducer
	{
	  public:
		virtual ~FrameProducer() = default;

		/* Writes one NV12 frame of width x height at dst: height rows of Y, then height / 2
		 * rows of interleaved UV, each row stride bytes apart. Called from the stream's
		 * RequestSample, one call at a time. Returns false when there is no frame to give. */
		virtual bool FillNV12(BYTE* dst, LONG stride, UINT32 width, UINT32 height) = 0;
	};

	/* The probe's producer: frame n of the test pattern, n counting up from 0. */
	FrameProducer* CreatePatternProducer();

	/* The test pattern, shared by the source (which draws it) and the probe (which checks
	 * what it read back). Frame n has n written as 32 bits in the top 16 rows (block b,
	 * 16 pixels wide, is bright for a 1 bit), a vertical bar that moves 8 pixels per frame,
	 * and gradients that shift with n everywhere else. */
	void PatternFillNV12(BYTE* dst, LONG stride, UINT32 width, UINT32 height, UINT32 index);

	/* Reads the frame number back from a picture drawn by PatternFillNV12. */
	bool PatternReadIndex(const BYTE* src, LONG stride, UINT32 width, UINT32 height,
	                      UINT32* index);

	/* FNV-1a, 64 bit: a checksum the log can print. */
	UINT64 Fnv1a64(const BYTE* data, size_t size);
} // namespace probecam
