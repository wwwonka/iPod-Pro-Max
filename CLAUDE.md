# iPod Pro Max — working notes for Claude

See README.md for what the app does and how it's built.

## Performance principles (always apply)

The app must stay **ultra-lightweight, ultra-responsive and ultra-snappy**, and must never drain the battery for nothing. Treat these as requirements for every feature, not polish to add later.

### Use every core for heavy work
- Any batch work over files or tracks (importing, scanning, tag reading, artwork, transcoding, sync preparation) is designed as **parallel from the start**, sized to the machine at runtime: `ProcessInfo.processInfo.activeProcessorCount`, never a hard-coded number.
- Pattern: a `withTaskGroup` sliding window with one in-flight task per core (see `LibraryStore.importFiles` / `refreshChangedTrackMetadata`). Use fewer workers for disk-bound or memory-heavy work (e.g. ffmpeg transcodes, which are multi-threaded themselves).
- Shared state between workers uses a lock (`OSAllocatedUnfairLock`, e.g. `ArtworkKeyCache`) or an actor, never the main actor.
- Deduplicate expensive work: e.g. an album's tracks share one cover, so its JPEG re-encode happens once per import.

### Keep the main thread free
- The main actor only does UI and cheap bookkeeping. Disk I/O, AVFoundation, image decoding/encoding, hashing and JSON encoding of large data run off it.
- **Batch updates to observed state.** Every mutation of `LibraryStore.tracks` re-renders and regroups the views, so append results in chunks (about every 500 ms), never one item at a time. Progress text is updated at the same cadence, not per item.
- Views cache derived data (grouping, sorting) and recompute only when inputs change; no disk access per row per render (see `missingPaths`).

### Zero work when idle
- When the app is idle, nothing runs: no timers, no polling loops, no periodic background refreshes. React to events instead (IOKit/disk notifications, user actions, app launch).
- Any unavoidable wait loop must be short-lived and tied to a specific operation (e.g. `SyncCoordinator.scheduleSync` waiting for the current sync to end), never open-ended.
- Background work uses an appropriate QoS (`.utility`/`.background` for housekeeping, `.userInitiated` only for work the user is waiting on) so macOS can schedule it efficiently on battery.

### Measure, don't guess
- Benchmark hot paths before and after a change. `Tools/dbtest/run.sh <music folder> <scratch dir> --import-bench` times a full import into a throwaway library (the parallel import took 5,299 files from 77.8 s to 8.7 s on 10 cores).
