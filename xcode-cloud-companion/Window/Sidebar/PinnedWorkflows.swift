import Observation
import SwiftUI

/// The workflows the user pinned to the top of the sidebar, in the order they chose; kept on this Mac only.
@Observable
final class PinnedWorkflows {
    static let defaultsKey = "sidebar.pinnedWorkflows"

    private(set) var ids: [String]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func isPinned(_ id: String) -> Bool {
        ids.contains(id)
    }

    func toggle(_ id: String) {
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        ids.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func save() {
        defaults.set(ids, forKey: Self.defaultsKey)
    }
}
