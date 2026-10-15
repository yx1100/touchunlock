import DurianCore
import SwiftUI

struct PasswordPage: View {
    let model: AppModel
    @State private var input = ""

    private var invalid: Bool { !input.isEmpty && !PasswordPolicy.isValid(input) }
    private var canSave: Bool { !input.isEmpty && !invalid && model.isReady }

    var body: some View {
        Form {
            Section {
                // 输入框和保存按钮同一行：这是页面上唯一的主动作，不需要额外的行。
                HStack(spacing: 10) {
                    SecureField("Mac login password", text: $input)
                        .textContentType(.password)
                        .onSubmit(save)
                    Button("Save to Device", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }

                if invalid {
                    Label("Use printable ASCII only, up to \(PasswordPolicy.maxLength) characters.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else if !model.isReady {
                    Label("Connect the device to save a password.", systemImage: "bolt.horizontal.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Unlock Password")
            } footer: {
                Text("The device stores the password and types it after a fingerprint match. Saving also updates every enrolled fingerprint.")
            }

            Section {
                LabeledContent {
                    if model.hasStoredPassword {
                        Button("Remove Copy", role: .destructive) { model.removeStoredPassword() }
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                } label: {
                    Label {
                        Text("Copy in this Mac's keychain")
                    } icon: {
                        Image(systemName: model.hasStoredPassword ? "key.fill" : "key")
                            .foregroundStyle(model.hasStoredPassword ? Color.orange : Color.secondary)
                    }
                }
            } header: {
                Text("On This Mac")
            } footer: {
                Text("Used to link new fingerprints automatically and to confirm deleting one. It never leaves this Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        guard canSave else { return }
        model.setPassword(input)
        input = ""
    }
}
