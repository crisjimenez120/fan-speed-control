import Foundation

public enum HelperConstants {
    public static let machServiceName = "com.crisjimenez.FanControl.Helper"
    public static let helperPath = "/Library/PrivilegedHelperTools/com.crisjimenez.FanControl.Helper"
    public static let plistPath = "/Library/LaunchDaemons/com.crisjimenez.FanControl.Helper.plist"
    /// Bump whenever the helper's behavior changes so the app offers to reinstall it.
    public static let version = "1.0.0"
    /// Only the signed FanControl app may connect.
    public static let clientRequirement =
        #"anchor apple generic and identifier "com.crisjimenez.FanControl" and certificate leaf[subject.OU] = "7C9898VUH3""#
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
