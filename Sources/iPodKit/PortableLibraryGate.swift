import Foundation

/// FIFO exclusion for operations that read or write the same portable library.
public actor PortableLibraryGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().resume() }
    }
}

/// Keeps a failed write staged until a later retry succeeds; callers must flush before exit/eject.
public actor PortableLibraryWriter {
    private var pending: (store: PortableLibraryStore, cache: PortableLibraryCache)?
    public init() {}
    public func save(_ cache: PortableLibraryCache, to store: PortableLibraryStore) throws {
        try flush()
        pending = (store, cache)
        try flush()
    }
    public func flush() throws {
        guard let value = pending else { return }
        try value.store.save(value.cache)
        pending = nil
    }
}
