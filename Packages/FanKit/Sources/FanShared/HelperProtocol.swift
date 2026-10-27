import Foundation

public enum HelperConstants {
    public static let machServiceName = "com.crisjimenez.FanControl.Helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/com.crisjimenez.FanControl.Helper"
    public static let plistPath = "/Library/LaunchDaemons/com.crisjimenez.FanControl.Helper.plist"
    /// Bump whenever the helper's behavior changes so the app offers to reinstall it.
    public static let version = "1.0.0"
    public static let appIdentifier = "com.crisjimenez.FanControl"

    /// Only the Fan Control app, signed by the same team as the helper, may connect.
    /// Builds signed ad hoc (no team) fall back to checking the identifier only.
    public static func clientRequirement(teamID: String?) -> String {
        guard let teamID else { return #"identifier "\#(appIdentifier)""# }
        return #"anchor apple generic and identifier "\#(appIdentifier)" and certificate leaf[subject.OU] = "\#(teamID)""#
    }
    /// The helper restores automatic control if the app is silent this long.
    public static let watchdogTimeout: TimeInterval = 10
}

/// XPC interface of the privileged helper. Replies carry an error message, or nil on success.
@objc public protocol FanHelperProtocol {
    func version(reply: @escaping @Sendable (String) -> Void)
    func setFanRPM(_ index: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void)
    func setFanAuto(_ index: Int, reply: @escaping @Sendable (String?) -> Void)
    func setAllAuto(reply: @escaping @Sendable (String?) -> Void)
    /// Keeps manual control alive. Without it the watchdog returns fans to auto.
    func heartbeat()
}
