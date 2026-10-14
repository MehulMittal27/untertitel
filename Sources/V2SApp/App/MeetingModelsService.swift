import Foundation
import MeetingKit
import os.log

private extension Logger {
    static let models = Logger(subsystem: "com.franklioxygen.v2s", category: "meetingModels")
}

/// The FluidAudio meeting models as Settings shows them: downloaded or not, how big,
/// and the download in progress. The only path that lets them reach the network.
@MainActor
final class MeetingModelsService: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed(bytes: Int64)
        case failed(String)
    }

    @Published private(set) var status: Status = .notInstalled

    private let isInstalledCheck: () -> Bool
    private let measure: () -> Int64
    private let downloadModels: (@escaping @Sendable (Double) -> Void) async throws -> Void
    private let deleteModels: () throws -> Void

    init(
        isInstalled: @escaping () -> Bool = { MeetingModels.isInstalled },
        measure: @escaping () -> Int64 = { MeetingModels.installedBytes() },
        download: @escaping (@escaping @Sendable (Double) -> Void) async throws -> Void = { try await MeetingModels.download(progress: $0) },
        delete: @escaping () throws -> Void = { try MeetingModels.delete() }
    ) {
        isInstalledCheck = isInstalled
        self.measure = measure
        downloadModels = download
        deleteModels = delete
        refresh()
    }

    var isInstalled: Bool {
        if case .installed = status { return true }
        return false
    }

    func refresh() {
        status = isInstalledCheck() ? .installed(bytes: measure()) : .notInstalled
    }

    func download() async {
        if case .downloading = status { return }
        status = .downloading(0)
        do {
            try await downloadModels { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.status else { return }
                    self.status = .downloading(fraction)
                }
            }
            Logger.models.log("Meeting models downloaded")
            refresh()
        } catch {
            Logger.models.error("Meeting models did not download: \(String(describing: error), privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

#if DEBUG
    func setStatusForTesting(_ status: Status) { self.status = status }
#endif

    func delete() {
        do {
            try deleteModels()
        } catch {
            Logger.models.error("Meeting models could not be deleted: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
}
