import Foundation
import PluginKit

await PluginMain.run(roles: [YouTubeMusicSource()], pluginID: "youtube-music", version: "1.0.0")
