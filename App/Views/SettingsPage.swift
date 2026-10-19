import DurianCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPage: View {
    let model: AppModel
    @State private var confirmForget = false
    /// 配对指引默认折叠。
    @State private var showPairingHelp = false

    var body: some View {
        Form {
            Section {
                Label("The device types the password only while this app is running.", systemImage: "checkmark.shield.fill")
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
                        Text("Already denied once?")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Lets the app tell when a window is asking for a password. Without it only secure password prompts are recognized.")
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
                Text("A panel appears after the device types a password or a manual test runs. The reader's light blinks while a window is asking for a password.")
            }

            Section {
                ForEach(model.ignoredApps, id: \.self) { id in
                    LabeledContent {
                        Button("Remove") { model.removeIgnoredApp(id) }
                    } label: {
                        ignoredAppLabel(id)
                    }
                }
                Button("Add App…") { chooseIgnoredApp() }
            } header: {
                Text("Ignored Apps")
            } footer: {
                Text("The device does not type a password while one of these apps is in front. The lock screen is not affected.")
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
                    Button("Search Again") { confirmForget = true }
                } label: {
                    Label("Search for the Device Again", systemImage: "arrow.clockwise")
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Use this when the app cannot find the device, for example after pairing it again in Bluetooth settings. Nothing on the device is erased.")
            }

            Section {
                LabeledContent {
                    Button("Pair") { model.pairDevice() }
                        .disabled(!model.isReady)
                } label: {
                    Label("Pair with This Mac", systemImage: "link")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Needed only when the reader has to learn this Mac again, for example after it was forgotten in Bluetooth settings.")
            }

            // 用可折叠 Section 而不是 DisclosureGroup：后者的内容会被缩进到标签列下方，
            // 只剩正文一半的宽度，中英文长句都要折行。Section 展开后是标准表单行，占满宽度。
            Section(isExpanded: $showPairingHelp) {
                pairingStep(1, "Press and hold the button on the reader for 3 seconds.")
                pairingStep(2, "The light blinks quickly to confirm pairing mode.")
                pairingStep(3, "Pairing mode lasts about a minute; a short press ends it early.")
                Label("Pairing replaces the device this reader was bound to before.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.orange.opacity(0.10))
            } header: {
                Label("Enter Pairing Mode", systemImage: "light.beacon.max")
            }

            Section {
                privacyRow("wifi.slash", "No network access. The app contains no networking code.")
                privacyRow("antenna.radiowaves.left.and.right", "Bluetooth is the only permission it requests.")
                privacyRow("key.fill", "The password copy stays in this Mac's keychain.")
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
        .confirmationDialog("Search for the device again?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Search Again") { model.forgetDevice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app restarts its search. Nothing on the device is erased.")
        }
    }

    private func ignoredAppLabel(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return Label {
            Text(verbatim: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
        } icon: {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable().frame(width: 20, height: 20)
        }
    }

    private func chooseIgnoredApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = String(localized: "Choose an app to ignore")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(model.addIgnoredApp(at:))
    }

    private func privacyRow(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.green)
        }
    }

    /// 配对步骤：编号用圆形徽标，比单纯的右对齐数字更清楚，也不会随行宽错位。
    private func pairingStep(_ index: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(index)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.14)))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
