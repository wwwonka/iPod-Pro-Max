#include "CWinDevices.h"

#if defined(_WIN32)
#include <windows.h>
#include <cfgmgr32.h>
#include <winioctl.h>
#include <initguid.h>
#include <devpkey.h>
#include <wchar.h>
#include <stdlib.h>

static const GUID IPM_GUID_DEVINTERFACE_DISK = {0x53F56307, 0xB6BF, 0x11D0, {0x94, 0xF2, 0x00, 0xA0, 0xC9, 0x1E, 0xFB, 0x8B}};
static const GUID IPM_GUID_DEVINTERFACE_VOLUME = {0x53F5630D, 0xB6BF, 0x11D0, {0x94, 0xF2, 0x00, 0xA0, 0xC9, 0x1E, 0xFB, 0x8B}};

static int device_number(const wchar_t *path, STORAGE_DEVICE_NUMBER *out) {
    HANDLE h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD returned = 0;
    BOOL ok = DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, NULL, 0, out, sizeof(*out), &returned, NULL);
    CloseHandle(h);
    return ok ? 1 : 0;
}

/// The disk device node behind a drive letter: its disk number matched against every present disk.
static int disk_devnode(uint16_t drive, DEVINST *node) {
    wchar_t volumePath[] = L"\\\\.\\X:";
    volumePath[4] = (wchar_t)drive;
    STORAGE_DEVICE_NUMBER number;
    if (!device_number(volumePath, &number)) return 0;

    ULONG length = 0;
    if (CM_Get_Device_Interface_List_SizeW(&length, (LPGUID)&IPM_GUID_DEVINTERFACE_DISK, NULL, CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS || length <= 1) return 0;
    wchar_t *list = calloc(length, sizeof(wchar_t));
    if (!list) return 0;
    int found = 0;
    if (CM_Get_Device_Interface_ListW((LPGUID)&IPM_GUID_DEVINTERFACE_DISK, NULL, list, length, CM_GET_DEVICE_INTERFACE_LIST_PRESENT) == CR_SUCCESS) {
        for (wchar_t *p = list; *p && !found; p += wcslen(p) + 1) {
            STORAGE_DEVICE_NUMBER n;
            if (!device_number(p, &n) || n.DeviceType != number.DeviceType || n.DeviceNumber != number.DeviceNumber) continue;
            wchar_t instance[512];
            ULONG size = sizeof(instance);
            DEVPROPTYPE type = 0;
            if (CM_Get_Device_Interface_PropertyW(p, &DEVPKEY_Device_InstanceId, &type, (PBYTE)instance, &size, 0) != CR_SUCCESS) continue;
            if (CM_Locate_DevNodeW(node, instance, CM_LOCATE_DEVNODE_NORMAL) == CR_SUCCESS) found = 1;
        }
    }
    free(list);
    return found;
}

static int hex_field(const wchar_t *id, const wchar_t *key, uint32_t *out) {
    const wchar_t *at = wcsstr(id, key);
    if (!at) return 0;
    *out = (uint32_t)wcstoul(at + wcslen(key), NULL, 16);
    return 1;
}

int ipm_usb_identity(uint16_t drive, uint32_t *vendor, uint32_t *product, uint16_t *serial, size_t serialCapacity) {
    DEVINST node;
    if (serialCapacity > 0) serial[0] = 0;
    if (!disk_devnode(drive, &node)) return 0;
    // The disk's ancestors: USBSTOR\DISK&VEN_APPLE&PROD_IPOD...\<serial>&0, then USB\VID_05AC&PID_1261\<serial>.
    for (int depth = 0; depth < 8; depth++) {
        wchar_t id[512];
        if (CM_Get_Device_IDW(node, id, 512, 0) == CR_SUCCESS && _wcsnicmp(id, L"USB\\VID_", 8) == 0) {
            if (!hex_field(id, L"VID_", vendor) || !hex_field(id, L"PID_", product)) return 0;
            const wchar_t *last = wcsrchr(id, L'\\');
            // Windows makes up an instance id containing '&' when the device has no serial number.
            if (last && !wcschr(last + 1, L'&') && serialCapacity > 0) {
                size_t i = 0;
                for (const wchar_t *c = last + 1; *c && i + 1 < serialCapacity; c++) serial[i++] = (uint16_t)*c;
                serial[i] = 0;
            }
            return 1;
        }
        DEVINST parent;
        if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) return 0;
        node = parent;
    }
    return 0;
}

int ipm_eject(uint16_t drive, uint16_t *veto, size_t vetoCapacity) {
    DEVINST node;
    if (vetoCapacity > 0) veto[0] = 0;
    if (!disk_devnode(drive, &node)) return 0;
    // The disk first, then its parent (the USB mass storage device) if the disk refuses.
    for (int attempt = 0; attempt < 2; attempt++) {
        PNP_VETO_TYPE vetoType = PNP_VetoTypeUnknown;
        wchar_t name[MAX_PATH] = {0};
        CONFIGRET result = CM_Request_Device_EjectW(node, &vetoType, name, MAX_PATH, 0);
        if (result == CR_SUCCESS && vetoType == PNP_VetoTypeUnknown) return 1;
        size_t i = 0;
        for (const wchar_t *c = name; *c && i + 1 < vetoCapacity; c++) veto[i++] = (uint16_t)*c;
        if (vetoCapacity > 0) veto[i] = 0;
        DEVINST parent;
        if (CM_Get_Parent(&parent, node, 0) != CR_SUCCESS) return 0;
        node = parent;
    }
    return 0;
}

typedef struct {
    HCMNOTIFICATION notification;
    void (*callback)(void *);
    void *context;
} ipm_watch;

static DWORD CALLBACK on_notify(HCMNOTIFICATION h, PVOID context, CM_NOTIFY_ACTION action, PCM_NOTIFY_EVENT_DATA data, DWORD size) {
    (void)h; (void)data; (void)size;
    ipm_watch *w = (ipm_watch *)context;
    if (action == CM_NOTIFY_ACTION_DEVICEINTERFACEARRIVAL || action == CM_NOTIFY_ACTION_DEVICEINTERFACEREMOVAL) {
        w->callback(w->context);
    }
    return ERROR_SUCCESS;
}

void *ipm_watch_start(void (*callback)(void *context), void *context) {
    ipm_watch *w = calloc(1, sizeof(ipm_watch));
    if (!w) return NULL;
    w->callback = callback;
    w->context = context;
    CM_NOTIFY_FILTER filter;
    ZeroMemory(&filter, sizeof(filter));
    filter.cbSize = sizeof(filter);
    filter.FilterType = CM_NOTIFY_FILTER_TYPE_DEVICEINTERFACE;
    filter.u.DeviceInterface.ClassGuid = IPM_GUID_DEVINTERFACE_VOLUME;
    if (CM_Register_Notification(&filter, w, on_notify, &w->notification) != CR_SUCCESS) {
        free(w);
        return NULL;
    }
    return w;
}

void ipm_watch_stop(void *handle) {
    ipm_watch *w = (ipm_watch *)handle;
    if (!w) return;
    CM_Unregister_Notification(w->notification);
    free(w);
}
#endif
