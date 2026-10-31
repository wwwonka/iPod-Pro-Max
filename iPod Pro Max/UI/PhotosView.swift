import Foundation
import SwiftCrossUI
import iPodKit
import MediaKit

/// The Photos section: what this computer sends to the iPod's Photos menu. Folders work on every OS (each
/// becomes an album, and so does each subfolder with pictures); a Mac can also pick albums of the Photos
/// app. The iPod's photos are rebuilt from these choices when you sync.
struct PhotosView: View {
    var store: PortableLibraryStore?
    /// Names of the connected iPods with a color screen.
    var devices: [String]
    var isBusy: (String) -> Bool
    var onSync: (String) -> Void
    @Environment(\.chooseFile) private var chooseFile

    @State private var folders: [KnownSource] = []
    @State private var folderCounts: [UUID: Int] = [:]
    @State private var selection = PhotoSelection()
    @State private var message = ""
    #if canImport(Photos) && canImport(AppKit)
    @State private var access = PhotosApp.access
    @State private var albums: [PhotosAlbumInfo] = []
    @State private var allCount = 0
    #endif

    private var choices: PhotoChoices { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(summary).foregroundColor(.gray)
                Spacer()
                ForEach(devices, id: \.self) { name in
                    Button(devices.count > 1 ? "Sync photos to \(name)" : "Sync photos to iPod") { onSync(name) }
                        .disabled(isBusy(name) || total == 0)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    folderBox
                    #if canImport(Photos) && canImport(AppKit)
                    photosAppBox
                    #endif
                    if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundColor(MacColor.red) }
                    Caption("Pictures are copied as iPod thumbnails (about 0.9 MB each on an iPod Video), so a large collection takes a while and a fair amount of space. Syncing replaces the iPod's photos with exactly this choice.")
                }
                .padding(16)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await refresh() }
    }

    // MARK: Sections

    private var folderBox: some View {
        GroupBox(title: "Folders") {
            VStack(alignment: .leading, spacing: 8) {
                if folders.isEmpty {
                    Text("No folder yet. Add a folder of pictures: each folder is an album on the iPod, and so is each of its subfolders.")
                        .foregroundColor(.gray)
                }
                ForEach(folders, id: \.id) { folder in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent).lineLimit(1)
                            Text(folder.path).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        Text(folderCounts[folder.id].map { "\($0) pictures" } ?? "…").font(.system(size: 11)).foregroundColor(.gray)
                        Button("Remove") { remove(folder) }
                    }
                }
                Button("Add Folder…") { Task { await addFolder() } }
            }
        }
    }

    #if canImport(Photos) && canImport(AppKit)
    private var photosAppBox: some View {
        GroupBox(title: "Photos app") {
            VStack(alignment: .leading, spacing: 8) {
                switch access {
                case .authorized:
                    CheckboxRow(title: "All Photos (\(allCount))", isOn: Binding(get: { selection.includeAllPhotos }, set: { value in
                        var copy = selection; copy.includeAllPhotos = value; apply(copy)
                    }))
                    if albums.isEmpty { Text("No albums found in Photos.").foregroundColor(.gray) }
                    ForEach(albums) { album in
                        CheckboxRow(title: "\(album.title) (\(album.count))", isOn: Binding(get: { selection.albumIDs.contains(album.id) }, set: { value in
                            var copy = selection
                            if value { if !copy.albumIDs.contains(album.id) { copy.albumIDs.append(album.id) } } else { copy.albumIDs.removeAll { $0 == album.id } }
                            copy.albumNames[album.id] = album.title
                            apply(copy)
                        }))
                    }
                case .notDetermined:
                    Text("Pick albums from the Photos app to copy them to the iPod.").foregroundColor(.gray)
                    Button("Choose Albums…") { Task { await requestAccess() } }
                case .denied:
                    Text("Photos access is off. Allow iPod Pro Max to read your Photos library in System Settings › Privacy & Security › Photos, then check again.")
                        .foregroundColor(.gray)
                    Button("Check Again") { Task { await refresh() } }
                }
            }
        }
    }
    #endif

    // MARK: Numbers

    private var total: Int {
        var n = folderCounts.values.reduce(0, +)
        #if canImport(Photos) && canImport(AppKit)
        if access == .authorized {
            n += selection.includeAllPhotos ? allCount : albums.filter { selection.albumIDs.contains($0.id) }.reduce(0) { $0 + $1.count }
        }
        #endif
        return n
    }

    private var summary: String {
        let n = total
        return n == 0 ? "Nothing selected" : "About \(n) picture\(n == 1 ? "" : "s") selected"
    }

    // MARK: Actions

    private func apply(_ new: PhotoSelection) {
        selection = new
        choices.update(new)
    }

    private func refresh() async {
        guard let store else { return }
        selection = choices.selection
        let sources = await Task.detached(priority: .userInitiated) { store.sources(of: .photos) }.value
        folders = sources
        let counts = await Task.detached(priority: .userInitiated) { () -> [UUID: Int] in
            Dictionary(uniqueKeysWithValues: sources.map { ($0.id, FolderPhotoLibrary.images(in: URL(fileURLWithPath: $0.path)).count) })
        }.value
        folderCounts = counts
        #if canImport(Photos) && canImport(AppKit)
        access = PhotosApp.access
        if access == .authorized {
            let (found, count) = await Task.detached(priority: .userInitiated) { (PhotosApp.albums(), PhotosApp.allPhotosCount()) }.value
            albums = found
            allCount = count
        }
        #endif
    }

    #if canImport(Photos) && canImport(AppKit)
    private func requestAccess() async {
        access = await PhotosApp.requestAccess()
        await refresh()
    }
    #endif

    private func addFolder() async {
        guard let store, let url = await chooseFile(title: "Choose a Folder of Pictures", defaultButtonLabel: "Add Folder",
            allowSelectingFiles: false, allowSelectingDirectories: true) else { return }
        message = ""
        do {
            try await Task.detached(priority: .userInitiated) { try store.addSource(kind: .photos, path: url.path) }.value
        } catch { message = "Couldn't add the folder: \(error.localizedDescription)"; return }
        await refresh()
    }

    private func remove(_ folder: KnownSource) {
        guard let store else { return }
        folders.removeAll { $0.id == folder.id }
        folderCounts[folder.id] = nil
        Task {
            do { try await Task.detached(priority: .utility) { try store.removeSource(id: folder.id) }.value }
            catch { message = "Couldn't remove the folder: \(error.localizedDescription)" }
        }
    }
}
