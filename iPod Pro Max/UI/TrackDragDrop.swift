//
//  TrackDragDrop.swift
//  iPod Pro Max
//
//  In-app drag payload for dragging one or more library track selections (e.g. audiobooks) onto
//  an iPod in the sidebar to turn their sync flag on.
//
//  Uses the system "public.data" type rather than a custom exported UTType, which would need a
//  matching UTExportedTypeDeclarations entry in Info.plist (awkward with this target's auto-generated
//  one) — this is a private, in-process drag between two SwiftUI views in the same app, so there's no
//  need for a globally-registered type identifier.
//

import SwiftUI
import UniformTypeIdentifiers

struct TrackIDsTransfer: Codable, Transferable {
    var ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
