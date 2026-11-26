/* devnode: create a root-enumerated device and install its driver, what
 * "devcon install <inf> <hwid>" does (probe-iddcx.yml: pnputil /add-device refuses
 * Root\MttVDD on Windows 11 26100, and devcon is not on the runner images).
 *
 *   devnode.exe <full path to the .inf> <hardware id> <class name>
 *
 * Exit code 0 when the device was created and its driver installed.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <stdio.h>
#include <wchar.h>

int wmain(int argc, wchar_t** argv)
{
	if (argc != 4)
	{
		fwprintf(stderr, L"usage: devnode <inf> <hardware id> <class name>\n");
		return 2;
	}
	const wchar_t* inf = argv[1];
	const wchar_t* hwid = argv[2];
	const wchar_t* className = argv[3];

	GUID classGuid;
	DWORD needed = 0;
	if (!SetupDiClassGuidsFromNameW(className, &classGuid, 1, &needed) || (needed == 0))
	{
		fwprintf(stderr, L"SetupDiClassGuidsFromName(%ls): %lu\n", className, GetLastError());
		return 1;
	}

	HDEVINFO set = SetupDiCreateDeviceInfoList(&classGuid, NULL);
	if (set == INVALID_HANDLE_VALUE)
	{
		fwprintf(stderr, L"SetupDiCreateDeviceInfoList: %lu\n", GetLastError());
		return 1;
	}

	int rc = 1;
	SP_DEVINFO_DATA info = { 0 };
	info.cbSize = sizeof(info);
	if (!SetupDiCreateDeviceInfoW(set, className, &classGuid, NULL, NULL, DICD_GENERATE_ID,
	                              &info))
	{
		fwprintf(stderr, L"SetupDiCreateDeviceInfo: %lu\n", GetLastError());
		goto out;
	}

	/* REG_MULTI_SZ: the id, then an empty string */
	wchar_t ids[256] = { 0 };
	const size_t len = wcslen(hwid);
	if (len + 2 > ARRAYSIZE(ids))
		goto out;
	wmemcpy(ids, hwid, len);
	if (!SetupDiSetDeviceRegistryPropertyW(set, &info, SPDRP_HARDWAREID, (const BYTE*)ids,
	                                       (DWORD)((len + 2) * sizeof(wchar_t))))
	{
		fwprintf(stderr, L"SetupDiSetDeviceRegistryProperty: %lu\n", GetLastError());
		goto out;
	}
	if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &info))
	{
		fwprintf(stderr, L"SetupDiCallClassInstaller(DIF_REGISTERDEVICE): %lu\n",
		         GetLastError());
		goto out;
	}
	wprintf(L"device node created for %ls\n", hwid);

	BOOL reboot = FALSE;
	if (!UpdateDriverForPlugAndPlayDevicesW(NULL, hwid, inf, INSTALLFLAG_FORCE, &reboot))
	{
		fwprintf(stderr, L"UpdateDriverForPlugAndPlayDevices: %lu (0x%08lX)\n", GetLastError(),
		         GetLastError());
		goto out;
	}
	wprintf(L"driver installed, reboot %ls\n", reboot ? L"needed" : L"not needed");
	rc = 0;

out:
	SetupDiDestroyDeviceInfoList(set);
	return rc;
}
