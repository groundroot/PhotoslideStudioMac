import Foundation

@MainActor
final class MediaSummaryStore: ObservableObject {
    @Published private(set) var summaries: [UUID: MediaPlaybackSummary] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var lastSignatures: [UUID: RefreshSignature] = [:]
    private var inflightSignatures: [UUID: RefreshSignature] = [:]
    private var lastCompletedAt: [UUID: Date] = [:]

    func summary(for eventID: UUID) -> MediaPlaybackSummary {
        summaries[eventID] ?? MediaPlaybackSummary(itemCount: 0, totalDuration: 0)
    }

    func refresh(for event: SlideshowEvent) {
        let signature = RefreshSignature(event: event)
        let now = Date()

        if inflightSignatures[event.id] == signature {
            return
        }

        if lastSignatures[event.id] == signature,
           let lastCompletedAt = lastCompletedAt[event.id],
           now.timeIntervalSince(lastCompletedAt) < 15 {
            return
        }

        tasks[event.id]?.cancel()
        inflightSignatures[event.id] = signature

        let snapshot = event
        tasks[event.id] = Task.detached(priority: .utility) {
            let result = MediaLibrary.summary(for: snapshot)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.summaries[snapshot.id] = result
                self.tasks[snapshot.id] = nil
                self.inflightSignatures[snapshot.id] = nil
                self.lastSignatures[snapshot.id] = signature
                self.lastCompletedAt[snapshot.id] = Date()
            }
        }
    }

    func remove(eventID: UUID) {
        tasks[eventID]?.cancel()
        tasks[eventID] = nil
        summaries.removeValue(forKey: eventID)
        lastSignatures.removeValue(forKey: eventID)
        inflightSignatures.removeValue(forKey: eventID)
        lastCompletedAt.removeValue(forKey: eventID)
    }
}

private struct RefreshSignature: Hashable {
    let id: UUID
    let kind: ProjectKind
    let mediaSourceKind: MediaSourceKind
    let mediaFolderPath: String
    let cloudSourceURL: String
    let playbackOrder: PlaybackOrder
    let secondsPerPhoto: Double

    init(event: SlideshowEvent) {
        id = event.id
        kind = event.kind
        mediaSourceKind = event.mediaSourceKind
        mediaFolderPath = event.mediaFolderPath
        cloudSourceURL = event.cloudSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        playbackOrder = event.playbackOrder
        secondsPerPhoto = event.secondsPerPhoto
    }
}
