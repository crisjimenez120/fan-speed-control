import FanShared
import Foundation

enum HelperInstaller {
    static let label = HelperConstants.machServiceName

    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchServices/\(label)")
    }

    static func install() throws {
        let plist: [String: Any] = [
            "Label": label,
            "Program": HelperConstants.helperPath,
            "MachServices": [label: true],
            "RunAtLoad": true,
        ]
        let tmp = FileManager.default.temporaryDirectory.appending(path: "\(label).plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: tmp)
        let src = bundledHelperURL.path
        guard FileManager.default.fileExists(atPath: src) else {
            throw InstallError("The helper is missing from the app bundle.")
        }
        let dst = HelperConstants.helperPath
        let plistDst = HelperConstants.plistPath
        try runAsAdmin("""
        /bin/launchctl bootout system/\(label) 2>/dev/null; \
        /bin/mkdir -p /Library/PrivilegedHelperTools && \
        /bin/cp -f \(q(src)) \(q(dst)) && /usr/sbin/chown root:wheel \(q(dst)) && /bin/chmod 755 \(q(dst)) && \
        /bin/cp -f \(q(tmp.path)) \(q(plistDst)) && /usr/sbin/chown root:wheel \(q(plistDst)) && /bin/chmod 644 \(q(plistDst)) && \
        /bin/launchctl bootstrap system \(q(plistDst))
        """)
    }

    static func uninstall() throws {
        try runAsAdmin("""
        /bin/launchctl bootout system/\(label) 2>/dev/null; \
        /bin/rm -f \(q(HelperConstants.helperPath)) \(q(HelperConstants.plistPath))
        """)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Fan Control needs to install its helper to change fan speeds.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            if code == -128 { throw InstallError("Cancelled.") }
            throw InstallError(error[NSAppleScript.errorMessage] as? String ?? "Installation failed.")
        }
    }

    struct InstallError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
