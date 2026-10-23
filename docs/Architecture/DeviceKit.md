# DeviceKit

Détecte les iPod montés, les identifie, et sait les éjecter. **Tout se fait par événements**, jamais par polling (voir [[Vision]]).

```swift
protocol DeviceWatcher { var events: AsyncStream<DeviceEvent> { get } }   // monté / démonté
protocol USBInfoProvider { func usbInfo(forVolume: URL) -> USBInfo? }      // PID, numéro de série
protocol Ejector { func eject(_ volume: URL) async throws }
```

| | macOS | Linux | Windows |
|---|---|---|---|
| Événements | Notifications de montage NSWorkspace / DiskArbitration (actuel) | `udev` monitor (netlink) + `/proc/self/mountinfo` | `WM_DEVICECHANGE` (fenêtre cachée) |
| USB → volume | IOKit (`USBIdentification` actuel) | sysfs (`/sys/block/sdX/../serial`) | SetupAPI + `IOCTL_STORAGE_GET_DEVICE_NUMBER` |
| Éjection | DiskArbitration | udisks2 via D-Bus | `CM_Request_Device_Eject` |

## Le chemin critique : FireWire GUID → hash58
Sans FireWire GUID, un iPod classic ou nano 3G/4G est `.unsupported` (`Device/IPodDevice.swift:61`), parce que le DB signé hash58 en a besoin.
- Il vient de `SysInfoExtended` si le fichier existe. Sinon, c'est le **numéro de série USB**, qui est le GUID sur ces modèles.
- Chaque implémentation de `USBInfoProvider` doit donc le fournir. **C'est le premier test réel sur Windows et Linux** (phase 4 dans [[Phases]]).
- Si nécessaire, on lit `SysInfoExtended` via SCSI INQUIRY (pages vendeur, comme libgpod) et on l'écrit sur l'iPod pour les fois suivantes.

## Ce qui ne change pas
`IPodDevice.load` (lecture de SysInfo et SysInfoExtended) et `IPodModelTable` sont du Foundation pur et vont dans iPodKit tels quels. Voir [[Modules]].
