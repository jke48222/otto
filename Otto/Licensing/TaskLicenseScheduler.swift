//
//  TaskLicenseScheduler.swift
//  Otto
//
//  The live LicenseScheduling (§14.4.4): each piece of work runs once on the main actor after its delay, measured on
//  the continuous clock (which keeps counting while the Mac sleeps). Cancelling the returned handle before the delay
//  ends means the work never runs. Tests use ManualLicenseScheduler instead.
//

#if OTTO_LICENSING
import Foundation

@MainActor final class TaskLicenseScheduler: LicenseScheduling {
    init() {}

    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> LicenseScheduledWork {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: max(delay, Duration.zero), clock: .continuous)
            } catch {
                return  // cancelled
            }
            guard !Task.isCancelled else { return }
            work()
        }
        return LicenseScheduledWork { task.cancel() }
    }
}
#endif
