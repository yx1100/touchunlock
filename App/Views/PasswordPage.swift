import DurianCore
import SwiftUI

struct PasswordPage: View {
    let model: AppModel
    @State private var input = ""
    /// 明文显示开关。设错密码的后果是设备输入错误密码、解锁静默失败，
    /// 所以留一个可主动打开的核对入口。
    @State private var reveal = false
    @State private var confirmRemove = false

    private var invalid: Bool { !input.isEmpty && !PasswordPolicy.isValid(input) }
    private var canSave: Bool { !input.isEmpty && !invalid && model.isReady }

    var body: some View {
        Form {
            Section { status }

            Section {
                // 字段独占一行。Form 会把它按「设置项的值」渲染成尾对齐，输入时文字
                // 从右边往左长；这一点暂时按现状接受。
                Group {
                    if reveal {
                        TextField("Mac login password", text: $input)
                    } else {
                        SecureField("Mac login password", text: $input)
                    }
                }
                .textContentType(.password)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onSubmit(save)

                // macOS 上渲染为复选框，对应系统设置里密码框下的「显示密码」。
                Toggle("Show Password", isOn: $reveal)

                // 提示只在有话说时占一行，不影响上面的字段。
                hint

                HStack {
                    Spacer()
                    Button("Save to Device", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSave)
                }
            } header: {
                Text("Unlock Password")
            } footer: {
                Text("Stored on the device and typed after a fingerprint match. Saving also updates every enrolled fingerprint.")
            }

            Section {
                LabeledContent {
                    if model.hasStoredPassword {
                        Button("Remove Copy", role: .destructive) { confirmRemove = true }
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
                Text("Links new fingerprints and confirms deletions. It never leaves this Mac.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the copy from this Mac?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Copy", role: .destructive) { model.removeStoredPassword() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New fingerprints will no longer link automatically, and deleting one will no longer ask for the password.")
        }
    }

    /// 顶部状态：进页面第一眼就能看出解锁密码设置了没有。
    @ViewBuilder private var status: some View {
        HStack(spacing: 14) {
            StatusGlyph(systemName: model.hasStoredPassword ? "key.fill" : "key",
                        color: model.hasStoredPassword ? .green : .orange,
                        size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasStoredPassword ? "Unlock password set" : "Unlock password not set")
                    .font(.title3.weight(.semibold))
                Text(model.hasStoredPassword
                     ? String(localized: "Saved on the device and in this Mac's keychain.")
                     : String(localized: "Enter your Mac login password once."))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var hint: some View {
        if invalid {
            Label("Use printable ASCII only, up to \(PasswordPolicy.maxLength) characters.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.isReady {
            Label("Connect the device to save a password.", systemImage: "bolt.horizontal.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard canSave else { return }
        model.setPassword(input)
        input = ""
        reveal = false
    }
}
