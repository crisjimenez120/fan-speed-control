import FanShared
import Foundation

enum HelperState: Equatable {
    case checking
    case notInstalled
    case outdated(installed: String)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
    /// States worth re-checking on their own; the others need the user to install or update.
    var canRetry: Bool {
        switch self {
        case .checking, .failed: true
        default: false
        }
    }
}

/// Talks to the privileged helper over XPC.
@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping @Sendable (Error) -> Void) -> FanHelperProtocol? {
        let conn = connection ?? makeConnection()
        return conn.remoteObjectProxyWithErrorHandler(onError) as? FanHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        conn.resume()
        connection = conn
        return conn
    }

    func reset() {
        connection?.invalidate()
        connection = nil
    }

    func installedVersion() async -> String? {
        guard FileManager.default.fileExists(atPath: HelperConstants.helperPath) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once(cont)
            Task {
                try? await Task.sleep(for: .seconds(2))
                once.resume(nil)
            }
            guard let p = proxy(onError: { _ in once.resume(nil) }) else { return once.resume(nil) }
            p.version { once.resume($0) }
        }
    }

    func setRPM(_ fan: Int, _ rpm: Double) async -> String? {
        await call { p, done in p.setFanRPM(fan, rpm: rpm, reply: done) }
    }

    func setAuto(_ fan: Int) async -> String? {
        await call { p, done in p.setFanAuto(fan, reply: done) }
    }

    func setAllAuto() async -> String? {
        await call { p, done in p.setAllAuto(reply: done) }
    }

    func heartbeat() {
        proxy(onError: { _ in })?.heartbeat()
    }

    /// Blocking version for app termination, where we can't await.
    func setAllAutoSynchronously() {
        guard let conn = connection,
              let p = conn.synchronousRemoteObjectProxyWithErrorHandler({ _ in }) as? FanHelperProtocol else { return }
        p.setAllAuto { _ in }
    }

    private func call(_ body: (FanHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once(cont)
            // A reply lost across sleep would otherwise hang the control loop forever.
            Task {
                try? await Task.sleep(for: .seconds(3))
                once.resume("The helper didn't respond")
            }
            guard let p = proxy(onError: { once.resume($0.localizedDescription) }) else {
                return once.resume("Helper unavailable")
            }
            body(p) { once.resume($0) }
        }
    }
}

/// Resumes a continuation at most once (XPC may call both the reply and the error handler).
private final class Once<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<T, Never>) { cont = c }
    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
