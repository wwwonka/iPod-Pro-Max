import Foundation
import PluginKit

await PluginMain.run(roles: [SpotifySource()], pluginID: "spotify", version: "1.0.0")
