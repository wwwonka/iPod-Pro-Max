# iPod Pro Max — working notes

See README.md for what the app does, the repo layout and how it's built. Every change to the app ships on macOS, Windows and Linux together.

## Performance principles (always apply)

The app must stay **ultra-lightweight, ultra-responsive and ultra-snappy**, and must never drain the battery for nothing. These are requirements for every feature, not polish.

- **Use every core for heavy work.** Batch work over files or tracks (import, scan, tags, artwork, transcoding, sync prep) is parallel from the start, sized with `ProcessInfo.processInfo.activeProcessorCount`, never a hard-coded number. Use a `withTaskGroup` sliding window with one in-flight task per core (reference implementation: `LibraryStore.importFiles` in `Refs/SwiftUI/`). Use fewer workers for disk-bound or already multi-threaded work (ffmpeg). Shared state between workers goes behind a lock (`OSAllocatedUnfairLock`) or an actor, never the main actor. Deduplicate expensive work (an album's tracks share one cover, re-encoded once per import).
- **Keep the main thread free.** The main actor only does UI and cheap bookkeeping; disk I/O, AVFoundation, image coding, hashing and large JSON encoding run off it. Batch updates to observed state (append results about every 500 ms, progress text at the same cadence), because each mutation re-renders and regroups views. Views cache derived data and recompute only when inputs change; no disk access per row per render.
- **Zero work when idle.** No timers, polling loops or periodic refreshes; react to events (IOKit/disk notifications, user actions, launch). Any unavoidable wait loop is short-lived and tied to one operation. Background work uses the lowest suitable QoS (`.utility`/`.background`; `.userInitiated` only when the user is waiting).
- **Measure, don't guess.** Benchmark hot paths before and after: `Tools/DbTest/run.sh <music folder> <scratch dir> --import-bench` times a full import into a throwaway library.

## How we track work
- **Tasks**: private GitHub Project "iPod Pro Max" (https://github.com/users/wwwonka/projects/5); issues are disabled, cards are draft items with `Status` (Todo / In Progress / Done) and `Phase`. Manage with `gh project item-list|item-create|item-edit 5 --owner wwwonka`. New work gets a card first; set In Progress when starting, Done (with commit hashes in the body) when finished.
- **Decisions, architecture, measurements**: `Docs/` (Obsidian vault opened on `Docs/`, never the repo root). Don't duplicate task status there.
- **Conventions**: initial capitals for project folders; keep established module names and tool-managed hidden folders; no empty placeholder folders. The old SwiftUI app in `Refs/SwiftUI/` is a porting reference only.
- The final feature roadmap is not defined yet; discuss it with the owner before creating the next GitHub Project.
