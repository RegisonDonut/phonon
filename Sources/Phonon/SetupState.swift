import SwiftUI

/// Observable state for the first-run setup window — the installer sees every
/// step and live download progress here.
@MainActor
final class SetupState: ObservableObject {
    enum Phase: Equatable {
        case choosing           // first-run: pick which model to install
        case preparing          // unpacking / locating the server
        case downloading        // pulling the model
        case startingServer     // booting the local model server
        case ready
        case error(String)
    }

    @Published var phase: Phase = .preparing
    @Published var fraction: Double = 0          // 0…1 for the download
    @Published var detail: String = ""           // e.g. "2.1 / 5.7 GB · 18 MB/s"
    var onChoose: ((ModelSpec) -> Void)?         // first-run picker callback
}
