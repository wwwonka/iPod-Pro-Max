#!/bin/bash
# Patches SwiftCrossUI's checkout before a GTK build, until the fix is upstream.
#   patch-dependencies.sh <SwiftPM scratch dir, e.g. .build>
#
# GTK: Pango(for:) created a fresh Pango context for every text measurement, which makes GTK
# recompute the widget's CSS each time; SwiftCrossUI measures every Text on each update, so a
# sidebar click cost ~320 ms in the Fedora VM. GTK already keeps a context per widget, kept up to
# date on style changes: reuse it.
set -euo pipefail
file="$1/checkouts/swift-cross-ui/Sources/Gtk/Utility/Pango.swift"
[ -f "$file" ] || { echo "patch-dependencies: $file not found (run swift package resolve first)" >&2; exit 1; }
if grep -q "gtk_widget_create_pango_context(widget.widgetPointer)" "$file"; then
    chmod u+w "$file"
    perl -0pi -e 's/pangoContext = gtk_widget_create_pango_context\(widget\.widgetPointer\)/pangoContext = gtk_widget_get_pango_context(widget.widgetPointer)\n        g_object_ref(UnsafeMutableRawPointer(pangoContext))/' "$file"
    echo "patch-dependencies: Pango context reuse applied"
fi
