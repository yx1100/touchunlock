import DurianCore
import SwiftUI

struct OverviewPage: View {
    let model: AppModel
    let go: (Page) -> Void

    private var steps: [SetupStep] {
        let ready = model.isReady
        return [
            SetupStep(
                title: "Connect the device",
                detail: ready
                    ? String(localized: "\(model.deviceName ?? "Durian Touch") · firmware \(model.firmwareVersion ?? "…")")
                    : String(localized: "Power on the device and keep it near the Mac."),
                state: ready ? .done : .pending,
                action: ready ? nil : StepAction(title: "Connect") { model.reconnect() }),
            SetupStep(
                title: "Pair the Bluetooth keyboard",
                detail: model.keyboardLinked
                    ? String(localized: "macOS recognizes the device as a keyboard.")
                    : String(localized: "macOS has no keyboard for the device. Forget it in Bluetooth settings and pair it again."),
                state: model.keyboardLinked ? .done : (ready ? .warning : .pending),
                action: model.keyboardLinked ? nil : StepAction(title: "Bluetooth Settings…") { model.openBluetoothSettings() }),
            SetupStep(
                title: "Set the unlock password",
                detail: model.hasStoredPassword
                    ? String(localized: "Saved on the device and in this Mac's keychain.")
                    : String(localized: "Enter your Mac login password once."),
                state: model.hasStoredPassword ? .done : .pending,
                action: model.hasStoredPassword ? nil : StepAction(title: "Set Password") { go(.password) }),
            SetupStep(
                title: "Enroll a fingerprint",
                detail: model.fingerprintCount > 0
                    ? String(localized: "\(model.fingerprintCount) enrolled.")
                    : String(localized: "Enroll at least one finger."),
                state: model.fingerprintCount > 0 ? .done : .pending,
                action: model.fingerprintCount > 0 ? nil : StepAction(title: "Add Fingerprint") { go(.fingerprints) }),
        ]
    }

    private var allDone: Bool { steps.allSatisfy { $0.state == .done } }

    private var notice: LocalizedStringKey {
        "The device types the password only while this app is running. Keep it running and turn on Open at Login."
    }

    var body: some View {
        Form {
            Section { header }
            Section {
                ForEach(steps) { SetupRow(step: $0) }
            } header: {
                Text(allDone ? "Setup" : "Get Ready")
            }
            Section {
                Label {
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(Color.green)
                }
                // 已授权就换成一条确认，不再继续劝——重复提示只会让人当噪声划过去。
                if model.hasAccessibilityPermission {
                    Label {
                        Text("Device Control and Data Access is allowed.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(Color.green)
                    }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allow Device Control and Data Access so the app can tell when a window is asking for a password.")
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                Button("Allow…") { model.requestAccessibilityPermission() }
                                Button("Open System Settings…") { model.openAccessibilitySettings() }
                                    .buttonStyle(.link)
                            }
                        }
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(Color.orange)
                    }
                }
            } header: {
                Text("Good to Know")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 顶部状态

    @ViewBuilder private var header: some View {
        let state = model.bleState
        HStack(spacing: 14) {
            StatusGlyph(
                systemName: allDone && model.isReady ? "checkmark.seal.fill" : state.symbol,
                color: allDone && model.isReady ? .green : (model.isReady ? .accentColor : state.tint),
                pulsing: state.isWorking)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.title3.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            headerAction
        }
        .padding(.vertical, 4)
    }

    private var headline: String {
        if model.isReady { return allDone ? String(localized: "Ready to unlock") : String(localized: "Device connected") }
        return model.bleState.title
    }

    private var subtitle: String {
        switch model.bleState {
        case .ready:
            let left = steps.filter { $0.state != .done }.count
            return allDone ? String(localized: "Touch an enrolled finger to unlock.") : String(localized: "\(left) step(s) left.")
        case .searching, .connecting: return String(localized: "Make sure the device is powered on.")
        case .idle: return String(localized: "The app reconnects automatically.")
        case .unauthorized: return String(localized: "Allow Bluetooth for TouchUnlock in Privacy & Security.")
        case .poweredOff: return String(localized: "Turn Bluetooth on to connect.")
        case .unsupported: return String(localized: "This Mac cannot use Bluetooth Low Energy.")
        }
    }

    @ViewBuilder private var headerAction: some View {
        switch model.bleState {
        case .unauthorized:
            Button("Open Privacy Settings…") { model.openBluetoothPrivacySettings() }
        case .idle:
            Button("Connect") { model.reconnect() }.buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }
}

// MARK: - 准备清单

private struct StepAction {
    let title: LocalizedStringKey
    let run: () -> Void
    init(title: LocalizedStringKey, run: @escaping () -> Void) { self.title = title; self.run = run }
}

private struct SetupStep: Identifiable {
    enum State { case done, pending, warning }
    let title: LocalizedStringKey
    let detail: String
    let state: State
    let action: StepAction?
    var id: String { "\(title)" }
}

private struct SetupRow: View {
    let step: SetupStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(step.state == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let action = step.action {
                Button(action.title, action: action.run)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch step.state {
        case .done: return "checkmark.circle.fill"
        case .pending: return "circle"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch step.state {
        case .done: return .green
        case .pending: return .secondary
        case .warning: return .orange
        }
    }
}
