#if canImport(GtkBackend)
    import CGtk
    import Foundation

    // A translucent, blurred sidebar on Linux, like WhiteSur-Glassy and Aura Glass: the app never
    // blurs anything itself (on Wayland it can't even see the desktop). It only makes the sidebar's
    // background translucent; the compositor blurs what's behind the window, on the GPU, at no cost
    // to the app. That only looks right when something does blur, so the sidebar stays opaque
    // unless one of these is there:
    // - GNOME with the Blur my Shell extension, its "Applications" blur on, and this app in its
    //   whitelist (or "blur all applications"),
    // - Hyprland, which blurs translucent windows by default.
    // Without blur, GNOME gets the wallpaper tint instead (WallpaperTintGtk.swift), and other desktops
    // the opaque Mac color. `IPPM_GLASS=1`, `tint` or `0` forces glass, tint or opaque.
    // KDE (org_kde_kwin_blur) is a separate card.
    //
    // Only the sidebar's background is translucent: text, icons and the track table stay opaque.
    // Blur my Shell's own "opacity" setting fades whole windows, text included; 255 keeps them crisp.

    @MainActor
    final class LinuxGlass {
        static let shared = LinuxGlass()

        private static let extensionUUID = "blur-my-shell@aunetx"
        private static let applicationsSchema = "org.gnome.shell.extensions.blur-my-shell.applications"

        private var window: UnsafeMutablePointer<GtkWindow>?
        private var shellSettings: UnsafeMutablePointer<GSettings>?
        private var blurSettings: UnsafeMutablePointer<GSettings>?
        private var styleInstalled = false

        /// Called once the window exists. Watches the settings it depends on (signals, no polling).
        func install(on window: UnsafeMutablePointer<GtkWindow>) {
            self.window = window
            installStyle()
            if forced == nil { watchBlurMyShell() }
            if forced != "0" {
                WallpaperTint.shared.onChange = { LinuxGlass.shared.apply() }
                WallpaperTint.shared.start()
            }
            apply()
        }

        private var forced: String? {
            let value = ProcessInfo.processInfo.environment["IPPM_GLASS"]
            return ["1", "0", "tint"].contains(value) ? value : nil
        }

        /// What blurs behind the window, if anything.
        private func blurSource() -> String? {
            if let forced { return forced == "1" ? "IPPM_GLASS=1" : nil }
            if ProcessInfo.processInfo.environment["HYPRLAND_INSTANCE_SIGNATURE"] != nil { return "Hyprland" }
            if blurMyShellBlursThisApp() { return "Blur my Shell" }
            return nil
        }

        /// The last style applied: settings fire one "changed" per key, most of them unrelated.
        private var appliedStyle: String?

        fileprivate func apply() {
            guard let window else { return }
            let source = blurSource()
            let tint = source == nil && forced != "0" && WallpaperTint.shared.isReady
            let style = source.map { "translucent, blurred by \($0)" } ?? (tint ? "tinted by the wallpaper" : "opaque")
            guard appliedStyle != style else { return }
            appliedStyle = style
            for (cssClass, on) in [("ippm-glass", source != nil), ("ippm-tint", tint)] {
                if on { gtk_widget_add_css_class(cast(window), cssClass) } else { gtk_widget_remove_css_class(cast(window), cssClass) }
            }
            log("[glass] sidebar \(style)")
        }

        // MARK: Blur my Shell

        private func blurMyShellBlursThisApp() -> Bool {
            guard let shellSettings, let blurSettings else { return false }
            guard g_settings_get_boolean(shellSettings, "disable-user-extensions") == 0,
                  strv(shellSettings, "enabled-extensions").contains(Self.extensionUUID),
                  g_settings_get_boolean(blurSettings, "blur") != 0 else { return false }
            return g_settings_get_boolean(blurSettings, "enable-all") != 0
                || strv(blurSettings, "whitelist").contains(appIdentifier)
        }

        /// Loads the extension's settings (its schema ships inside the extension, not with GLib) and
        /// re-applies when the user changes them.
        private func watchBlurMyShell() {
            guard let source = g_settings_schema_source_get_default(),
                  let shellSchema = g_settings_schema_source_lookup(source, "org.gnome.shell", 1) else { return }
            g_settings_schema_unref(shellSchema)
            shellSettings = g_settings_new("org.gnome.shell")
            connectChanged(shellSettings)

            let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let dataDirs = (ProcessInfo.processInfo.environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":")
            let candidates = ["\(home)/.local/share"] + dataDirs.map(String.init)
            for base in candidates {
                let dir = "\(base)/gnome-shell/extensions/\(Self.extensionUUID)/schemas"
                guard FileManager.default.fileExists(atPath: dir + "/gschemas.compiled"),
                      let extensionSource = g_settings_schema_source_new_from_directory(dir, source, 0, nil) else { continue }
                defer { g_settings_schema_source_unref(extensionSource) }
                guard let schema = g_settings_schema_source_lookup(extensionSource, Self.applicationsSchema, 0) else { continue }
                blurSettings = g_settings_new_full(schema, nil, nil)
                g_settings_schema_unref(schema)
                connectChanged(blurSettings)
                return
            }
            // Installed system-wide with its schema compiled into GLib's own directory.
            if let schema = g_settings_schema_source_lookup(source, Self.applicationsSchema, 1) {
                blurSettings = g_settings_new_full(schema, nil, nil)
                g_settings_schema_unref(schema)
                connectChanged(blurSettings)
            }
        }

        private func connectChanged(_ settings: UnsafeMutablePointer<GSettings>?) {
            guard let settings else { return }
            g_signal_connect_data(cast(settings), "changed", unsafeBitCast(glassSettingsChanged, to: GCallback.self),
                                  nil, nil, GConnectFlags(rawValue: 0))
        }

        fileprivate func settingsChanged() { apply() }

        private func strv(_ settings: UnsafeMutablePointer<GSettings>, _ key: String) -> [String] {
            guard let values = g_settings_get_strv(settings, key) else { return [] }
            defer { g_strfreev(values) }
            var result: [String] = []
            var i = 0
            while let value = values[i] {
                result.append(String(cString: value))
                i += 1
            }
            return result
        }

        // MARK: Style

        /// The window's own background goes; the sidebar keeps the Mac's colors at 60 % so the blur
        /// shows through; the detail column paints its own opaque background (WindowBackground).
        private func installStyle() {
            guard !styleInstalled else { return }
            styleInstalled = true
            let provider = gtk_css_provider_new()!
            loadCSS(provider, """
                window.ippm-glass, window.ippm-glass > .ippm-content { background-color: transparent; }
                window.ippm-glass .ippm-sidebar-pane { background-color: rgba(235, 235, 235, 0.6); }
                window.ippm-glass.ippm-dark .ippm-sidebar-pane { background-color: rgba(44, 44, 44, 0.6); }
                """)
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), cast(provider), 801)
        }
    }

    private let glassSettingsChanged: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { _, _, _ in
        MainActor.assumeIsolated { LinuxGlass.shared.settingsChanged() }
    }
#endif
