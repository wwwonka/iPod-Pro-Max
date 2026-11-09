import Foundation
/// Bridge between the menu bar and `ContentView`: the view registers what each command does once it
/// is up, the menus only call them (nothing happens before that).
@MainActor
enum AppCommands {
    static var addMusicFolder: (() -> Void)?
    static var addAudiobooksFolder: (() -> Void)?
    static var addPhotosFolder: (() -> Void)?
    static var openSettings: (() -> Void)?
    /// Records a folder (kind = `SourceKind.rawValue`) chosen in the Settings window, then refreshes the
    /// library. The choosing happens in Settings; the main window is only asked to do the work.
    static var addSource: ((_ kind: String, _ folder: URL) -> Void)?
    static var removeSource: ((_ id: UUID) -> Void)?
}
