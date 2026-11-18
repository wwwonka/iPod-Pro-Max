# Soulseek Plug-in

ID: `soulseek`
Roles: `resolver`, `downloader`, `share`

Native Swift client for the Soulseek P2P network backed by portable `CSockets` (`poll` / `WSAPoll`) and `CZlib` (miniz). Protocol layout adapted from [seeleseek](https://github.com/bretth18/seeleseek) (MIT License).

## Verification

```sh
swift build --product SoulseekPlugin
mkdir -p Plug-ins/Soulseek/bin/macos
cp .build/debug/SoulseekPlugin Plug-ins/Soulseek/bin/macos/soulseek-plugin
swift run ipodpromax plugin test Plug-ins/Soulseek --offline
```
