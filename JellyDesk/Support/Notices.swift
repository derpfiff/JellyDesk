import Foundation

/// Kurze Hinweise, die das Hauptfenster einige Sekunden einblendet.
@MainActor
final class Notices: ObservableObject {
    @Published private(set) var current: String?
    private var hideTask: Task<Void, Never>?

    func post(_ text: String) {
        current = text
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}
