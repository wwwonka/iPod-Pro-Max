import Foundation
import PluginKit

await PluginMain.run(roles: [YtDlpHandler()], pluginID: "yt-dlp", version: "1.0.0")
