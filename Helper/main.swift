import FanShared
import Foundation
import SMCKit

/// All SMC writes happen on this queue.
let queue = DispatchQueue(label: "fanhelper.smc")

final class FanService: NSObject, FanHelperProtocol, @unchecked Sendable {
    private let smc: SMC
    private let fanCount: Int
    private var manualFans: Set<Int> = []
    private var lastHeartbeat = Date()
    private var connections = 0
    private var watchdog: DispatchSourceTimer?

    init(smc: SMC) {
        self.smc = smc
        fanCount = Int(smc.number("FNum") ?? 0)
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        timer.resume()
        watchdog = timer
    }

    // MARK: Connection bookkeeping (called on `queue`)

    func connectionOpened() {
        connections += 1
        lastHeartbeat = Date()
    }

    func connectionClosed() {
        connections -= 1
        if connections <= 0 { restoreAll(reason: "client disconnected") }
    }

    private func checkWatchdog() {
        guard !manualFans.isEmpty, Date().timeIntervalSince(lastHeartbeat) > HelperConstants.watchdogTimeout else { return }
        restoreAll(reason: "watchdog timeout")
    }

    func restoreAll(reason: String, force: Bool = false) {
        guard force || !manualFans.isEmpty else { return }
        NSLog("FanHelper: restoring automatic control (\(reason))")
        for i in 0..<fanCount { try? setAuto(i) }
    }

    // MARK: SMC

    private var hasModeKeys: Bool { (try? smc.read("F0Md")) != nil }
    private var hasTestUnlock: Bool { (try? smc.read("Ftst")) != nil }

    private func setManual(_ i: Int, rpm: Double) throws {
        guard i >= 0, i < fanCount else { throw SMCError.keyNotFound("F\(i)") }
        let lo = smc.number("F\(i)Mn") ?? 0
        let hi = smc.number("F\(i)Mx") ?? 6000
        let target = rpm.isFinite ? min(max(rpm, lo), hi) : hi
        if !manualFans.contains(i) {
            // Newer Apple Silicon (M3+) locks fan writes behind Ftst; M1/M2 do not have it.
            if hasTestUnlock { try smc.write("Ftst", bytes: [1]) }
            if hasModeKeys {
                try writeWithRetry("F\(i)Md", bytes: [1])
            } else {
                let mask = Int(smc.number("FS! ") ?? 0) | (1 << i)
                try smc.write("FS! ", bytes: [UInt8(mask >> 8 & 0xff), UInt8(mask & 0xff)])
            }
            manualFans.insert(i)
        }
        try smc.write("F\(i)Tg", number: target)
    }

    private func setAuto(_ i: Int) throws {
        guard i >= 0, i < fanCount else { throw SMCError.keyNotFound("F\(i)") }
        if hasModeKeys {
            try smc.write("F\(i)Md", bytes: [0])
        } else {
            let mask = Int(smc.number("FS! ") ?? 0) & ~(1 << i)
            try smc.write("FS! ", bytes: [UInt8(mask >> 8 & 0xff), UInt8(mask & 0xff)])
        }
        manualFans.remove(i)
        if manualFans.isEmpty, hasTestUnlock { try? smc.write("Ftst", bytes: [0]) }
    }

    /// After an Ftst unlock the SMC can take a moment before it accepts mode changes.
    private func writeWithRetry(_ key: String, bytes: [UInt8]) throws {
        var lastError: Error?
        for _ in 0..<20 {
            do { return try smc.write(key, bytes: bytes) } catch { lastError = error }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw lastError!
    }

    // MARK: FanHelperProtocol

    func version(reply: @escaping @Sendable (String) -> Void) { reply(HelperConstants.version) }

    func setFanRPM(_ index: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            self.lastHeartbeat = Date()
            do { try self.setManual(index, rpm: rpm); reply(nil) } catch { reply("\(error)") }
        }
    }

    func setFanAuto(_ index: Int, reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do { try self.setAuto(index); reply(nil) } catch { reply("\(error)") }
        }
    }

    func setAllAuto(reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            var failure: String?
            for i in 0..<self.fanCount {
                do { try self.setAuto(i) } catch { failure = "\(error)" }
            }
            reply(failure)
        }
    }

    func heartbeat() {
        queue.async { self.lastHeartbeat = Date() }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: FanService
    init(service: FanService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.setCodeSigningRequirement(HelperConstants.clientRequirement)
        conn.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        conn.exportedObject = service
        let service = service
        conn.invalidationHandler = { queue.async { service.connectionClosed() } }
        queue.async { service.connectionOpened() }
        conn.resume()
        return true
    }
}

guard let smc = try? SMC() else {
    NSLog("FanHelper: cannot open AppleSMC")
    exit(1)
}
let service = FanService(smc: smc)
// A previous instance may have died with fans pinned; start from a known-safe state.
queue.async { service.restoreAll(reason: "launch", force: true) }
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// Never leave fans pinned when launchd stops us.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
term.setEventHandler {
    service.restoreAll(reason: "SIGTERM")
    exit(0)
}
term.resume()

NSLog("FanHelper \(HelperConstants.version) listening")
dispatchMain()
