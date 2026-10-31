#!/bin/bash
# Patches SwiftCrossUI's checkout before every build (macOS, GTK, WinUI), until the fixes are upstream.
#   patch-dependencies.sh <SwiftPM scratch dir, e.g. .build>
# (On Windows, build-windows.ps1 runs it with the bash that comes with Git.)
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

# Then every patch in patches/ (each says what it fixes), applied once. They must not touch the
# same files: a patch that isn't applied yet starts from the pristine files it touches (an earlier
# version of it may be there), with LF line endings like the patch (Git for Windows checks out CRLF).
checkout="$1/checkouts/swift-cross-ui"
for patch in "$(cd "$(dirname "$0")" && pwd)"/Patches/*.patch; do
    git -C "$checkout" apply --reverse --check "$patch" 2>/dev/null && continue
    git -C "$checkout" apply --numstat "$patch" | cut -f3 | while read -r path; do
        rm -f "$checkout/$path"
        git -C "$checkout" -c core.autocrlf=false checkout -- "$path"
    done
    git -C "$checkout" apply "$patch"
    echo "patch-dependencies: $(basename "$patch") applied"
done
