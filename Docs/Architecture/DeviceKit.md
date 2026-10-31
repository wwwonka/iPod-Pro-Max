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

## Mise en œuvre (2026-10-30)
API commune (`Sources/DeviceKit/DeviceKit.swift`) : `DeviceScanner.scan()` et `device(at:)`, `USBIdentification.identify(volume:)`, `VolumeWatcher` (rappel ou `AsyncStream`), `Ejector.eject(_:)`. Les protocoles imaginés plus haut sont devenus ces types concrets, avec un fichier par OS :

| | macOS | Linux | Windows |
|---|---|---|---|
| Volumes candidats | `mountedVolumeURLs`, disques locaux éjectables | `/proc/self/mountinfo`, systèmes de fichiers vfat, hfsplus, exfat sur `/dev/…` | lettres de lecteur amovibles ou fixes, hors lecteur système |
| Événements | DiskArbitration (chemin et nom de volume, disparition) | `poll()` bloquant sur `/proc/self/mountinfo` (POLLPRI), dans un thread | `CM_Register_Notification` sur les interfaces de volume, regroupés sur une seconde le temps que la lettre soit attribuée |
| USB → volume | IORegistry (code existant) | `/sys/dev/block/<maj:min>` puis remontée jusqu'à `idVendor` / `idProduct` / `serial` | disque (`IOCTL_STORAGE_GET_DEVICE_NUMBER`) puis parents Plug and Play jusqu'à `USB\VID_…&PID_…\<série>` |
| Éjection | `DADiskUnmount` (disque entier) puis `DADiskEject` | `udisksctl unmount` puis `power-off` ; sinon `umount` + `eject` | `CM_Request_Device_EjectW` sur le disque, puis son parent |

Sous Windows, les appels cfgmgr32 sont dans la cible C `CWinDevices` (voir [[ADR-006 Noyau portable sans dépendance Apple]]).

Le **FireWire GUID** est maintenant repris du numéro de série USB quand SysInfo n'en donne pas et que la série fait 16 chiffres hexadécimaux (`USBDeviceIdentity.firewireGUIDFromSerial`).

**Pas encore testé avec un vrai iPod hors Mac** : dans les VM, la détection d'iPods simulés, la compilation et l'absence d'erreur sans iPod ont été vérifiées, pas la lecture du numéro de série ni l'éjection. C'est le prochain test réel (passage USB de l'iPod à la VM).

**Événements vérifiés sur les 3 OS (2026-10-30)**, avec le prototype SwiftCrossUI qui affiche maintenant ses iPods par DeviceKit : un faux iPod (disque FAT32 avec `iPod_Control/Device/SysInfo`) apparaît dans la sidebar au montage et disparaît au démontage, sans relancer l'app. Disque : image `hdiutil` sur macOS, périphérique loop monté avec l'uid de l'utilisateur sous Fedora (monté par root sans `uid=`, le volume est illisible pour l'app et donc ignoré), VHD attaché et détaché par `diskpart` sous Windows.
