import DurianCore
import SwiftUI

struct FingerprintsPage: View {
    let model: AppModel
    let go: (Page) -> Void

    @State private var pendingDelete: Int?
    @State private var confirmation = ""
    /// 正在编辑的指纹（改密码或改名）。两件事共用一个 sheet，
    /// 免得同一个视图上挂两个 `.sheet(item:)`。
    @State private var editing: EditTarget?

    private enum EditTarget: Identifiable {
        case password(Int)
        case rename(Int)

        var id: String {
            switch self {
            case .password(let id): return "password-\(id)"
            case .rename(let id): return "rename-\(id)"
            }
        }
    }

    private var ids: [Int] { model.fingerprints?.registeredIds ?? [] }

    private var blocker: LocalizedStringKey? {
        if !model.isReady { return "Connect the device to manage fingerprints." }
        if !model.hasStoredPassword { return "Set the unlock password first." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if ids.isEmpty {
                    ContentUnavailableView {
                        Label("No Fingerprints", systemImage: "touchid")
                    } description: {
                        Text(model.isReady ? "Add a fingerprint to unlock with a touch." : "Connect the device to see its fingerprints.")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(ids, id: \.self) { id in
                        FingerprintRow(
                            id: id,
                            name: model.displayName(for: id),
                            canEdit: model.isReady,
                            hasCustomPassword: model.hasCustomPassword(id),
                            flashing: model.flashingFingerprint == id,
                            editPassword: { editing = .password(id) },
                            rename: { editing = .rename(id) },
                            delete: { pendingDelete = id })
                    }
                }
            } header: {
                if let max = model.fingerprints?.maxFingerprint, !ids.isEmpty {
                    Text("Enrolled · \(ids.count) of \(max)")
                }
            }

            Section {
                HStack {
                    Button {
                        model.startEnroll()
                    } label: {
                        Label("Add Fingerprint", systemImage: "plus.circle.fill")
                    }
                    .disabled(blocker != nil || model.enroll.isBusy || model.isRebinding)

                    Spacer()

                    // 只有一个测试入口：测「任意已录入的手指」，由面板给出结果。
                    Button {
                        model.startFingerprintTest()
                    } label: {
                        Label("Test", systemImage: "hand.point.up.left")
                    }
                    .disabled(blocker != nil || model.enroll.isBusy || model.isRebinding
                              || model.fingerprintTest != nil)
                }
            } footer: {
                if let blocker {
                    HStack(spacing: 4) {
                        Text(blocker)
                        if model.isReady, !model.hasStoredPassword {
                            Button("Set Password") { go(.password) }.buttonStyle(.link)
                        }
                    }
                } else if model.isRebinding {
                    // 设备对密码写入的回包不带 id，两条链同时在飞会把结果认错。
                    Text("Still updating the enrolled fingerprints. Try again in a moment.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            switch target {
            case .password(let id):
                FingerprintPasswordSheet(model: model, id: id)
            case .rename(let id):
                FingerprintRenameSheet(model: model, id: id)
            }
        }
        .alert("Delete this fingerprint?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { reset() } }
        )) {
            if model.hasStoredPassword {
                SecureField("Unlock password", text: $confirmation)
            }
            Button("Delete", role: .destructive) {
                if let id = pendingDelete { model.deleteFingerprint(id, confirming: confirmation) }
                reset()
            }
            Button("Cancel", role: .cancel) { reset() }
        } message: {
            Text(model.hasStoredPassword
                 ? "Enter the unlock password to confirm. This cannot be undone."
                 : "This cannot be undone.")
        }
    }

    private func reset() {
        pendingDelete = nil
        confirmation = ""
    }
}

private struct FingerprintRow: View {
    let id: Int
    let name: String
    let canEdit: Bool
    let hasCustomPassword: Bool
    /// 刚被识别到，行背景闪几下。
    let flashing: Bool
    let editPassword: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "touchid", color: .pink, size: 28,
                      scale: 0.90, nudge: CGSize(width: -0.0043, height: 0.0043))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(hasCustomPassword ? "Has its own password" : "Uses the system password")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Password…", action: editPassword)
                .disabled(!canEdit)
            Button(action: rename) {
                Image(systemName: "pencil")
            }
            .help("Rename")
            .disabled(!canEdit)
            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .help("Delete")
            .disabled(!canEdit)
        }
        .padding(.vertical, 2)
        .background {
            // 识别到这一枚时整行闪几下；用中性灰而不是强调色，避免和「选中」混淆。
            // repeatForever 在 flashing 变回 false 时才停下，所以这里不做「闪几次」的计数，
            // 靠模型那边 2.4 秒后清标志。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(pulse ? 0.22 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        }
        .onChange(of: flashing, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) { pulse = false }
            }
        }
    }
}

/// 给指纹改名。名字只存在这台 Mac 上，设备那边仍然只有编号。
private struct FingerprintRenameSheet: View {
    let model: AppModel
    let id: Int

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Rename Fingerprint \(id)", systemImage: "pencil")
                .font(.headline)
            Text("The name is kept on this Mac only. The device stores fingerprints by number, so a name never travels with the reader.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear { input = model.fingerprintNames[String(id)] ?? "" }
    }

    private func save() {
        model.rename(id, to: input)
        dismiss()
    }
}

/// 给某枚指纹单独设置密码。锁屏时设备一律用系统密码，这个设置只在未锁屏、
/// 且前台有窗口在等密码时生效。
private struct FingerprintPasswordSheet: View {
    let model: AppModel
    let id: Int

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    private var invalid: Bool { !input.isEmpty && !PasswordPolicy.isValid(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fingerprint \(id)", systemImage: "touchid")
                .font(.headline)
            Text("When a window is asking for a password, this fingerprint types the password set here. At the lock screen the system password is always used.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $input)
                .textContentType(.password)

            if invalid {
                Text("Use printable ASCII only, up to \(PasswordPolicy.maxLength) characters.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                if model.hasCustomPassword(id) {
                    Button("Use the System Password") {
                        model.useSystemPassword(for: id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setCustomPassword(input, for: id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(input.isEmpty || invalid || !model.isReady)
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}

// MARK: - 录入弹窗

struct EnrollSheet: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            content
        }
        .padding(28)
        .frame(width: 360)
        .interactiveDismissDisabled(model.enroll.isBusy)
    }

    @ViewBuilder private var content: some View {
        switch model.enroll {
        case .idle:
            EmptyView()

        case .starting(let id):
            glyph("touchid", .accentColor, pulsing: true)
            titles(String(localized: "Enrolling Fingerprint \(id)"),
                   String(localized: "Place a finger on the sensor, lift it, then place it again."))
            dots(done: 0, total: model.fingerprints?.enrollTotalSteps ?? 6)
            Button("Cancel") { model.cancelEnroll() }.keyboardShortcut(.cancelAction)

        case .progress(let id, let step, let total):
            glyph("touchid", .accentColor, pulsing: true)
            titles(String(localized: "Enrolling Fingerprint \(id)"),
                   String(localized: "Step \(step) of \(total). Lift your finger, then place it again."))
            dots(done: step, total: total)
            Button("Cancel") { model.cancelEnroll() }.keyboardShortcut(.cancelAction)

        case .binding:
            glyph("key.fill", .orange, pulsing: true)
            titles(String(localized: "Linking the Password"),
                   String(localized: "Almost done."))
            ProgressView().controlSize(.small)

        case .done(let id):
            glyph("checkmark.circle.fill", .green)
            titles(String(localized: "Fingerprint \(id) Enrolled"),
                   String(localized: "Touch the sensor with this finger to unlock."))
            Button("Done") { model.closeEnroll() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .failed(let message):
            glyph("exclamationmark.triangle.fill", .orange)
            titles(String(localized: "Enrollment Did Not Finish"), message)
            HStack {
                Button("Close") { model.closeEnroll() }.keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    model.closeEnroll()
                    model.startEnroll()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func glyph(_ name: String, _ color: Color, pulsing: Bool = false) -> some View {
        StatusGlyph(systemName: name, color: color, size: 64, pulsing: pulsing)
    }

    private func titles(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dots(done: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<max(total, 1), id: \.self) { index in
                Circle()
                    .fill(index < done ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .animation(.easeOut(duration: 0.2), value: done)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(total)")
    }
}
