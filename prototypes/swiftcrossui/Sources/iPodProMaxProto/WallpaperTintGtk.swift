#if canImport(GtkBackend)
    import CGtk
    import Foundation

    // The sidebar tinted by the desktop's wallpaper, like macOS's "wallpaper tinting", for GNOME,
    // where an app can't get real blur without a Shell extension (see GlassGtk.swift). The app reads
    // the wallpaper from GNOME's settings (no permission), renders it small, blurs it heavily, blends
    // it with the Mac sidebar color and uses that as the sidebar's background. So blurred that it's
    // only soft gradients: on Wayland an app doesn't know where its window is, and it doesn't need to.
    //
    // Cost: one small render and blur when the wallpaper changes (a few ms, off the main thread),
    // then nothing; the light and dark images are both ready, so switching appearance is free.

    @MainActor
    final class WallpaperTint {
        static let shared = WallpaperTint()

        private static let schema = "org.gnome.desktop.background"
        private var settings: UnsafeMutablePointer<GSettings>?
        private let provider = gtk_css_provider_new()!
        private var providerInstalled = false
        private var generation = 0
        /// Called when the tint becomes ready or goes away (GlassGtk picks the sidebar's style).
        var onChange: () -> Void = {}
        private(set) var isReady = false

        /// Starts following GNOME's wallpaper; false where there is no such setting (not GNOME).
        @discardableResult
        func start() -> Bool {
            guard settings == nil else { return true }
            guard let source = g_settings_schema_source_get_default(),
                  let schema = g_settings_schema_source_lookup(source, Self.schema, 1) else { return false }
            g_settings_schema_unref(schema)
            settings = g_settings_new(Self.schema)
            g_signal_connect_data(cast(settings), "changed", unsafeBitCast(wallpaperChanged, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
            refresh()
            return true
        }

        fileprivate func refresh() {
            guard let settings else { return }
            let light = Self.path(fromURI: string(settings, "picture-uri"))
            let dark = Self.path(fromURI: string(settings, "picture-uri-dark")) ?? light
            let fallback = string(settings, "primary-color")
            generation += 1
            let current = generation
            let cacheDir = Self.cacheDirectory()
            // Off the main thread: decoding even a small render of an SVG or JPEG takes a few ms.
            DispatchQueue.global(qos: .utility).async {
                let lightFile = Self.renderTint(from: light, fallbackColor: fallback, dark: false, into: cacheDir, generation: current)
                let darkFile = Self.renderTint(from: dark, fallbackColor: fallback, dark: true, into: cacheDir, generation: current)
                let result = TintFiles(generation: current, light: lightFile, dark: darkFile)
                g_idle_add_full(200, { data in
                    let files = Unmanaged<TintFiles>.fromOpaque(data!).takeRetainedValue()
                    MainActor.assumeIsolated { WallpaperTint.shared.apply(files) }
                    return 0
                }, Unmanaged.passRetained(result).toOpaque(), nil)
            }
        }

        private func apply(_ files: TintFiles) {
            guard files.generation == generation else { return }  // a newer wallpaper is on its way
            guard let light = files.light, let dark = files.dark else {
                isReady = false
                onChange()
                return
            }
            gtk_css_provider_load_from_string(provider, """
                window.ippm-tint .ippm-sidebar-pane { background: #EBEBEB url("file://\(light)") center / cover no-repeat; }
                window.ippm-tint.ippm-dark .ippm-sidebar-pane { background: #2C2C2C url("file://\(dark)") center / cover no-repeat; }
                """)
            if !providerInstalled {
                providerInstalled = true
                gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 802)
            }
            isReady = true
            onChange()
        }

        private func string(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> String? {
            guard let value = g_settings_get_string(settings, key) else { return nil }
            defer { g_free(value) }
            let s = String(cString: value)
            return s.isEmpty ? nil : s
        }

        // MARK: Rendering (any thread)

        private final class TintFiles {
            let generation: Int
            let light: String?
            let dark: String?
            init(generation: Int, light: String?, dark: String?) {
                self.generation = generation
                self.light = light
                self.dark = dark
            }
        }

        /// The tint is this many pixels wide; GTK scales it up smoothly (it's only gradients).
        nonisolated private static let width = 96

        nonisolated private static func cacheDirectory() -> URL {
            let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
            return base.appendingPathComponent("iPodProMax", isDirectory: true)
        }

        nonisolated private static func path(fromURI uri: String?) -> String? {
            guard var uri, !uri.isEmpty else { return nil }
            if uri.hasPrefix("file://") { uri = String(uri.dropFirst(7)) }
            uri = uri.removingPercentEncoding ?? uri
            // GNOME's time-of-day wallpapers are XML slide shows: take their first picture.
            if uri.hasSuffix(".xml"), let xml = try? String(contentsOfFile: uri, encoding: .utf8),
               let start = xml.range(of: "<file>"), let end = xml.range(of: "</file>", range: start.upperBound..<xml.endIndex) {
                return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return uri
        }

        /// Renders, blurs and blends one tint, and writes it as a PNG; nil when there's no wallpaper.
        nonisolated private static func renderTint(from path: String?, fallbackColor: String?, dark: Bool, into dir: URL, generation: Int) -> String? {
            let base: (Double, Double, Double) = dark ? (44, 44, 44) : (235, 235, 235)
            var pixels: [Double]
            var w = width, h = width * 9 / 16
            if let path, let pixbuf = gdk_pixbuf_new_from_file_at_scale(path, Int32(width), -1, 1, nil) {
                defer { g_object_unref(cast(pixbuf)) }
                w = Int(gdk_pixbuf_get_width(pixbuf)); h = Int(gdk_pixbuf_get_height(pixbuf))
                let stride = Int(gdk_pixbuf_get_rowstride(pixbuf)), channels = Int(gdk_pixbuf_get_n_channels(pixbuf))
                guard let data = gdk_pixbuf_read_pixels(pixbuf), w > 0, h > 0 else { return nil }
                pixels = [Double](repeating: 0, count: w * h * 3)
                for y in 0..<h {
                    for x in 0..<w {
                        let p = y * stride + x * channels
                        for c in 0..<3 { pixels[(y * w + x) * 3 + c] = Double(data[p + c]) }
                    }
                }
            } else if let rgb = fallbackColor.flatMap(parseHex) {
                pixels = (0..<(w * h)).flatMap { _ in [rgb.0, rgb.1, rgb.2] }
            } else {
                return nil
            }
            // Three box blurs ≈ a Gaussian; radius ~1/8 of the width leaves only soft color fields.
            for _ in 0..<3 { boxBlur(&pixels, w, h, radius: max(w / 8, 1)) }
            // Blended with the Mac sidebar color, as macOS does: a hint of the desktop, still calm.
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                for c in 0..<3 {
                    let b = c == 0 ? base.0 : c == 1 ? base.1 : base.2
                    rgba[i * 4 + c] = UInt8(clamping: Int((pixels[i * 3 + c] * 0.35 + b * 0.65).rounded()))
                }
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A new name per generation, so GTK never serves a stale image from its cache.
            let name = "sidebar-tint-\(generation)-\(dark ? "dark" : "light").png"
            let file = dir.appendingPathComponent(name).path
            for old in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where old.hasPrefix("sidebar-tint-") && old.hasSuffix(dark ? "-dark.png" : "-light.png") && old != name {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(old).path)
            }
            let saved = rgba.withUnsafeBytes { raw -> Bool in
                guard let bytes = g_bytes_new(raw.baseAddress, gsize(raw.count)) else { return false }
                defer { g_bytes_unref(bytes) }
                guard let texture = gdk_memory_texture_new(Int32(w), Int32(h), GDK_MEMORY_R8G8B8A8, bytes, gsize(w * 4)) else { return false }
                defer { g_object_unref(cast(texture)) }
                return gdk_texture_save_to_png(texture, file) != 0
            }
            return saved ? file : nil
        }

        nonisolated private static func boxBlur(_ p: inout [Double], _ w: Int, _ h: Int, radius r: Int) {
            var tmp = p
            for y in 0..<h {
                for x in 0..<w {
                    var sum = (0.0, 0.0, 0.0), n = 0.0
                    for dx in -r...r {
                        let xx = min(max(x + dx, 0), w - 1), i = (y * w + xx) * 3
                        sum.0 += p[i]; sum.1 += p[i + 1]; sum.2 += p[i + 2]; n += 1
                    }
                    let o = (y * w + x) * 3
                    tmp[o] = sum.0 / n; tmp[o + 1] = sum.1 / n; tmp[o + 2] = sum.2 / n
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var sum = (0.0, 0.0, 0.0), n = 0.0
                    for dy in -r...r {
                        let yy = min(max(y + dy, 0), h - 1), i = (yy * w + x) * 3
                        sum.0 += tmp[i]; sum.1 += tmp[i + 1]; sum.2 += tmp[i + 2]; n += 1
                    }
                    let o = (y * w + x) * 3
                    p[o] = sum.0 / n; p[o + 1] = sum.1 / n; p[o + 2] = sum.2 / n
                }
            }
        }

        nonisolated private static func parseHex(_ s: String) -> (Double, Double, Double)? {
            let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
            return (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
        }
    }

    private let wallpaperChanged: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, key, _ in
        guard let key else { return }
        let name = String(cString: key)
        guard name.hasPrefix("picture-uri") || name == "primary-color" else { return }
        MainActor.assumeIsolated { WallpaperTint.shared.refresh() }
    }
#endif
