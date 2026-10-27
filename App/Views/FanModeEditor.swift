import FanCore
import SMCKit
import SwiftUI

/// Edits a fan's mode. Used in the popover (compact) and the main window.
struct FanModeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appActions) private var actions
    let fan: FanInfo
    let mode: FanMode
    var compact = false
    let onChange: (FanMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { mode.kind }, set: { onChange(defaultMode(for: $0)) })) {
                ForEach(FanMode.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            switch mode {
            case .auto:
                Label("macOS is controlling this fan.", systemImage: "apple.logo")
                    .font(.caption).foregroundStyle(.secondary)
            case .fixed(let rpm):
                fixedEditor(rpm)
            case .sensor(let id, let low, let high):
                sensorEditor(id: id, low: low, high: high)
            case .curve(let id, let curve):
                curveEditor(id: id, curve: curve)
            }
        }
    }

    private func fixedEditor(_ rpm: Double) -> some View {
        FixedRPMSlider(rpm: rpm.clamped(fan.minRPM, fan.maxRPM), range: fan.minRPM...max(fan.maxRPM, fan.minRPM + 1)) {
            onChange(.fixed(rpm: $0))
        }
    }

    private func sensorEditor(id: String, low: Double, high: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SensorPickerRow(selection: id, context: mode.hashValue) { onChange(.sensor(sensorID: $0, lowTemp: low, highTemp: high)) }
            HStack {
                tempStepper("Ramp up from", value: low, range: 20...(high - 5)) { onChange(.sensor(sensorID: id, lowTemp: $0, highTemp: high)) }
                Spacer()
                tempStepper("Max at", value: high, range: (low + 5)...110) { onChange(.sensor(sensorID: id, lowTemp: low, highTemp: $0)) }
            }
            .font(.caption)
        }
    }

    private func tempStepper(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping @MainActor (Double) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: range, step: 1) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(.secondary)
                Text(model.format(value)).monospacedDigit().fontWeight(.medium)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func curveEditor(id: String, curve: FanCurve) -> some View {
        SensorPickerRow(selection: id, context: mode.hashValue) { onChange(.curve(sensorID: $0, curve: curve)) }
        let temp = model.sensorsByID[id]?.celsius
        if compact {
            Button {
                actions?.openMain(.fans)
            } label: {
                CurveThumbnail(curve: curve, currentTemp: temp)
                    .frame(height: 44)
                    .overlay(alignment: .topTrailing) {
                        Label("Edit", systemImage: "pencil").font(.caption2).labelStyle(.iconOnly)
                            .padding(4).background(.thinMaterial, in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .help("Edit curve in the Fan Control window")
        } else {
            CurveEditor(curve: curve, onChange: { onChange(.curve(sensorID: id, curve: $0)) },
                        currentTemp: temp, limits: FanLimits(min: fan.minRPM, max: fan.maxRPM), unit: model.config.unit)
        }
    }

    private func defaultMode(for kind: FanMode.Kind) -> FanMode {
        let sensor = mode.sensorID ?? "cpu.max"
        switch kind {
        case .auto: return .auto
        case .fixed: return .fixed(rpm: ((fan.currentRPM.clamped(fan.minRPM, fan.maxRPM)) / 50).rounded() * 50)
        case .sensor: return .sensor(sensorID: sensor, lowTemp: 50, highTemp: 85)
        case .curve: return .curve(sensorID: sensor, curve: .balanced)
        }
    }
}

/// RPM slider that tracks the mouse locally and commits to the model at most 5×/s while dragging,
/// plus once on release, so dragging stays fluid.
private struct FixedRPMSlider: View {
    let rpm: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void

    @State private var draft: Double?
    @State private var lastCommit = Date.distantPast

    var body: some View {
        let value = draft ?? rpm
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Target").foregroundStyle(.secondary)
                Spacer()
                Text("\(value.rpmString) RPM").monospacedDigit().fontWeight(.medium)
            }
            .font(.caption)
            Slider(value: Binding(get: { value }, set: { v in
                let snapped = (v / 50).rounded() * 50
                draft = snapped
                if Date().timeIntervalSince(lastCommit) > 0.2 {
                    lastCommit = Date()
                    commit(snapped)
                }
            }), in: range) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "tortoise").font(.caption2)
            } maximumValueLabel: {
                Image(systemName: "hare").font(.caption2)
            } onEditingChanged: { editing in
                if !editing, let d = draft {
                    commit(d)
                    draft = nil
                }
            }
        }
    }
}
