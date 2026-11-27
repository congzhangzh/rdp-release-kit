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
 * Microsoft's Windows-Camera VirtualCamera sample and the "Frame Server Custom Media
 * Source" rules (written from those documents, no code taken):
 *
 * - the CLSID makes an IMFActivate; its ActivateObject creates the media source
 * - the source is IMFMediaSourceEx (source and stream attribute stores) and IKsControl
 *   (Frame Server sends KS properties; we support none and say so with
 *   ERROR_SET_NOT_FOUND)
 * - one stream, IMFMediaStream2, NV12 640x480 at 30 fps, whose attributes carry
 *   MF_DEVICESTREAM_STREAM_CATEGORY = PINNAME_VIDEO_CAPTURE (PREVIEW is not supported for
 *   custom sources), MF_DEVICESTREAM_STREAM_ID = 0, MF_DEVICESTREAM_FRAMESERVER_SHARED and
 *   MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES = colour
 * - a live source: no MEEndOfStream or MEEndOfPresentation, no pause, timestamps from
 *   MFGetSystemTime, and the caller's token copied onto each sample
 *
 * Frame Server loads this DLL as Local Service in session 0, so it must sit in a folder
 * that account can read. The pictures come from a FrameProducer (frame_producer.h).
 *
 * Locking: each object has one critical section; it is never held while waiting for an
 * event (GetEvent may block), and the source calls into its stream with its own lock held
 * (source lock, then stream lock, never the other way round). */

#include "probe_common.h"

#include <new>

namespace probecam
{
	namespace
	{
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

#define RETURN_IF_FAILED_HR(expr)  \
	do                             \
	{                              \
		const HRESULT hr_ = (expr); \
		if (FAILED(hr_))           \
			return hr_;            \
	} while (0)

		HRESULT CreateVideoType(IMFMediaType** out)
		{
			IMFMediaType* type = nullptr;
			RETURN_IF_FAILED_HR(MFCreateMediaType(&type));
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
			if (FAILED(hr))
			{
				type->Release();
				return hr;
			}
			*out = type;
			return S_OK;
		}

		HRESULT SetCaptureStreamAttributes(IMFAttributes* attrs)
		{
			RETURN_IF_FAILED_HR(attrs->SetGUID(MF_DEVICESTREAM_STREAM_CATEGORY, PINNAME_VIDEO_CAPTURE));
			RETURN_IF_FAILED_HR(attrs->SetUINT32(MF_DEVICESTREAM_STREAM_ID, 0));
			RETURN_IF_FAILED_HR(attrs->SetUINT32(MF_DEVICESTREAM_FRAMESERVER_SHARED, 1));
			RETURN_IF_FAILED_HR(attrs->SetUINT32(MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES,
			                                     MFFrameSourceTypes_Color));
			return S_OK;
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
					return E_OUTOFMEMORY;
				HRESULT hr = MFCreateEventQueue(&stream->queue_);
				if (SUCCEEDED(hr))
					hr = MFCreateAttributes(&stream->attributes_, 4);
				if (SUCCEEDED(hr))
					hr = SetCaptureStreamAttributes(stream->attributes_);
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
					return MF_E_SHUTDOWN;
				return queue_->BeginGetEvent(callback, state);
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
					return MF_E_SHUTDOWN;
				*descriptor = descriptor_;
				descriptor_->AddRef();
				return S_OK;
			}
			STDMETHODIMP RequestSample(IUnknown* token) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				if (state_ != MF_STREAM_STATE_RUNNING)
					return MF_E_MEDIA_SOURCE_WRONGSTATE;

				IMFMediaBuffer* buffer = nullptr;
				IMFSample* sample = nullptr;
				HRESULT hr = MFCreateMemoryBuffer(kFrameBytes, &buffer);
				if (SUCCEEDED(hr))
				{
					BYTE* data = nullptr;
					DWORD capacity = 0;
					hr = buffer->Lock(&data, &capacity, nullptr);
					if (SUCCEEDED(hr))
					{
						const bool ok = (capacity >= kFrameBytes) &&
						                producer_->FillNV12(data, static_cast<LONG>(kWidth),
						                                    kWidth, kHeight);
						buffer->Unlock();
						if (!ok)
							hr = MF_E_UNEXPECTED;
					}
				}
				if (SUCCEEDED(hr))
					hr = buffer->SetCurrentLength(kFrameBytes);
				if (SUCCEEDED(hr))
					hr = MFCreateSample(&sample);
				if (SUCCEEDED(hr))
					hr = sample->AddBuffer(buffer);
				if (SUCCEEDED(hr))
					hr = sample->SetSampleTime(MFGetSystemTime());
				if (SUCCEEDED(hr))
					hr = sample->SetSampleDuration(10000000LL * kFpsDenominator / kFpsNumerator);
				if (SUCCEEDED(hr) && token)
					hr = sample->SetUnknown(MFSampleExtension_Token, token);
				if (SUCCEEDED(hr))
					hr = queue_->QueueEventParamUnk(MEMediaSample, GUID_NULL, S_OK, sample);
				SafeRelease(sample);
				SafeRelease(buffer);
				return hr;
			}

			/* IMFMediaStream2: Frame Server sets the state of each stream itself */
			STDMETHODIMP SetStreamState(MF_STREAM_STATE value) override
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				switch (value)
				{
					case MF_STREAM_STATE_STOPPED:
					case MF_STREAM_STATE_PAUSED:
					case MF_STREAM_STATE_RUNNING:
						state_ = value;
						return S_OK;
					default:
						return E_INVALIDARG;
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
					return MF_E_SHUTDOWN;
				state_ = MF_STREAM_STATE_RUNNING;
				return queue_->QueueEventParamVar(MEStreamStarted, GUID_NULL, S_OK, nullptr);
			}
			HRESULT Stop()
			{
				AutoLock lock(&cs_);
				if (!queue_)
					return MF_E_SHUTDOWN;
				state_ = MF_STREAM_STATE_STOPPED;
				return queue_->QueueEventParamVar(MEStreamStopped, GUID_NULL, S_OK, nullptr);
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
					return MF_E_SHUTDOWN;
				*out = attributes_;
				attributes_->AddRef();
				return S_OK;
			}

		  private:
			Stream(Source* source, IMFStreamDescriptor* descriptor, FrameProducer* producer);
			~Stream()
			{
				Shutdown();
				SafeRelease(descriptor_);
				DeleteCriticalSection(&cs_);
				ObjectDestroyed();
			}

			volatile LONG refs_ = 1;
			CRITICAL_SECTION cs_;
			IMFMediaSourceEx* source_ = nullptr; /* strong, until Shutdown */
			IMFStreamDescriptor* descriptor_ = nullptr;
			IMFMediaEventQueue* queue_ = nullptr;
			IMFAttributes* attributes_ = nullptr;
			FrameProducer* producer_ = nullptr; /* owned by the source */
			MF_STREAM_STATE state_ = MF_STREAM_STATE_STOPPED;
		};

		/* ---------------------------------------------------------------- the source */

		class Source final : public IMFMediaSourceEx, public IKsControl
		{
		  public:
			static HRESULT Create(IMFAttributes* activateAttributes, Source** out)
			{
				Source* source = new (std::nothrow) Source();
				if (!source)
					return E_OUTOFMEMORY;
				const HRESULT hr = source->Initialize(activateAttributes);
				if (FAILED(hr))
				{
					source->Shutdown();
					source->Release();
					return hr;
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
				else if (riid == IID_IKsControl)
					*ppv = static_cast<IKsControl*>(this);
				else
				{
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
					return MF_E_SHUTDOWN;
				return queue_->BeginGetEvent(callback, state);
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
				if (shutdown_)
					return MF_E_SHUTDOWN;
				*characteristics = MFMEDIASOURCE_IS_LIVE;
				return S_OK;
			}
			STDMETHODIMP CreatePresentationDescriptor(IMFPresentationDescriptor** out) override
			{
				if (!out)
					return E_POINTER;
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				return presentation_->Clone(out);
			}
			STDMETHODIMP Start(IMFPresentationDescriptor* presentation, const GUID* timeFormat,
			                   const PROPVARIANT* startPosition) override
			{
				if (!presentation)
					return E_INVALIDARG;
				if (timeFormat && (*timeFormat != GUID_NULL))
					return MF_E_UNSUPPORTED_TIME_FORMAT;

				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;

				DWORD count = 0;
				RETURN_IF_FAILED_HR(presentation->GetStreamDescriptorCount(&count));
				if (count != 1)
					return E_INVALIDARG;
				BOOL selected = FALSE;
				IMFStreamDescriptor* descriptor = nullptr;
				RETURN_IF_FAILED_HR(
				    presentation->GetStreamDescriptorByIndex(0, &selected, &descriptor));
				DWORD id = 0;
				const HRESULT idHr = descriptor->GetStreamIdentifier(&id);
				descriptor->Release();
				RETURN_IF_FAILED_HR(idHr);
				if (id != 0)
					return E_INVALIDARG;

				if (selected)
				{
					/* MENewStream the first time, MEUpdatedStream on a restart */
					RETURN_IF_FAILED_HR(queue_->QueueEventParamUnk(
					    announced_ ? MEUpdatedStream : MENewStream, GUID_NULL, S_OK,
					    static_cast<IMFMediaStream*>(stream_)));
					announced_ = true;
					RETURN_IF_FAILED_HR(stream_->Start());
				}

				PROPVARIANT empty;
				PropVariantInit(&empty);
				return queue_->QueueEventParamVar(MESourceStarted, GUID_NULL, S_OK,
				                                  startPosition ? startPosition : &empty);
			}
			STDMETHODIMP Stop() override
			{
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				RETURN_IF_FAILED_HR(stream_->Stop());
				return queue_->QueueEventParamVar(MESourceStopped, GUID_NULL, S_OK, nullptr);
			}
			STDMETHODIMP Pause() override
			{
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				return MF_E_INVALID_STATE_TRANSITION; /* a live camera does not pause */
			}
			STDMETHODIMP Shutdown() override
			{
				Stream* stream = nullptr;
				{
					AutoLock lock(&cs_);
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
				if (shutdown_)
					return MF_E_SHUTDOWN;
				*out = attributes_;
				attributes_->AddRef();
				return S_OK;
			}
			STDMETHODIMP GetStreamAttributes(DWORD streamId, IMFAttributes** out) override
			{
				if (!out)
					return E_POINTER;
				AutoLock lock(&cs_);
				if (shutdown_)
					return MF_E_SHUTDOWN;
				if (streamId != 0)
					return MF_E_INVALIDSTREAMNUMBER;
				return stream_->GetAttributes(out);
			}
			STDMETHODIMP SetD3DManager(IUnknown*) override
			{
				/* system-memory samples only */
				AutoLock lock(&cs_);
				return shutdown_ ? MF_E_SHUTDOWN : S_OK;
			}

			/* IKsControl: no camera controls */
			STDMETHODIMP KsProperty(PKSPROPERTY, ULONG, LPVOID, ULONG, ULONG*) override
			{
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}
			STDMETHODIMP KsMethod(PKSMETHOD, ULONG, LPVOID, ULONG, ULONG*) override
			{
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}
			STDMETHODIMP KsEvent(PKSEVENT, ULONG, LPVOID, ULONG, ULONG*) override
			{
				return HRESULT_FROM_WIN32(ERROR_SET_NOT_FOUND);
			}

		  private:
			Source()
			{
				InitializeCriticalSection(&cs_);
				ObjectCreated();
			}
			~Source()
			{
				if (!shutdown_)
					Shutdown();
				SafeRelease(queue_);
				SafeRelease(presentation_);
				SafeRelease(attributes_);
				delete producer_;
				DeleteCriticalSection(&cs_);
				ObjectDestroyed();
			}

			HRESULT Initialize(IMFAttributes* activateAttributes)
			{
				producer_ = CreatePatternProducer();
				if (!producer_)
					return E_OUTOFMEMORY;
				RETURN_IF_FAILED_HR(MFCreateEventQueue(&queue_));
				RETURN_IF_FAILED_HR(MFCreateAttributes(&attributes_, 8));
				/* what Frame Server put on the activate (e.g. the symbolic link) */
				if (activateAttributes)
					RETURN_IF_FAILED_HR(activateAttributes->CopyAllItems(attributes_));

				IMFMediaType* type = nullptr;
				RETURN_IF_FAILED_HR(CreateVideoType(&type));
				IMFStreamDescriptor* descriptor = nullptr;
				HRESULT hr = MFCreateStreamDescriptor(0, 1, &type, &descriptor);
				IMFMediaTypeHandler* handler = nullptr;
				if (SUCCEEDED(hr))
					hr = descriptor->GetMediaTypeHandler(&handler);
				if (SUCCEEDED(hr))
					hr = handler->SetCurrentMediaType(type);
				if (SUCCEEDED(hr))
					hr = SetCaptureStreamAttributes(descriptor);
				if (SUCCEEDED(hr))
					hr = MFCreatePresentationDescriptor(1, &descriptor, &presentation_);
				if (SUCCEEDED(hr))
					hr = presentation_->SelectStream(0);
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
				return MF_E_SHUTDOWN;
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
				return MFCreateAttributes(&attrs_, 4);
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

			/* IMFActivate */
			STDMETHODIMP ActivateObject(REFIID riid, void** ppv) override
			{
				if (!ppv)
					return E_POINTER;
				AutoLock lock(&cs_);
				if (!source_)
					RETURN_IF_FAILED_HR(Source::Create(attrs_, &source_));
				return source_->QueryInterface(riid, ppv);
			}
			STDMETHODIMP ShutdownObject() override
			{
				AutoLock lock(&cs_);
				if (source_)
				{
					(void)source_->Shutdown();
					SafeRelease(source_);
				}
				return S_OK;
			}
			STDMETHODIMP DetachObject() override
			{
				AutoLock lock(&cs_);
				SafeRelease(source_);
				return S_OK;
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
				if (source_)
				{
					(void)source_->Shutdown();
					SafeRelease(source_);
				}
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
			return E_OUTOFMEMORY;
		HRESULT hr = activate->Initialize();
		if (SUCCEEDED(hr))
			hr = activate->QueryInterface(riid, ppv);
		activate->Release();
		return hr;
	}
} // namespace probecam
