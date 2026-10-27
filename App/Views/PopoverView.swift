import FanCore
import SMCKit
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appActions) private var actions

    var body: some View {
        VStack(spacing: 12) {
            header
            if !model.hardwareAvailable {
                Card { Label("Can't read the SMC on this Mac.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            HelperBanner()
            if let err = model.lastError { ErrorBanner(message: err) }
            ProfileChips()
            ForEach(model.fans) { fan in FanCard(fan: fan) }
            SensorStrip()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            SpinningFan(rpm: model.averageRPM, size: 22, tint: Theme.color(forLoad: model.fanLoad))
            VStack(alignment: .leading, spacing: 0) {
                Text("Fan Control").font(.headline)
                Text(model.activeProfile?.name ?? (model.config.liveModes.values.allSatisfy { $0 == .auto } ? "System control" : "Custom"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let t = model.sensorsByID["cpu.max"]?.celsius {
                VStack(alignment: .trailing, spacing: 0) {
                    RollingNumber(value: t, threshold: 1, size: 26, color: Theme.color(forCelsius: t)) { model.format($0) }
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                actions?.openMain(nil)
            } label: {
                Label("Open Fan Control", systemImage: "macwindow")
            }
            .buttonStyle(.glass)
            Spacer()
            Button {
                model.resetAllToAuto()
            } label: {
                Label("All Auto", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.glass)
            .help("Hand every fan back to macOS")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .help("Quit Fan Control (fans return to automatic)")
        }
        .controlSize(.regular)
    }
}

/// Profile switcher: a grid of tiles that wraps instead of scrolling, so every profile is visible.
struct ProfileChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 110), spacing: 6)], spacing: 6) {
            ForEach(model.config.profiles) { p in
                ProfileTile(profile: p, active: p.id == model.config.activeProfileID) { model.apply(p) }
            }
        }
        .help("Cycle profiles with \(HotKey.displayString)")
    }
}

private struct ProfileTile: View {
    let profile: Profile
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(profile.name)
                    .font(.caption2.weight(active ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary.opacity(hovering ? 1.6 : 1)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct FanCard: View {
    @Environment(AppModel.self) private var model
    let fan: FanInfo

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    SpinningFan(rpm: fan.currentRPM, size: 15)
                    Text(fan.name).font(.subheadline.weight(.semibold))
                    Spacer()
                    RollingNumber(value: fan.currentRPM, threshold: 50, size: 15) { (($0 / 10).rounded() * 10).rpmString }
                    Text("RPM").font(.caption2).foregroundStyle(.secondary)
                }
                RPMBar(fan: fan)
                HStack {
                    Text(fan.minRPM.rpmString)
                    Spacer()
                    if fan.isManual { Text("target \(fan.targetRPM.rpmString)") }
                    Spacer()
                    Text(fan.maxRPM.rpmString)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                FanModeEditor(fan: fan, mode: model.mode(for: fan.index), compact: true) {
                    model.setMode($0, for: fan.index)
                }
            }
        }
    }
}

struct SensorStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appActions) private var actions

    var body: some View {
        Card(padding: 10) {
            VStack(spacing: 6) {
                ForEach(model.pinnedSensors) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.group.symbol)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(s.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 8)
                        Sparkline(samples: model.sensorSamples(s.id, last: 300), color: Theme.color(forCelsius: s.celsius))
                            .frame(width: 70, height: 18)
                        Text(model.format(s.celsius))
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(Theme.color(forCelsius: s.celsius))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Button {
                    actions?.openMain(.sensors)
                } label: {
                    Text("All \(model.sensors.count) sensors")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.link)
            }
        }
    }
}

struct HelperBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let wantsManual = model.fans.contains { model.mode(for: $0.index) != .auto }
        switch model.helperState {
        case .ready where model.helperUpdateAvailable:
            Card {
                HStack {
                    Label("A newer helper is available.", systemImage: "arrow.down.circle").font(.callout)
                    Spacer()
                    Button(model.installing ? "Updating…" : "Update") { model.installHelper() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.installing)
                }
            }
        case .ready, .checking:
            EmptyView()
        case .notInstalled where !wantsManual:
            EmptyView()
        default:
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: "lock.shield").font(.callout.weight(.semibold))
                    Text("Reading temperatures works without it. Changing fan speed needs a small helper that runs as root. You'll be asked for your password once.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.installing ? "Installing…" : "Install Helper") { model.installHelper() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.installing)
                }
            }
        }
    }

    private var title: String {
        switch model.helperState {
        case .outdated: "Helper update required"
        case .failed: "Helper not responding"
        default: "Install the fan helper"
        }
    }
}

struct ErrorBanner: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
