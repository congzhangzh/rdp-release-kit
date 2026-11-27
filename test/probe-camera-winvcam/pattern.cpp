/*
 * probe-camera-winvcam: the moving NV12 test pattern
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

#include "frame_producer.h"

#include <new>

namespace probecam
{
	namespace
	{
		constexpr UINT32 kIndexBits = 32;
		constexpr UINT32 kIndexBlock = 16; /* pixels per bit, and the band's height */
		constexpr BYTE kDark = 16;
		constexpr BYTE kBright = 235;

		class PatternProducer final : public FrameProducer
		{
		  public:
			bool FillNV12(BYTE* dst, LONG stride, UINT32 width, UINT32 height) override
			{
				PatternFillNV12(dst, stride, width, height, next_++);
				return true;
			}

		  private:
			UINT32 next_ = 0;
		};
	} // namespace

	FrameProducer* CreatePatternProducer()
	{
		return new (std::nothrow) PatternProducer();
	}

	void PatternFillNV12(BYTE* dst, LONG stride, UINT32 width, UINT32 height, UINT32 index)
	{
		const UINT32 barX = (index * 8) % width;
		for (UINT32 y = 0; y < height; y++)
		{
			BYTE* row = dst + static_cast<size_t>(y) * static_cast<size_t>(stride);
			for (UINT32 x = 0; x < width; x++)
			{
				BYTE v = static_cast<BYTE>((x + 2 * y + 3 * index) & 0xFF);
				if ((x >= barX) && (x < barX + 16))
					v = kBright;
				if ((y < kIndexBlock) && (x < kIndexBits * kIndexBlock))
				{
					const UINT32 bit = x / kIndexBlock;
					v = ((index >> bit) & 1) ? kBright : kDark;
				}
				row[x] = v;
			}
		}

		BYTE* uv = dst + static_cast<size_t>(height) * static_cast<size_t>(stride);
		for (UINT32 j = 0; j < height / 2; j++)
		{
			BYTE* row = uv + static_cast<size_t>(j) * static_cast<size_t>(stride);
			for (UINT32 i = 0; i < width / 2; i++)
			{
				row[2 * i] = static_cast<BYTE>((i + index) & 0xFF);         /* U */
				row[2 * i + 1] = static_cast<BYTE>((j + 2 * index) & 0xFF); /* V */
			}
		}
	}

	bool PatternReadIndex(const BYTE* src, LONG stride, UINT32 width, UINT32 height,
	                      UINT32* index)
	{
		if (!src || !index || (width < kIndexBits * kIndexBlock) || (height < kIndexBlock))
			return false;

		const BYTE* row = src + static_cast<size_t>(kIndexBlock / 2) * static_cast<size_t>(stride);
		UINT32 value = 0;
		for (UINT32 bit = 0; bit < kIndexBits; bit++)
		{
			if (row[bit * kIndexBlock + kIndexBlock / 2] > 128)
				value |= (1u << bit);
		}
		*index = value;
		return true;
	}

	UINT64 Fnv1a64(const BYTE* data, size_t size)
	{
		UINT64 hash = 0xcbf29ce484222325ull;
		for (size_t i = 0; i < size; i++)
		{
			hash ^= data[i];
			hash *= 0x100000001b3ull;
		}
		return hash;
	}
} // namespace probecam
