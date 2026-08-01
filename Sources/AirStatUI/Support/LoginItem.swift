import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService`, the only mechanism that works on
/// macOS 13+ without shipping a separate helper bundle.
public enum LoginItem {

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Make the system state match the user's preference. Failures are returned
    /// rather than swallowed, because a silent no-op here is indistinguishable
    /// from the feature not existing.
    @discardableResult
    public static func synchronize(enabled: Bool) -> Error? {
        do {
            let service = SMAppService.mainApp
            if enabled {
                guard service.status != .enabled else { return nil }
                try service.register()
            } else {
                guard service.status == .enabled else { return nil }
                try service.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
