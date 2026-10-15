import DurianCore
import SwiftUI

struct SettingsPage: View {
    let model: AppModel
    @State private var confirmForget = false
    /// 配对指引默认折叠。
    @State private var showPairingHelp = false

    var body: some View {
        Form {
            Section {
                Label("The device types the password only while this app is running. When the app is not running, touching the sensor does nothing.", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.secondary)
            } header: {
                Text("How It Works")
            }

            Section {
                LabeledContent {
                    if model.hasAccessibilityPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") { model.requestAccessibilityPermission() }
                    }
                } label: {
                    Label("Device Control and Data Access", systemImage: "lock.shield")
                }
                if !model.hasAccessibilityPermission {
                    LabeledContent {
                        Button("Open System Settings…") { model.openAccessibilitySettings() }
                    } label: {
                        Text("Already said no once?")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("TouchUnlock reads whether the frontmost window is asking for a password, so the reader types only when there is somewhere to type. Without this permission it can still notice secure password prompts, but not every password field. You will find the switch in System Settings → Privacy & Security → Device Control and Data Access.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.showHUD }, set: { model.showHUD = $0 })) {
                    Label("Show On-Screen Notifications", systemImage: "bell.badge")
                }
                Toggle(isOn: Binding(get: { model.showIndicator }, set: { model.showIndicator = $0 })) {
                    Label("Pulse the Reader's Light", systemImage: "light.beacon.max")
                }
            } header: {
                Text("Feedback")
            } footer: {
                Text("A small panel appears at the top of the screen after the device types a password, and after a manual test from the Fingerprints page. The reader's light blinks slowly while a window is asking for a password, so you know the reader will type when you touch it.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin)) {
                    Label("Open at Login", systemImage: "power")
                }
                Toggle(isOn: Binding(get: { model.showDockIcon }, set: model.setShowDockIcon)) {
                    Label("Show in Dock", systemImage: "dock.rectangle")
                }
            } header: {
                Text("General")
            } footer: {
                Text("When the Dock icon is hidden, the app stays in the menu bar.")
            }

            Section {
                LabeledContent {
                    Button("Open…") { model.openBluetoothSettings() }
                } label: {
                    Label("Bluetooth Settings", systemImage: "wave.3.right")
                }
                LabeledContent {
                    Button("Forget", role: .destructive) { confirmForget = true }
                } label: {
                    Label("Forget This Device", systemImage: "link.badge.plus")
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Forgetting only makes the app look for a device again. It does not erase anything on the device.")
            }

            Section {
                LabeledContent {
                    Button("Pair") { model.pairDevice() }
                        .disabled(!model.isReady)
                } label: {
                    Label("Pair with This Mac", systemImage: "link")
                }

                // 折叠起来：配对是一次性设置，平时不该占着版面。
                DisclosureGroup(isExpanded: $showPairingHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        pairingStep(1, "Press and hold the button on the reader for more than 3 seconds.")
                        pairingStep(2, "The light starts blinking quickly, which means it is in pairing mode.")
                        pairingStep(3, "Pairing mode lasts about a minute, and a short press ends it early.")
                        Label("Pairing again replaces the device this reader was bound to before.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    .padding(.leading, 2)
                } label: {
                    Label("Enter Pairing Mode", systemImage: "light.beacon.max")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Only needed when the reader has to learn this Mac again, for example after forgetting it in Bluetooth settings.")
            }

            Section {
                privacyRow("wifi.slash", "No network access. The app has no networking code.")
                privacyRow("antenna.radiowaves.left.and.right", "Bluetooth is the only permission it asks for.")
                privacyRow("key.fill", "The password copy stays in the keychain of this Mac.")
                privacyRow("text.alignleft", "The log never contains passwords.")
            } header: {
                Text("Privacy")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.appVersion)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Device", role: .destructive) { model.forgetDevice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app will search for a device again.")
        }
    }

    private func privacyRow(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.green)
        }
    }

    /// 配对步骤：编号与正文按第一行基线对齐，编号列定宽，多行文本不缩进错位。
    private func pairingStep(_ index: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(index)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 10, alignment: .trailing)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
