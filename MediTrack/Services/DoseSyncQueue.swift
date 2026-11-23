import Foundation
import Network

enum RetryPolicy {
    static let maximumAttempts = 5

    static func reserveAttempt(for log: inout DoseLog, now: Date) {
        log.attempts += 1
        log.nextAttemptAt = nextDate(after: now, attempt: log.attempts)
    }

    static func recordFailure(_ error: Error, for log: inout DoseLog, now: Date) {
        log.failure = error.localizedDescription
        if log.attempts >= maximumAttempts || !isRetryable(error) {
            log.syncState = .failed
        } else {
            log.nextAttemptAt = nextDate(after: now, attempt: log.attempts)
        }
    }

    private static func nextDate(after date: Date, attempt: Int) -> Date {
        date.addingTimeInterval(TimeInterval(1 << attempt))
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return error is URLError }
        guard case .http(let code) = apiError else { return false }
        return [408, 425, 429].contains(code) || (500...599).contains(code)
    }
}

@MainActor
final class DoseSyncQueue {
    private let store: any MedicationStore
    private let api: any ClinicAPI
    private let now: () -> Date
    private var available = false
    private var worker: Task<Void, Never>?
    private var wake: Task<Void, Never>?

    var onChange: (() -> Void)?
    var onStoreError: ((Error) -> Void)?

    init(store: any MedicationStore, api: any ClinicAPI, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.api = api
        self.now = now
    }

    func setAvailable(_ available: Bool) {
        self.available = available
        if available {
            kick()
        } else {
            wake?.cancel()
            wake = nil
        }
    }

    func kick() {
        guard available, worker == nil else { return }
        wake?.cancel()
        wake = nil
        worker = Task { [weak self] in await self?.drain() }
    }

    func waitForCurrentPass() async {
        await worker?.value
    }

    private func drain() async {
        defer { worker = nil }
        while available {
            do {
                guard var log = try store.pendingLogs().first else { return }
                let delay = log.nextAttemptAt.timeIntervalSince(now())
                guard delay <= 0 else {
                    scheduleWake(after: delay)
                    return
                }

                if log.attempts >= RetryPolicy.maximumAttempts {
                    log.syncState = .failed
                    log.failure = "The last sync attempt was interrupted."
                    try store.saveSync(log)
                    onChange?()
                    continue
                }

                // Reserve the attempt before the request so a relaunch still respects the cap.
                RetryPolicy.reserveAttempt(for: &log, now: now())
                try store.saveSync(log)

                do {
                    try await api.submit(log)
                    log.syncState = .synced
                    log.failure = nil
                } catch {
                    RetryPolicy.recordFailure(error, for: &log, now: now())
                }

                // Persist a response even if connectivity or scene state changed during the request.
                try store.saveSync(log)
                onChange?()
            } catch {
                onStoreError?(error)
                if available { scheduleWake(after: 5) }
                return
            }
        }
    }

    private func scheduleWake(after delay: TimeInterval) {
        wake = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                self?.kick()
            } catch is CancellationError {
                // A new event recomputes the next persisted deadline.
            } catch {
                self?.onStoreError?(error)
            }
        }
    }
}

protocol ConnectivitySource {
    func updates() -> AsyncStream<Bool>
}

struct NetworkConnectivity: ConnectivitySource {
    func updates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "MediTrack.connectivity"))
        }
    }
}
