/*
 * probe-camera-winvcam: a minimal custom media source for a Windows virtual camera
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

/* What MFCreateVirtualCamera needs behind its sourceId CLSID, following the design of
 * Microsoft's Windows-Camera VirtualCamera sample (SimpleMediaSource) and the "Frame Server
 * Custom Media Source" rules (written from those, no code taken):
 *
 * - the CLSID makes an IMFActivate. Each ActivateObject creates a NEW source (v3: v1/v2
 *   cached one source per activate, so a second activation after its Shutdown got a dead
 *   source; Start failed with MF_E_SHUTDOWN in run 46031460019). DetachObject and
 *   ShutdownObject return E_NOTIMPL, as the custom media source rules say they must.
 * - the source is IMFMediaSourceEx, IMFGetService (mandatory per those rules; v1/v2 lacked
 *   it; no services), IKsControl (no camera controls: ERROR_SET_NOT_FOUND, what a driver
 *   without the handler answers) and IMFSampleAllocatorControl (not in the rules, but in
 *   the sample: Frame Server may give each stream its sample allocator).
 * - its attributes carry what the activate had plus MF_DEVICEMFT_SENSORPROFILE_COLLECTION
 *   with the Legacy profile, which the sample calls mandatory (camera profiles, so that
 *   apps that know nothing of profiles still work).
 * - one stream, IMFMediaStream2, NV12 640x480 at 30 fps; its attributes and its stream
 *   descriptor's carry MF_DEVICESTREAM_STREAM_CATEGORY = PINNAME_VIDEO_CAPTURE (PREVIEW is
 *   not supported for custom sources), MF_DEVICESTREAM_STREAM_ID, FRAMESERVER_SHARED and
 *   FRAMESOURCE_TYPES = colour.
 * - a live source: MENewStream, then MESourceStarted with the system time as VT_I8; no
 *   pause; sample times from MFGetSystemTime; the caller's token copied onto each sample.
 * - frames in 2D buffers (MFCreate2DMediaBuffer, recommended for NV12 in system memory),
 *   or in Frame Server's samples when it provides an allocator.
 *
 * Every call is written to the DLL's log (dll_log.h), failures with their HRESULT.
 *
 * Locking: each object has one critical section; it is never held while waiting for an
 * event (GetEvent may block), and the source calls into its stream with its own lock held
 * (source lock, then stream lock, never the other way round). */

#include "probe_common.h"
#include "dll_log.h"

#include <new>

namespace probecam
{
	namespace
	{
		/* IID_IKsControl (ks.h, ksproxy.h): which SDK header defines the symbol, if any,
		 * differs between SDKs and MSVC builds (C2065 on windows-2022 and windows-11-arm with
		 * SDK 26100), so it is spelled out here */
		const IID kIID_IKsControl = { 0x28F54685,
			                          0x06FD,
			                          0x11D2,
			                          { 0xB2, 0x7A, 0x00, 0xA0, 0xC9, 0x22, 0x31, 0x96 } };

		template <class T> void SafeRelease(T*& p)
		{
			if (p)
			{
				p->Release();
				p = nullptr;
			}
		}

		class AutoLock
		{
		  public:
			explicit AutoLock(CRITICAL_SECTION* cs) : cs_(cs)
			{
				EnterCriticalSection(cs_);
			}
			~AutoLock()
			{
				LeaveCriticalSection(cs_);
			}
			AutoLock(const AutoLock&) = delete;
			AutoLock& operator=(const AutoLock&) = delete;

		  private:
			CRITICAL_SECTION* cs_;
		};

#define RETURN_IF_FAILED_LOG(what, expr)                  \
	do                                                    \
	{                                                     \
		const HRESULT hr_ = LogIfFailed((what), (expr)); \
		if (FAILED(hr_))                                  \
			return hr_;                                   \
	} while (0)

		HRESULT CreateVideoType(IMFMediaType** out)
		{
			IMFMediaType* type = nullptr;
			RETURN_IF_FAILED_LOG("MFCreateMediaType", MFCreateMediaType(&type));
			HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
			if (SUCCEEDED(hr))
				hr = type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
			if (SUCCEEDED(hr))
				hr = MFSetAttributeSize(type, MF_MT_FRAME_SIZE, kWidth, kHeight);
			if (SUCCEEDED(hr))
				hr = MFSetAttributeRatio(type, MF_MT_FRAME_RATE, kFpsNumerator, kFpsDenominator);
			if (SUCCEEDED(hr))
				hr = MFSetAttributeRatio(type, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_DEFAULT_STRIDE, kWidth);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_SAMPLE_SIZE, kFrameBytes);
			if (SUCCEEDED(hr))
				hr = type->SetUINT32(MF_MT_AVG_BITRATE, kFrameBytes * 8 * kFpsNumerator / kFpsDenominator);
			if (FAILED(hr))
			{
				type->Release();
				return LogIfFailed("CreateVideoType", hr);
			}
			*out = type;
			return S_OK;
		}

		HRESULT SetCaptureStreamAttributes(IMFAttributes* attrs)
		{
			RETURN_IF_FAILED_LOG("set STREAM_CATEGORY",
			                     attrs->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE));
			RETURN_IF_FAILED_LOG("set STREAM_ID", attrs->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0));
			RETURN_IF_FAILED_LOG("set FRAMESERVER_SHARED",
			                     attrs->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1));
			RETURN_IF_FAILED_LOG("set FRAMESOURCE_TYPES",
			                     attrs->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
			                                      MFFrameSourceTypes_Color));
			return S_OK;
		}

		/* The Legacy camera profile (any resolution, up to 30 fps, any subtype) for stream 0.
		 * The profile functions live in mfsensorgroup.dll; looked up at run time, so the DLL
		 * also loads where there is none (Wine), and a failure here is logged, not fatal. */
		void AddSensorProfiles(IMFAttributes* attrs)
		{
			using CreateCollectionFn = HRESULT(WINAPI*)(IMFSensorProfileCollection**);
			using CreateProfileFn = HRESULT(WINAPI*)(REFGUID, UINT32, LPCWSTR, IMFSensorProfile**);
			HMODULE module = LoadLibraryExW(L"mfsensorgroup.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
			auto createCollection =
			    module ? reinterpret_cast<CreateCollectionFn>(reinterpret_cast<void*>(
			                 GetProcAddress(module, "MFCreateSensorProfileCollection")))
			           : nullptr;
			auto createProfile = module ? reinterpret_cast<CreateProfileFn>(reinterpret_cast<void*>(
			                                  GetProcAddress(module, "MFCreateSensorProfile")))
			                            : nullptr;
			if (!createCollection || !createProfile)
			{
				Log("sensor profiles: mfsensorgroup.dll or its profile functions missing (error %lu); "
				    "source attributes without MF_DEVICEMFT_SENSORPROFILE_COLLECTION",
				    GetLastError());
				return;
			}
			IMFSensorProfileCollection* collection = nullptr;
			IMFSensorProfile* profile = nullptr;
			HRESULT hr = LogIfFailed("MFCreateSensorProfileCollection", createCollection(&collection));
			if (SUCCEEDED(hr))
				hr = LogIfFailed("MFCreateSensorProfile(Legacy)",
				                 createProfile(KSCAMERAPROFILE_Legacy, 0, nullptr, &profile));
			if (SUCCEEDED(hr))
				hr = LogIfFailed("AddProfileFilter", profile->AddProfileFilter(0, L"((RES==;FRT<=30,1;SUT==))"));
			if (SUCCEEDED(hr))
				hr = LogIfFailed("AddProfile", collection->AddProfile(profile));
			if (SUCCEEDED(hr))
				hr = LogIfFailed("set SENSORPROFILE_COLLECTION",
				                 attrs->SetUnknown(MF_DEVICEMFT_SENSORPROFILE_COLLECTION, collection));
			if (SUCCEEDED(hr))
				Log("sensor profiles: Legacy profile set for stream 0");
			SafeRelease(profile);
			SafeRelease(collection);
		}

		const char* StateName(MF_STREAM_STATE state)
		{
			switch (state)
			{
				case MF_STREAM_STATE_STOPPED:
					return "STOPPED";
				case MF_STREAM_STATE_PAUSED:
					return "PAUSED";
				case MF_STREAM_STATE_RUNNING:
					return "RUNNING";
				default:
					return "?";
			}
		}

		class Source;

		/* ---------------------------------------------------------------- the stream */

		class Stream final : public IMFMediaStream2
		{
		  public:
			static HRESULT Create(Source* source, IMFStreamDescriptor* descriptor,
			                      FrameProducer* producer, Stream** out)
			{
				Stream* stream = new (std::nothrow) Stream(source, descriptor, producer);
				if (!stream)
					return LogIfFailed("new Stream", E_OUTOFMEMORY);
				HRESULT hr = LogIfFailed("stream MFCreateEventQueue", MFCreateEventQueue(&stream->queue_));
				if (SUCCEEDED(hr))
					hr = LogIfFailed("stream MFCreateAttributes", MFCreateAttributes(&stream->attributes_, 4));
				if (SUCCEEDED(hr))
					hr = SetCaptureStreamAttributes(stream->attributes_);
				if (SUCCEEDED(hr))
					hr = LogIfFailed("stream CreateVideoType", CreateVideoType(&stream->type_));
				if (FAILED(hr))
				{
					stream->Shutdown();
					stream->Release();
					return hr;
				}
				*out = stream;
				return S_OK;
			}

			/* IUnknown */
			STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
			{
				if (!ppv)
					return E_POINTER;
				if ((riid == __uuidof(IUnknown)) || (riid == __uuidof(IMFMediaEventGenerator)) ||
				    (riid == __uuidof(IMFMediaStream)) || (riid == __uuidof(IMFMediaStream2)))
				{
					*ppv = static_cast<IMFMediaStream2*>(this);
					AddRef();
					return S_OK;
				}
				char name[64];
				GuidText(riid, name, sizeof(name));
				Log("stream %p QueryInterface(%s): E_NOINTERFACE", static_cast<void*>(this), name);
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

			/* IMFMediaEventGenerator */
			STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override
			{
				IMFMediaEventQueue* queue = nullptr;
				{
					AutoLock lock(&cs_);
					if (!queue_)
						return MF_E_SHUTDOWN;
					queue = queue_;
					queue->AddRef();
				}
				const HRESULT hr = queue->GetEvent(flags, event);
				queue->Release();
				return hr;
			}
			STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("stream BeginGetEvent", MF_E_SHUTDOWN);
				return LogIfFailed("stream BeginGetEvent", queue_->BeginGetEvent(callback, state));
			}
			STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				return queue_->EndGetEvent(result, event);
			}
			STDMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType, HRESULT status,
			                        const PROPVARIANT* value) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				return queue_->QueueEventParamVar(type, extendedType, status, value);
			}

			/* IMFMediaStream */
			STDMETHODIMP GetMediaSource(IMFMediaSource** source) override;
			STDMETHODIMP GetStreamDescriptor(IMFStreamDescriptor** descriptor) override
			{
				if (!descriptor)
					return E_POINTER;
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("stream GetStreamDescriptor", MF_E_SHUTDOWN);
				*descriptor = descriptor_;
				descriptor_->AddRef();
				return S_OK;
			}
			STDMETHODIMP RequestSample(IUnknown* token) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("RequestSample", MF_E_SHUTDOWN);
				if (state_ != MF_STREAM_STATE_RUNNING)
				{
					Log("RequestSample in state %s", StateName(state_));
					return MF_E_MEDIA_SOURCE_WRONGSTATE;
				}
				if (requests_ < 3)
					Log("RequestSample #%lu token %p allocator %p", requests_,
					    static_cast<void*>(token), static_cast<void*>(allocator_));
				requests_++;

				IMFSample* sample = nullptr;
				HRESULT hr = allocator_ ? AllocatedSample(&sample) : MemorySample(&sample);
				if (SUCCEEDED(hr))
					hr = sample->SetSampleTime(MFGetSystemTime());
				if (SUCCEEDED(hr))
					hr = sample->SetSampleDuration(10000000LL * kFpsDenominator / kFpsNumerator);
				if (SUCCEEDED(hr) && token)
					hr = sample->SetUnknown(MFSampleExtension_Token, token);
				if (SUCCEEDED(hr))
					hr = queue_->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample);
				SafeRelease(sample);
				return LogIfFailed("RequestSample", hr);
			}

			/* IMFMediaStream2: Frame Server sets the state of each stream itself */
			STDMETHODIMP SetStreamState(MF_STREAM_STATE value) override
			{
				AutoLock lock(&cs_);
				Log("SetStreamState(%s) from %s", StateName(value), StateName(state_));
				if (!queue_)
					return LogIfFailed("SetStreamState", MF_E_SHUTDOWN);
				switch (value)
				{
					case MF_STREAM_STATE_RUNNING:
						if (state_ != MF_STREAM_STATE_RUNNING)
							RETURN_IF_FAILED_LOG("SetStreamState prepare", PrepareAllocator());
						state_ = value;
						return S_OK;
					case MF_STREAM_STATE_STOPPED:
					case MF_STREAM_STATE_PAUSED:
						state_ = value;
						return S_OK;
					default:
						return LogIfFailed("SetStreamState", MF_E_INVALID_STATE_TRANSITION);
				}
			}
			STDMETHODIMP GetStreamState(MF_STREAM_STATE* value) override
			{
				if (!value)
					return E_POINTER;
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				*value = state_;
				return S_OK;
			}

			/* called by the source, with the source's lock held */
			HRESULT Start()
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("stream Start", MF_E_SHUTDOWN);
				RETURN_IF_FAILED_LOG("stream Start prepare", PrepareAllocator());
				state_ = MF_STREAM_STATE_RUNNING;
				return LogIfFailed("queue MEStreamStarted",
				                   queue_->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr));
			}
			HRESULT Stop()
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("stream Stop", MF_E_SHUTDOWN);
				state_ = MF_STREAM_STATE_STOPPED;
				return LogIfFailed("queue MEStreamStopped",
				                   queue_->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr));
			}
			void Shutdown()
			{
				IMFMediaSourceEx* source = nullptr;
				{
					AutoLock lock(&cs_);
					if (queue_)
						queue_->Shutdown();
					SafeRelease(queue_);
					SafeRelease(attributes_);
					if (allocator_)
						(void)allocator_->UninitializeSampleAllocator();
					SafeRelease(allocator_);
					state_ = MF_STREAM_STATE_STOPPED;
					source = source_;
					source_ = nullptr; /* breaks the source <-> stream cycle */
				}
				if (source)
					source->Release();
			}
			HRESULT GetAttributes(IMFAttributes** out)
			{
				AutoLock lock(&cs_);
				if (!attributes_)
					return LogIfFailed("GetStreamAttributes", MF_E_SHUTDOWN);
				*out = attributes_;
				attributes_->AddRef();
				return S_OK;
			}
			/* IMFSampleAllocatorControl::SetDefaultAllocator, through the source */
			HRESULT SetAllocator(IMFVideoSampleAllocator* allocator)
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return LogIfFailed("SetDefaultAllocator", MF_E_SHUTDOWN);
				if (state_ == MF_STREAM_STATE_RUNNING)
					return LogIfFailed("SetDefaultAllocator while running", MF_E_INVALIDREQUEST);
				SafeRelease(allocator_);
				allocator_ = allocator;
				if (allocator_)
					allocator_->AddRef();
				allocatorReady_ = false;
				return S_OK;
			}

		  private:
			Stream(Source* source, IMFStreamDescriptor* descriptor, FrameProducer* producer);
			~Stream()
			{
				Shutdown();
				SafeRelease(type_);
				SafeRelease(descriptor_);
				DeleteCriticalSection(&cs_);
				ObjectDestroyed();
			}

			/* with cs_ held: a provided allocator is sized for our type before streaming */
			HRESULT PrepareAllocator()
			{
				if (!allocator_ || allocatorReady_)
					return S_OK;
				RETURN_IF_FAILED_LOG("InitializeSampleAllocator",
				                     allocator_->InitializeSampleAllocator(10, type_));
				allocatorReady_ = true;
				Log("provided sample allocator initialized: 10 NV12 %ux%u", kWidth, kHeight);
				return S_OK;
			}

			/* with cs_ held: draws into a sample's first buffer, at its pitch when it is 2D */
			HRESULT FillSample(IMFSample* sample)
			{
				IMFMediaBuffer* buffer = nullptr;
				IMF2DBuffer* buffer2d = nullptr;
				HRESULT hr = sample->GetBufferByIndex(0, &buffer);
				if (SUCCEEDED(hr) && SUCCEEDED(buffer->QueryInterface(IID_PPV_ARGS(&buffer2d))))
				{
					BYTE* scan0 = nullptr;
					LONG pitch = 0;
					hr = buffer2d->Lock2D(&scan0, &pitch);
					if (SUCCEEDED(hr))
					{
						if ((pitch < static_cast<LONG>(kWidth)) ||
						    !producer_->FillNV12(scan0, pitch, kWidth, kHeight))
							hr = MF_E_UNEXPECTED;
						(void)buffer2d->Unlock2D();
					}
					DWORD contiguous = 0;
					if (SUCCEEDED(hr) && SUCCEEDED(buffer2d->GetContiguousLength(&contiguous)))
						hr = buffer->SetCurrentLength(contiguous);
					if (SUCCEEDED(hr) && (requests_ <= 1))
						Log("frame drawn in a 2D buffer, pitch %ld", pitch);
				}
				else if (SUCCEEDED(hr))
				{
					BYTE* data = nullptr;
					DWORD capacity = 0;
					hr = buffer->Lock(&data, &capacity, nullptr);
					if (SUCCEEDED(hr))
					{
						if ((capacity < kFrameBytes) ||
						    !producer_->FillNV12(data, static_cast<LONG>(kWidth), kWidth, kHeight))
							hr = MF_E_UNEXPECTED;
						buffer->Unlock();
					}
					if (SUCCEEDED(hr))
						hr = buffer->SetCurrentLength(kFrameBytes);
				}
				SafeRelease(buffer2d);
				SafeRelease(buffer);
				return LogIfFailed("FillSample", hr);
			}

			/* with cs_ held: a sample of our own (in process, or no allocator given) */
			HRESULT MemorySample(IMFSample** out)
			{
				IMFMediaBuffer* buffer = nullptr;
				IMFSample* sample = nullptr;
				HRESULT hr = LogIfFailed("MFCreate2DMediaBuffer",
				                         MFCreate2DMediaBuffer(kWidth, kHeight, MFVideoFormat_NV12.Data1,
				                                               FALSE, &buffer));
				if (SUCCEEDED(hr))
					hr = MFCreateSample(&sample);
				if (SUCCEEDED(hr))
					hr = sample->AddBuffer(buffer);
				SafeRelease(buffer);
				if (SUCCEEDED(hr))
					hr = FillSample(sample);
				if (FAILED(hr))
				{
					SafeRelease(sample);
					return LogIfFailed("MemorySample", hr);
				}
				*out = sample;
				return S_OK;
			}

			/* with cs_ held: a sample from Frame Server's allocator */
			HRESULT AllocatedSample(IMFSample** out)
			{
				HRESULT hr = PrepareAllocator();
				IMFSample* sample = nullptr;
				if (SUCCEEDED(hr))
					hr = LogIfFailed("AllocateSample", allocator_->AllocateSample(&sample));
				if (SUCCEEDED(hr))
					hr = FillSample(sample);
				if (FAILED(hr))
				{
					SafeRelease(sample);
					return LogIfFailed("AllocatedSample", hr);
				}
				*out = sample;
				return S_OK;
			}

			volatile LONG refs_ = 1;
			CRITICAL_SECTION cs_;
			IMFMediaSourceEx* source_ = nullptr; /* strong, until Shutdown */
			IMFStreamDescriptor* descriptor_ = nullptr;
			IMFMediaEventQueue* queue_ = nullptr;
			IMFAttributes* attributes_ = nullptr;
			IMFMediaType* type_ = nullptr;
			IMFVideoSampleAllocator* allocator_ = nullptr; /* Frame Server's, if it gave one */
			bool allocatorReady_ = false;
			FrameProducer* producer_ = nullptr; /* owned by the source */
			MF_STREAM_STATE state_ = MF_STREAM_STATE_STOPPED;
			ULONG requests_ = 0;
		};

		/* ---------------------------------------------------------------- the source */

		class Source final : public IMFMediaSourceEx,
		                     public IMFGetService,
		                     public IKsControl,
		                     public IMFSampleAllocatorControl
		{
		  public:
			static HRESULT Create(IMFAttributes* activateAttributes, Source** out)
			{
				Source* source = new (std::nothrow) Source();
				if (!source)
					return LogIfFailed("new Source", E_OUTOFMEMORY);
				const HRESULT hr = source->Initialize(activateAttributes);
				if (FAILED(hr))
				{
					(void)source->Shutdown();
					source->Release();
					return LogIfFailed("Source::Initialize", hr);
				}
				*out = source;
				return S_OK;
			}

			/* IUnknown */
			STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
			{
				if (!ppv)
					return E_POINTER;
				if ((riid == __uuidof(IUnknown)) || (riid == __uuidof(IMFMediaEventGenerator)) ||
				    (riid == __uuidof(IMFMediaSource)) || (riid == __uuidof(IMFMediaSourceEx)))
					*ppv = static_cast<IMFMediaSourceEx*>(this);
				else if (riid == __uuidof(IMFGetService))
					*ppv = static_cast<IMFGetService*>(this);
				else if (riid == kIID_IKsControl)
					*ppv = static_cast<IKsControl*>(this);
				else if (riid == __uuidof(IMFSampleAllocatorControl))
					*ppv = static_cast<IMFSampleAllocatorControl*>(this);
				else
				{
					char name[64];
					GuidText(riid, name, sizeof(name));
					Log("source %p QueryInterface(%s): E_NOINTERFACE", static_cast<void*>(this), name);
					*ppv = nullptr;
					return E_NOINTERFACE;
				}
				AddRef();
				return S_OK;
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

			/* IMFMediaEventGenerator */
			STDMETHODIMP GetEvent(DWORD flags, IMFMediaEvent** event) override
			{
				IMFMediaEventQueue* queue = nullptr;
				{
					AutoLock lock(&cs_);
					if (shutdown_)
						return MF_E_SHUTDOWN;
					queue = queue_;
					queue->AddRef();
				}
				const HRESULT hr = queue->GetEvent(flags, event);
				queue->Release();
				return hr;
			}
			STDMETHODIMP BeginGetEvent(IMFAsyncCallback* callback, IUnknown* state) override
			{
				AutoLock lock(&cs_);
				if (shutdown_)
					return LogIfFailed("source BeginGetEvent", MF_E_SHUTDOWN);
				return LogIfFailed("source BeginGetEvent", queue_->BeginGetEvent(callback, state));
			}
			STDMETHODIMP EndGetEvent(IMFAsyncResult* result, IMFMediaEvent** event) override
			{
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				return queue_->EndGetEvent(result, event);
			}
			STDMETHODIMP QueueEvent(MediaEventType type, REFGUID extendedType, HRESULT status,
			                        const PROPVARIANT* value) override
			{
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				return queue_->QueueEventParamVar(type, extendedType, status, value);
			}

			/* IMFMediaSource */
			STDMETHODIMP GetCharacteristics(DWORD* characteristics) override
			{
				if (!characteristics)
					return E_POINTER;
				AutoLock lock(&cs_);
				Log("source %p GetCharacteristics%s", static_cast<void*>(this),
				    shutdown_ ? " after Shutdown" : "");
				if (shutdown_)
					return LogIfFailed("GetCharacteristics", MF_E_SHUTDOWN);
				*characteristics = MFMEDIASOURCE_IS_LIVE;
				return S_OK;
			}
			STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** out) override
			{
				if (!out)
					return E_POINTER;
				AutoLock lock(&cs_);
				Log("source %p CreatePresentationDescriptor%s", static_cast<void*>(this),
				    shutdown_ ? " after Shutdown" : "");
				if (shutdown_)
					return LogIfFailed("CreatePresentationDescriptor", MF_E_SHUTDOWN);
				return LogIfFailed("CreatePresentationDescriptor", presentation_->Clone(out));
			}
			STDMETHODIMP Start(IMFPresentationDescriptor* presentation, const GUID* timeFormat,
			                   const PROPVARIANT* startPosition) override
			{
				char format[64];
				GuidText(timeFormat ? *timeFormat : GUID_NULL, format, sizeof(format));
				Log("source %p Start(pd %p, time format %s, start position vt %u)",
				    static_cast<void*>(this), static_cast<void*>(presentation), format,
				    startPosition ? static_cast<unsigned>(startPosition->vt) : 0xFFFFu);
				if (!presentation)
					return LogIfFailed("Start", E_INVALIDARG);
				if (timeFormat && (*timeFormat != GUID_NULL))
					return LogIfFailed("Start", MF_E_UNSUPPORTED_TIME_FORMAT);

				AutoLock lock(&cs_);
				if (shutdown_)
					return LogIfFailed("Start after Shutdown", MF_E_SHUTDOWN);

				DWORD count = 0;
				RETURN_IF_FAILED_LOG("Start GetStreamDescriptorCount",
				                     presentation->GetStreamDescriptorCount(&count));
				if (count != 1)
					return LogIfFailed("Start: stream count", E_INVALIDARG);
				BOOL selected = FALSE;
				IMFStreamDescriptor* descriptor = nullptr;
				RETURN_IF_FAILED_LOG("Start GetStreamDescriptorByIndex",
				                     presentation->GetStreamDescriptorByIndex(0, &selected, &descriptor));
				DWORD id = 0;
				const HRESULT idHr = descriptor->GetStreamIdentifier(&id);
				descriptor->Release();
				RETURN_IF_FAILED_LOG("Start GetStreamIdentifier", idHr);
				Log("source %p Start: stream %lu selected %d", static_cast<void*>(this), id, selected);
				if (id != 0)
					return LogIfFailed("Start: stream id", E_INVALIDARG);

				if (selected)
				{
					/* MENewStream the first time, MEUpdatedStream on a restart */
					RETURN_IF_FAILED_LOG("queue MENewStream", queue_->QueueEventParamUnk(
					                                             announced_ ? MEUpdatedStream : MENewStream,
					                                             GUID_NULL, S_OK,
					                                             static_cast<IMFMediaStream*>(stream_)));
					announced_ = true;
					RETURN_IF_FAILED_LOG("stream Start", stream_->Start());
				}

				PROPVARIANT startTime;
				PropVariantInit(&startTime);
				startTime.vt = VT_I8;
				startTime.hVal.QuadPart = MFGetSystemTime();
				return LogIfFailed("queue MESourceStarted",
				                   queue_->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK, &startTime));
			}
			STDMETHODIMP Stop() override
			{
				AutoLock lock(&cs_);
				Log("source %p Stop", static_cast<void*>(this));
				if (shutdown_)
					return LogIfFailed("Stop after Shutdown", MF_E_SHUTDOWN);
				RETURN_IF_FAILED_LOG("stream Stop", stream_->Stop());
				return LogIfFailed("queue MESourceStopped",
				                   queue_->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr));
			}
			STDMETHODIMP Pause() override
			{
				AutoLock lock(&cs_);
				Log("source %p Pause: not supported", static_cast<void*>(this));
				if (shutdown_)
					return MF_E_SHUTDOWN;
				return MF_E_INVALID_STATE_TRANSITION; /* a live camera does not pause */
			}
			STDMETHODIMP Shutdown() override
			{
				char caller[MAX_PATH + 32];
				CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
				Stream* stream = nullptr;
				{
					AutoLock lock(&cs_);
					Log("source %p Shutdown, called from %s%s", static_cast<void*>(this), caller,
					    shutdown_ ? " (again)" : "");
					if (shutdown_)
						return MF_E_SHUTDOWN;
					shutdown_ = true;
					if (queue_)
						queue_->Shutdown();
					stream = stream_;
					stream_ = nullptr;
				}
				/* outside our lock: the stream gives back its reference to us */
				if (stream)
				{
					stream->Shutdown();
					stream->Release();
				}
				return S_OK;
			}

			/* IMFMediaSourceEx */
			STDMETHODIMP GetSourceAttributes(IMFAttributes** out) override
			{
				if (!out)
					return E_POINTER;
				AutoLock lock(&cs_);
				Log("source %p GetSourceAttributes", static_cast<void*>(this));
				if (shutdown_)
					return LogIfFailed("GetSourceAttributes", MF_E_SHUTDOWN);
				*out = attributes_; /* the store itself, not a copy */
				attributes_->AddRef();
				return S_OK;
			}
			STDMETHODIMP GetStreamAttributes(DWORD streamId, IMFAttributes** out) override
			{
				if (!out)
					return E_POINTER;
				AutoLock lock(&cs_);
				Log("source %p GetStreamAttributes(%lu)", static_cast<void*>(this), streamId);
				if (shutdown_)
					return LogIfFailed("GetStreamAttributes", MF_E_SHUTDOWN);
				if (streamId != 0)
					return LogIfFailed("GetStreamAttributes", MF_E_INVALIDSTREAMNUMBER);
				return stream_->GetAttributes(out);
			}
			STDMETHODIMP SetD3DManager(IUnknown* manager) override
			{
				/* system-memory samples only */
				AutoLock lock(&cs_);
				Log("source %p SetD3DManager(%p): ignored", static_cast<void*>(this),
				    static_cast<void*>(manager));
				return shutdown_ ? MF_E_SHUTDOWN : S_OK;
			}

			/* IMFGetService: none */
			STDMETHODIMP GetService(REFGUID service, REFIID riid, LPVOID* ppv) override
			{
				char serviceName[64];
				char interfaceName[64];
				GuidText(service, serviceName, sizeof(serviceName));
				GuidText(riid, interfaceName, sizeof(interfaceName));
				Log("source %p GetService(%s, %s): MF_E_UNSUPPORTED_SERVICE", static_cast<void*>(this),
				    serviceName, interfaceName);
				if (ppv)
					*ppv = nullptr;
				return MF_E_UNSUPPORTED_SERVICE;
			}

			/* IKsControl: no camera controls */
			STDMETHODIMP KsProperty(PKSPROPERTY property, ULONG length, LPVOID, ULONG, ULONG*) override
			{
				if (property && (length >= sizeof(KSPROPERTY)))
				{
					char set[64];
					GuidText(property->Set, set, sizeof(set));
					Log("source %p KsProperty(set %s id %lu flags 0x%lx): ERROR_SET_NOT_FOUND",
					    static_cast<void*>(this), set, property->Id, property->Flags);
				}
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}
			STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG*) override
			{
				Log("source %p KsMethod: ERROR_SET_NOT_FOUND", static_cast<void*>(this));
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}
			STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG*) override
			{
				Log("source %p KsEvent: ERROR_SET_NOT_FOUND", static_cast<void*>(this));
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}

			/* IMFSampleAllocatorControl: the stream draws into Frame Server's samples */
			STDMETHODIMP SetDefaultAllocator(DWORD streamId, IUnknown* allocator) override
			{
				AutoLock lock(&cs_);
				Log("source %p SetDefaultAllocator(stream %lu, %p)", static_cast<void*>(this), streamId,
				    static_cast<void*>(allocator));
				if (shutdown_)
					return LogIfFailed("SetDefaultAllocator", MF_E_SHUTDOWN);
				if (streamId != 0)
					return LogIfFailed("SetDefaultAllocator", MF_E_INVALIDSTREAMNUMBER);
				if (!allocator)
					return LogIfFailed("SetDefaultAllocator", E_POINTER);
				IMFVideoSampleAllocator* video = nullptr;
				RETURN_IF_FAILED_LOG("SetDefaultAllocator QI IMFVideoSampleAllocator",
				                     allocator->QueryInterface(IID_PPV_ARGS(&video)));
				const HRESULT hr = stream_->SetAllocator(video);
				video->Release();
				return hr;
			}
			STDMETHODIMP GetAllocatorUsage(DWORD streamId, DWORD* inputStreamId,
			                               MFSampleAllocatorUsage* usage) override
			{
				AutoLock lock(&cs_);
				Log("source %p GetAllocatorUsage(stream %lu): UsesProvidedAllocator",
				    static_cast<void*>(this), streamId);
				if (shutdown_)
					return LogIfFailed("GetAllocatorUsage", MF_E_SHUTDOWN);
				if (!inputStreamId || !usage)
					return E_POINTER;
				if (streamId != 0)
					return LogIfFailed("GetAllocatorUsage", MF_E_INVALIDSTREAMNUMBER);
				*inputStreamId = streamId;
				*usage = MFSampleAllocatorUsage_UsesProvidedAllocator;
				return S_OK;
			}

		  private:
			Source()
			{
				InitializeCriticalSection(&cs_);
				ObjectCreated();
				Log("source %p created", static_cast<void*>(this));
			}
			~Source()
			{
				if (!shutdown_)
					(void)Shutdown();
				SafeRelease(queue_);
				SafeRelease(presentation_);
				SafeRelease(attributes_);
				delete producer_;
				DeleteCriticalSection(&cs_);
				Log("source %p destroyed", static_cast<void*>(this));
				ObjectDestroyed();
			}

			HRESULT Initialize(IMFAttributes* activateAttributes)
			{
				producer_ = CreatePatternProducer();
				if (!producer_)
					return E_OUTOFMEMORY;
				RETURN_IF_FAILED_LOG("source MFCreateEventQueue", MFCreateEventQueue(&queue_));
				RETURN_IF_FAILED_LOG("source MFCreateAttributes", MFCreateAttributes(&attributes_, 8));
				/* what Frame Server put on the activate (e.g. the symbolic link) */
				if (activateAttributes)
				{
					UINT32 items = 0;
					(void)activateAttributes->GetCount(&items);
					Log("source %p: %u attribute(s) from the activate", static_cast<void*>(this), items);
					for (UINT32 i = 0; i < items; i++)
					{
						GUID key = GUID_NULL;
						if (SUCCEEDED(activateAttributes->GetItemByIndex(i, &key, nullptr)))
						{
							char name[64];
							GuidText(key, name, sizeof(name));
							Log("  activate attribute %s", name);
						}
					}
					RETURN_IF_FAILED_LOG("CopyAllItems", activateAttributes->CopyAllItems(attributes_));
				}
				AddSensorProfiles(attributes_);

				IMFMediaType* type = nullptr;
				RETURN_IF_FAILED_LOG("CreateVideoType", CreateVideoType(&type));
				IMFStreamDescriptor* descriptor = nullptr;
				HRESULT hr = LogIfFailed("MFCreateStreamDescriptor",
				                         MFCreateStreamDescriptor(0, 1, &type, &descriptor));
				IMFMediaTypeHandler* handler = nullptr;
				if (SUCCEEDED(hr))
					hr = LogIfFailed("GetMediaTypeHandler", descriptor->GetMediaTypeHandler(&handler));
				if (SUCCEEDED(hr))
					hr = LogIfFailed("SetCurrentMediaType", handler->SetCurrentMediaType(type));
				if (SUCCEEDED(hr))
					hr = SetCaptureStreamAttributes(descriptor);
				if (SUCCEEDED(hr))
					hr = LogIfFailed("MFCreatePresentationDescriptor",
					                 MFCreatePresentationDescriptor(1, &descriptor, &presentation_));
				if (SUCCEEDED(hr))
					hr = LogIfFailed("SelectStream", presentation_->SelectStream(0));
				if (SUCCEEDED(hr))
					hr = Stream::Create(this, descriptor, producer_, &stream_);
				SafeRelease(handler);
				SafeRelease(descriptor);
				SafeRelease(type);
				return hr;
			}

			volatile LONG refs_ = 1;
			CRITICAL_SECTION cs_;
			bool shutdown_ = false;
			bool announced_ = false;
			IMFMediaEventQueue* queue_ = nullptr;
			IMFAttributes* attributes_ = nullptr;
			IMFPresentationDescriptor* presentation_ = nullptr;
			Stream* stream_ = nullptr;
			FrameProducer* producer_ = nullptr;
		};

		Stream::Stream(Source* source, IMFStreamDescriptor* descriptor, FrameProducer* producer)
		    : source_(source), descriptor_(descriptor), producer_(producer)
		{
			InitializeCriticalSection(&cs_);
			source_->AddRef();
			descriptor_->AddRef();
			ObjectCreated();
		}

		STDMETHODIMP Stream::GetMediaSource(IMFMediaSource** source)
		{
			if (!source)
				return E_POINTER;
			AutoLock lock(&cs_);
			if (!source_)
				return LogIfFailed("stream GetMediaSource", MF_E_SHUTDOWN);
			*source = source_;
			source_->AddRef();
			return S_OK;
		}

		/* ---------------------------------------------------------------- the activate */

		/* IMFActivate is an attribute store too: every IMFAttributes call goes to attrs_. */
		class Activate final : public IMFActivate
		{
		  public:
			Activate()
			{
				InitializeCriticalSection(&cs_);
				ObjectCreated();
			}
			HRESULT Initialize()
			{
				return LogIfFailed("activate MFCreateAttributes", MFCreateAttributes(&attrs_, 4));
			}

			/* IUnknown */
			STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override
			{
				if (!ppv)
					return E_POINTER;
				if ((riid == __uuidof(IUnknown)) || (riid == __uuidof(IMFAttributes)) ||
				    (riid == __uuidof(IMFActivate)))
				{
					*ppv = static_cast<IMFActivate*>(this);
					AddRef();
					return S_OK;
				}
				char name[64];
				GuidText(riid, name, sizeof(name));
				Log("activate %p QueryInterface(%s): E_NOINTERFACE", static_cast<void*>(this), name);
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

			/* IMFActivate: a new source for every activation */
			STDMETHODIMP ActivateObject(REFIID riid, void** ppv) override
			{
				char name[64];
				GuidText(riid, name, sizeof(name));
				char caller[MAX_PATH + 32];
				CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
				Log("activate %p ActivateObject(%s), called from %s", static_cast<void*>(this), name,
				    caller);
				if (!ppv)
					return E_POINTER;
				*ppv = nullptr;
				AutoLock lock(&cs_);
				Source* source = nullptr;
				RETURN_IF_FAILED_LOG("ActivateObject: Source::Create", Source::Create(attrs_, &source));
				const HRESULT hr = LogIfFailed("ActivateObject: QueryInterface",
				                               source->QueryInterface(riid, ppv));
				if (SUCCEEDED(hr))
				{
					SafeRelease(source_);
					source_ = source; /* the last one, released with the activate */
					Log("activate %p ActivateObject: source %p", static_cast<void*>(this),
					    static_cast<void*>(source));
				}
				else
				{
					(void)source->Shutdown();
					source->Release();
				}
				return hr;
			}
			/* "DetachObject and ShutdownObject must return E_NOTIMPL" (Frame Server Custom
			 * Media Source, IMFActivate): the source's owner shuts the source down */
			STDMETHODIMP ShutdownObject() override
			{
				char caller[MAX_PATH + 32];
				CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
				Log("activate %p ShutdownObject, called from %s: E_NOTIMPL", static_cast<void*>(this),
				    caller);
				return E_NOTIMPL;
			}
			STDMETHODIMP DetachObject() override
			{
				char caller[MAX_PATH + 32];
				CallerText(PROBECAM_CALLER(), caller, sizeof(caller));
				Log("activate %p DetachObject, called from %s: E_NOTIMPL", static_cast<void*>(this), caller);
				return E_NOTIMPL;
			}

			/* IMFAttributes */
			STDMETHODIMP GetItem(REFGUID key, PROPVARIANT* value) override
			{
				return attrs_->GetItem(key, value);
			}
			STDMETHODIMP GetItemType(REFGUID key, MF_ATTRIBUTE_TYPE* type) override
			{
				return attrs_->GetItemType(key, type);
			}
			STDMETHODIMP CompareItem(REFGUID key, REFPROPVARIANT value, BOOL* result) override
			{
				return attrs_->CompareItem(key, value, result);
			}
			STDMETHODIMP Compare(IMFAttributes* theirs, MF_ATTRIBUTES_MATCH_TYPE type,
			                     BOOL* result) override
			{
				return attrs_->Compare(theirs, type, result);
			}
			STDMETHODIMP GetUINT32(REFGUID key, UINT32* value) override
			{
				return attrs_->GetUINT32(key, value);
			}
			STDMETHODIMP GetUINT64(REFGUID key, UINT64* value) override
			{
				return attrs_->GetUINT64(key, value);
			}
			STDMETHODIMP GetDouble(REFGUID key, double* value) override
			{
				return attrs_->GetDouble(key, value);
			}
			STDMETHODIMP GetGUID(REFGUID key, GUID* value) override
			{
				return attrs_->GetGUID(key, value);
			}
			STDMETHODIMP GetStringLength(REFGUID key, UINT32* length) override
			{
				return attrs_->GetStringLength(key, length);
			}
			STDMETHODIMP GetString(REFGUID key, LPWSTR value, UINT32 size, UINT32* length) override
			{
				return attrs_->GetString(key, value, size, length);
			}
			STDMETHODIMP GetAllocatedString(REFGUID key, LPWSTR* value, UINT32* length) override
			{
				return attrs_->GetAllocatedString(key, value, length);
			}
			STDMETHODIMP GetBlobSize(REFGUID key, UINT32* size) override
			{
				return attrs_->GetBlobSize(key, size);
			}
			STDMETHODIMP GetBlob(REFGUID key, UINT8* buffer, UINT32 size, UINT32* written) override
			{
				return attrs_->GetBlob(key, buffer, size, written);
			}
			STDMETHODIMP GetAllocatedBlob(REFGUID key, UINT8** buffer, UINT32* size) override
			{
				return attrs_->GetAllocatedBlob(key, buffer, size);
			}
			STDMETHODIMP GetUnknown(REFGUID key, REFIID riid, LPVOID* ppv) override
			{
				return attrs_->GetUnknown(key, riid, ppv);
			}
			STDMETHODIMP SetItem(REFGUID key, REFPROPVARIANT value) override
			{
				return attrs_->SetItem(key, value);
			}
			STDMETHODIMP DeleteItem(REFGUID key) override
			{
				return attrs_->DeleteItem(key);
			}
			STDMETHODIMP DeleteAllItems() override
			{
				return attrs_->DeleteAllItems();
			}
			STDMETHODIMP SetUINT32(REFGUID key, UINT32 value) override
			{
				return attrs_->SetUINT32(key, value);
			}
			STDMETHODIMP SetUINT64(REFGUID key, UINT64 value) override
			{
				return attrs_->SetUINT64(key, value);
			}
			STDMETHODIMP SetDouble(REFGUID key, double value) override
			{
				return attrs_->SetDouble(key, value);
			}
			STDMETHODIMP SetGUID(REFGUID key, REFGUID value) override
			{
				return attrs_->SetGUID(key, value);
			}
			STDMETHODIMP SetString(REFGUID key, LPCWSTR value) override
			{
				return attrs_->SetString(key, value);
			}
			STDMETHODIMP SetBlob(REFGUID key, const UINT8* buffer, UINT32 size) override
			{
				return attrs_->SetBlob(key, buffer, size);
			}
			STDMETHODIMP SetUnknown(REFGUID key, IUnknown* value) override
			{
				return attrs_->SetUnknown(key, value);
			}
			STDMETHODIMP LockStore() override
			{
				return attrs_->LockStore();
			}
			STDMETHODIMP UnlockStore() override
			{
				return attrs_->UnlockStore();
			}
			STDMETHODIMP GetCount(UINT32* count) override
			{
				return attrs_->GetCount(count);
			}
			STDMETHODIMP GetItemByIndex(UINT32 index, GUID* key, PROPVARIANT* value) override
			{
				return attrs_->GetItemByIndex(index, key, value);
			}
			STDMETHODIMP CopyAllItems(IMFAttributes* dest) override
			{
				return attrs_->CopyAllItems(dest);
			}

		  private:
			~Activate()
			{
				SafeRelease(source_);
				SafeRelease(attrs_);
				DeleteCriticalSection(&cs_);
				ObjectDestroyed();
			}

			volatile LONG refs_ = 1;
			CRITICAL_SECTION cs_;
			IMFAttributes* attrs_ = nullptr;
			Source* source_ = nullptr;
		};
	} // namespace

	HRESULT CreateSourceActivate(REFIID riid, void** ppv)
	{
		if (!ppv)
			return E_POINTER;
		*ppv = nullptr;
		Activate* activate = new (std::nothrow) Activate();
		if (!activate)
			return LogIfFailed("new Activate", E_OUTOFMEMORY);
		HRESULT hr = activate->Initialize();
		if (SUCCEEDED(hr))
			hr = activate->QueryInterface(riid, ppv);
		activate->Release();
		return hr;
	}
} // namespace probecam
