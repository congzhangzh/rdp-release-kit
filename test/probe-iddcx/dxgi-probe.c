/* dxgi-probe: what DXGI desktop duplication sees of each monitor (probe-iddcx.yml).
 *
 * For every output of every adapter: its name and desktop rectangle, then a white
 * window over that rectangle, then up to 3 s of AcquireNextFrame on a duplication of
 * that output. The newest frame is written as <dir>\output-<a>-<o>.bmp and counted:
 * white pixels (all channels >= 0xF0) and black pixels (all channels <= 0x10).
 * One line per output on stdout, "key=value" pairs; a failing step is named, never
 * hidden. Exit code 0 when it ran to the end, whatever the pictures show.
 *
 *   dxgi-probe.exe <output dir>
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <string.h>

static LRESULT CALLBACK white_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
	if (msg == WM_PAINT)
	{
		PAINTSTRUCT ps;
		HDC dc = BeginPaint(hwnd, &ps);
		FillRect(dc, &ps.rcPaint, (HBRUSH)GetStockObject(WHITE_BRUSH));
		EndPaint(hwnd, &ps);
		return 0;
	}
	return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump(DWORD ms)
{
	const DWORD end = GetTickCount() + ms;
	while ((LONG)(end - GetTickCount()) > 0)
	{
		MSG msg;
		while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
		{
			TranslateMessage(&msg);
			DispatchMessageW(&msg);
		}
		Sleep(10);
	}
}

static BOOL write_bmp(const char* path, const BYTE* data, UINT pitch, UINT w, UINT h)
{
	FILE* f = fopen(path, "wb");
	if (!f)
		return FALSE;
	BITMAPFILEHEADER fh = { 0 };
	BITMAPINFOHEADER ih = { 0 };
	const DWORD size = w * h * 4;
	fh.bfType = 0x4D42;
	fh.bfOffBits = sizeof(fh) + sizeof(ih);
	fh.bfSize = fh.bfOffBits + size;
	ih.biSize = sizeof(ih);
	ih.biWidth = (LONG)w;
	ih.biHeight = -(LONG)h; /* top-down */
	ih.biPlanes = 1;
	ih.biBitCount = 32;
	ih.biCompression = BI_RGB;
	ih.biSizeImage = size;
	BOOL ok = fwrite(&fh, sizeof(fh), 1, f) == 1 && fwrite(&ih, sizeof(ih), 1, f) == 1;
	for (UINT y = 0; ok && (y < h); y++)
		ok = fwrite(data + (size_t)y * pitch, 4, w, f) == w;
	fclose(f);
	return ok;
}

/* duplicate one output; prints the rest of its line */
static void probe_output(IDXGIAdapter1* adapter, IDXGIOutput* output, const char* dir, UINT a,
                         UINT o)
{
	HRESULT hr;
	ID3D11Device* device = NULL;
	ID3D11DeviceContext* ctx = NULL;
	IDXGIOutput1* output1 = NULL;
	IDXGIOutputDuplication* dup = NULL;
	ID3D11Texture2D* staging = NULL;
	D3D_FEATURE_LEVEL level = 0;

	hr = D3D11CreateDevice((IDXGIAdapter*)adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL,
	                       D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0, D3D11_SDK_VERSION, &device,
	                       &level, &ctx);
	if (FAILED(hr))
	{
		printf(" step=D3D11CreateDevice hr=0x%08lX\n", (unsigned long)hr);
		return;
	}
	printf(" level=0x%04X", (unsigned)level);
	hr = IDXGIOutput_QueryInterface(output, &IID_IDXGIOutput1, (void**)&output1);
	if (FAILED(hr))
	{
		printf(" step=IDXGIOutput1 hr=0x%08lX\n", (unsigned long)hr);
		goto out;
	}
	hr = IDXGIOutput1_DuplicateOutput(output1, (IUnknown*)device, &dup);
	if (FAILED(hr))
	{
		printf(" step=DuplicateOutput hr=0x%08lX\n", (unsigned long)hr);
		goto out;
	}

	UINT acquired = 0;
	UINT timeouts = 0;
	HRESULT lastHr = S_OK;
	BOOL have = FALSE;
	const DWORD end = GetTickCount() + 3000;
	while ((LONG)(end - GetTickCount()) > 0)
	{
		DXGI_OUTDUPL_FRAME_INFO info;
		IDXGIResource* res = NULL;
		hr = IDXGIOutputDuplication_AcquireNextFrame(dup, 200, &info, &res);
		if (hr == DXGI_ERROR_WAIT_TIMEOUT)
		{
			timeouts++;
			if (have && (timeouts > 3))
				break;
			continue;
		}
		if (FAILED(hr))
		{
			lastHr = hr;
			break;
		}
		acquired++;
		ID3D11Texture2D* tex = NULL;
		if (SUCCEEDED(IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void**)&tex)))
		{
			D3D11_TEXTURE2D_DESC desc;
			ID3D11Texture2D_GetDesc(tex, &desc);
			if (!staging)
			{
				desc.Usage = D3D11_USAGE_STAGING;
				desc.BindFlags = 0;
				desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
				desc.MiscFlags = 0;
				desc.MipLevels = 1;
				desc.ArraySize = 1;
				desc.SampleDesc.Count = 1;
				hr = ID3D11Device_CreateTexture2D(device, &desc, NULL, &staging);
			}
			if (staging)
			{
				ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource*)staging,
				                                 (ID3D11Resource*)tex);
				have = TRUE;
			}
			ID3D11Texture2D_Release(tex);
		}
		IDXGIResource_Release(res);
		IDXGIOutputDuplication_ReleaseFrame(dup);
	}
	printf(" acquired=%u timeouts=%u", acquired, timeouts);
	if (FAILED(lastHr))
		printf(" acquire_hr=0x%08lX", (unsigned long)lastHr);
	if (!have)
	{
		printf(" step=no_frame\n");
		goto out;
	}

	D3D11_TEXTURE2D_DESC desc;
	ID3D11Texture2D_GetDesc(staging, &desc);
	D3D11_MAPPED_SUBRESOURCE map;
	hr = ID3D11DeviceContext_Map(ctx, (ID3D11Resource*)staging, 0, D3D11_MAP_READ, 0, &map);
	if (FAILED(hr))
	{
		printf(" step=Map hr=0x%08lX\n", (unsigned long)hr);
		goto out;
	}
	unsigned long long white = 0;
	unsigned long long black = 0;
	for (UINT y = 0; y < desc.Height; y++)
	{
		const BYTE* row = (const BYTE*)map.pData + (size_t)y * map.RowPitch;
		for (UINT x = 0; x < desc.Width; x++)
		{
			const BYTE* p = row + 4 * x;
			if ((p[0] >= 0xF0) && (p[1] >= 0xF0) && (p[2] >= 0xF0))
				white++;
			else if ((p[0] <= 0x10) && (p[1] <= 0x10) && (p[2] <= 0x10))
				black++;
		}
	}
	char path[MAX_PATH];
	(void)_snprintf(path, sizeof(path), "%s\\output-%u-%u.bmp", dir, a, o);
	const BOOL saved = write_bmp(path, map.pData, map.RowPitch, desc.Width, desc.Height);
	ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource*)staging, 0);
	printf(" frame=%ux%u format=%u pixels=%llu white=%llu black=%llu bmp=%s\n", desc.Width,
	       desc.Height, (unsigned)desc.Format, (unsigned long long)desc.Width * desc.Height,
	       white, black, saved ? path : "write-failed");

out:
	if (staging)
		ID3D11Texture2D_Release(staging);
	if (dup)
		IDXGIOutputDuplication_Release(dup);
	if (output1)
		IDXGIOutput1_Release(output1);
	if (ctx)
		ID3D11DeviceContext_Release(ctx);
	if (device)
		ID3D11Device_Release(device);
}

int main(int argc, char** argv)
{
	const char* dir = (argc > 1) ? argv[1] : ".";
	IDXGIFactory1* factory = NULL;

	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
	setvbuf(stdout, NULL, _IONBF, 0);

	WNDCLASSW wc = { 0 };
	wc.lpfnWndProc = white_proc;
	wc.hInstance = GetModuleHandleW(NULL);
	wc.lpszClassName = L"dxgi-probe-white";
	wc.hCursor = LoadCursor(NULL, IDC_ARROW);
	RegisterClassW(&wc);

	printf("monitors SM_CMONITORS=%d virtual=%d,%d %dx%d\n", GetSystemMetrics(SM_CMONITORS),
	       GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
	       GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));

	HRESULT hr = CreateDXGIFactory1(&IID_IDXGIFactory1, (void**)&factory);
	if (FAILED(hr))
	{
		printf("step=CreateDXGIFactory1 hr=0x%08lX\n", (unsigned long)hr);
		return 0;
	}
	IDXGIAdapter1* adapter = NULL;
	for (UINT a = 0; IDXGIFactory1_EnumAdapters1(factory, a, &adapter) != DXGI_ERROR_NOT_FOUND;
	     a++)
	{
		DXGI_ADAPTER_DESC1 ad;
		IDXGIAdapter1_GetDesc1(adapter, &ad);
		printf("adapter=%u name=\"%ls\" vendor=0x%04X device=0x%04X flags=0x%X vram=%llu\n", a,
		       ad.Description, ad.VendorId, ad.DeviceId, ad.Flags,
		       (unsigned long long)ad.DedicatedVideoMemory);
		IDXGIOutput* output = NULL;
		for (UINT o = 0; IDXGIAdapter1_EnumOutputs(adapter, o, &output) != DXGI_ERROR_NOT_FOUND;
		     o++)
		{
			DXGI_OUTPUT_DESC od;
			IDXGIOutput_GetDesc(output, &od);
			const RECT r = od.DesktopCoordinates;
			printf("output=%u.%u device=\"%ls\" attached=%d rect=%ld,%ld,%ld,%ld", a, o,
			       od.DeviceName, od.AttachedToDesktop, r.left, r.top, r.right, r.bottom);
			HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, wc.lpszClassName,
			                            L"dxgi-probe", WS_POPUP, r.left, r.top,
			                            r.right - r.left, r.bottom - r.top, NULL, NULL,
			                            wc.hInstance, NULL);
			if (hwnd)
			{
				ShowWindow(hwnd, SW_SHOWNOACTIVATE);
				UpdateWindow(hwnd);
				pump(700);
			}
			else
				printf(" window_error=%lu", GetLastError());
			probe_output(adapter, output, dir, a, o);
			if (hwnd)
			{
				DestroyWindow(hwnd);
				pump(200);
			}
			IDXGIOutput_Release(output);
		}
		IDXGIAdapter1_Release(adapter);
	}
	IDXGIFactory1_Release(factory);
	printf("done\n");
	return 0;
}
