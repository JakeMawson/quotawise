import Foundation

/// The supported AppKit signals QuotaWise can use to decide whether an
/// existing status item needs to be registered again.
public enum StatusItemAvailability {
    /// A retained item with a button is healthy enough to preserve during
    /// Studio presentation. AppKit's visibility signal can change when the
    /// app loses focus, so it is not a valid recovery trigger.
    public static func requiresRecovery(
        hasStatusItem: Bool,
        hasButton: Bool
    ) -> Bool {
        !hasStatusItem || !hasButton
    }
}
