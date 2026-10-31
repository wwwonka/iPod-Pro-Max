import Foundation

/// A compact device-page snapshot. Read once per connection, never from a view render.
public struct DeviceContentsSummary: Sendable {
    public var songs = 0
    public var podcasts = 0
    public var videos = 0
    public var audiobooks = 0
    public var musicBytes: Int64 = 0
    public var podcastBytes: Int64 = 0
    public var videoBytes: Int64 = 0
    public var audiobookBytes: Int64 = 0
    public var photoBytes: Int64 = 0
    public var photos = 0
    public var name = ""
    public var readError: String?
    public var stats = IPodDevice.VolumeStats(total: 0, free: 0)
    public init() {}

    public static func read(from dev: IPodDevice) -> DeviceContentsSummary {
        var c = DeviceContentsSummary()
        c.stats = dev.volumeStats()
        do {
            let db = try dev.readDatabase()
            c.name = db.name
            for t in db.tracks {
                if t.isPodcast { c.podcasts += 1; c.podcastBytes += Int64(t.fileSize) }
                else if t.mediaType & IPodMediaType.movie != 0 || t.mediaType & IPodMediaType.musicVideo != 0 || t.mediaType & IPodMediaType.tvShow != 0 { c.videos += 1; c.videoBytes += Int64(t.fileSize) }
                else if t.mediaType & IPodMediaType.audiobook != 0 { c.audiobooks += 1; c.audiobookBytes += Int64(t.fileSize) }
                else { c.songs += 1; c.musicBytes += Int64(t.fileSize) }
            }
            let photosDir = dev.mountPoint.appendingPathComponent("Photos")
            if let e = FileManager.default.enumerator(at: photosDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                while let f = e.nextObject() as? URL {
                    c.photoBytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            if let data = try? Data(contentsOf: photosDir.appendingPathComponent("Photo Database")), data.count > 0x84 {
                let r = ByteReader(data)
                // mhfd → first mhsd (type 1) → mhli holds the photo count.
                let mhsd = Int(r.u32(4))
                if r.hasHeader("mhsd", at: mhsd), r.hasHeader("mhli", at: mhsd + 0x60) { c.photos = Int(r.u32(mhsd + 0x60 + 8)) }
            }
        } catch {
            c.readError = "The iPod's database couldn't be read (\(error.localizedDescription)). Syncing will rebuild it."
        }
        return c
    }

}
