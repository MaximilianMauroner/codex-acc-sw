import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore
    let onHide: () -> Void
    let onQuit: () -> Void
    @State private var screen = PopoverScreen.usage

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                store: store,
                screen: screen,
                onShowUsage: { screen = .usage },
                onShowActions: { screen = .actions },
                onShowSettings: { screen = .settings },
                onShowAbout: { screen = .about },
                onHide: onHide
            )
            Divider()
            switch screen {
            case .usage:
                if let error = store.errorMessage, store.payload == nil {
                    ErrorState(message: error)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let error = store.errorMessage {
                                LiveRefreshWarning(message: error)
                            }
                            CostHistoryCard(store: store)
                            SummaryStrip(store: store)
                            AccountSection(
                                title: "Codex accounts",
                                accounts: store.codexAccounts,
                                store: store
                            )
                            if let claude = store.claudeAccount {
                                AccountSection(
                                    title: "Claude",
                                    accounts: [claude],
                                    store: store
                                )
                            }
                        }
                        .padding(14)
                    }
                }
            case .actions:
                ActionsScreen(store: store)
            case .settings:
                SettingsScreen(store: store)
            case .about:
                AboutScreen(onQuit: onQuit)
            }
        }
        .frame(width: 440, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct LiveRefreshWarning: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 3) {
                Text("Live refresh failed")
                    .font(.system(size: 12, weight: .semibold))
                Text("Showing cached usage. \(message)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .systemOrange).opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .systemOrange).opacity(0.45), lineWidth: 1)
        )
    }
}

private enum PopoverScreen {
    case usage
    case actions
    case settings
    case about
}

private struct HeaderView: View {
    @ObservedObject var store: UsageStore
    let screen: PopoverScreen
    let onShowUsage: () -> Void
    let onShowActions: () -> Void
    let onShowSettings: () -> Void
    let onShowAbout: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if screen == .usage, store.isRefreshing || store.isRefreshingCost {
                HeaderProgressIndicator()
            }
            if screen == .usage {
                HeaderIconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    store.refreshNow()
                }
                HeaderIconButton(systemName: "terminal", help: "Actions") {
                    onShowActions()
                }
                HeaderIconButton(systemName: "slider.horizontal.3", help: "Settings") {
                    onShowSettings()
                }
                HeaderIconButton(systemName: "info.circle", help: "About") {
                    onShowAbout()
                }
            } else {
                HeaderIconButton(systemName: "chevron.left", help: "Back") {
                    onShowUsage()
                }
            }
            HeaderIconButton(systemName: "xmark", help: "Hide") {
                onHide()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var title: String {
        switch screen {
        case .usage:
            return "AI Usage"
        case .actions:
            return "Actions"
        case .settings:
            return "Settings"
        case .about:
            return "About"
        }
    }

    private var subtitle: String {
        switch screen {
        case .usage:
            return "Updated \(store.lastUpdatedText)"
        case .actions:
            return "Codex commands"
        case .settings:
            return "Menu bar display"
        case .about:
            return AppInfo.versionLine
        }
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct HeaderProgressIndicator: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 24, height: 24)
    }
}

private struct SettingsScreen: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu bar")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Pick the paid usage rows shown in the closed title. Cached values stay available during refresh errors.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    let accounts = store.topBarSelectableAccounts
                    if accounts.isEmpty {
                        Text("No accounts have been loaded yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            TopBarToggleRow(account: account, store: store)
                            if index < accounts.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                )

                Text("Free or unavailable rows stay listed here for context. New paid rows are shown by default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }
}

private struct TopBarToggleRow: View {
    let account: UsageAccount
    @ObservedObject var store: UsageStore

    var body: some View {
        let canShow = store.canShowInTopBar(account)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(providerLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if account.isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(store.topBarPreviewValue(for: account))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(canShow ? .secondary : Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            TopBarStatusPill(text: statusText, tint: statusTint)
            Toggle("", isOn: Binding(
                get: { store.isTopBarVisible(account) },
                set: { store.setTopBarVisible(account, visible: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!canShow)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var providerLabel: String {
        account.isClaude ? "Claude" : "Codex"
    }

    private var statusText: String {
        if !store.canShowInTopBar(account) {
            if account.snapshot?.isFreePlan == true {
                return "Free"
            }
            if account.hasProblem {
                return "Unavailable"
            }
            return "No budget"
        }
        if !store.isTopBarVisible(account) {
            return "Hidden"
        }
        if account.stale || account.hasProblem {
            return "Cached"
        }
        return "Shown"
    }

    private var statusTint: Color {
        switch statusText {
        case "Shown":
            return Color(nsColor: .systemGreen)
        case "Hidden", "Free":
            return Color(nsColor: .secondaryLabelColor)
        case "Cached":
            return Color(nsColor: .systemOrange)
        default:
            return Color(nsColor: .systemRed)
        }
    }
}

private struct TopBarStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(tint.opacity(0.14))
            )
            .lineLimit(1)
    }
}

private struct ActionsScreen: View {
    @ObservedObject var store: UsageStore
    @State private var accountName = ""
    @State private var backupName = ""
    @State private var selectedAccountName = ""
    @State private var renameTarget = ""
    @State private var pendingLoginName: String?
    @State private var removeConfirmationName: String?
    @State private var commandOutput: AccountCommandOutput?
    @State private var isRunning = false

    private let runner = AccountCommandRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ActionSection(
                    title: "Codex accounts",
                    subtitle: "Switch the active auth file without leaving the menu."
                ) {
                    let accounts = store.codexAccounts
                    if accounts.isEmpty {
                        ActionEmptyState(text: "No saved Codex accounts are loaded yet.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                                CodexCommandAccountRow(
                                    account: account,
                                    isRunning: isRunning,
                                    onSwitch: {
                                        runCommand(
                                            ["switch", account.name],
                                            promptResponse: normalizedBackupName
                                        )
                                    }
                                )
                                if index < accounts.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    TextField("Unsaved current login backup name (if needed)", text: $backupName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning)
                    Text("Used by Switch and Prepare Login if the current login has not been saved yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                ActionSection(
                    title: "Add or save",
                    subtitle: "Prepare a new Codex login, then save it under the same name."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Account name", text: $accountName)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isRunning)
                        HStack(spacing: 8) {
                            Button {
                                let name = normalizedAccountName
                                runCommand(["save", name]) {
                                    accountName = ""
                                }
                            } label: {
                                Label("Save Current", systemImage: "tray.and.arrow.down")
                            }
                            .disabled(!canUseTypedName || isRunning)

                            Button {
                                let name = normalizedAccountName
                                runCommand(["add", name], promptResponse: normalizedBackupName) {
                                    pendingLoginName = name
                                }
                            } label: {
                                Label("Prepare Login", systemImage: "plus")
                            }
                            .disabled(!canUseTypedName || isRunning)
                        }
                        if let pendingLoginName {
                            HStack(spacing: 8) {
                                Text("Next: authenticate \(pendingLoginName).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    openLogin(accountName: pendingLoginName)
                                } label: {
                                    Label("Open Login", systemImage: "arrow.up.right.square")
                                }
                                .disabled(isRunning)
                            }
                        }
                        Text("Prepare Login removes the active Codex auth after saving the current one if it can be identified.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("If the current login is not already saved, its backup name is supplied to the command without an interactive Terminal prompt.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                ActionSection(
                    title: "Rename or remove",
                    subtitle: "Manage saved Codex auth files."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Account", selection: $selectedAccountName) {
                            ForEach(store.codexAccounts) { account in
                                Text(account.displayName).tag(account.name)
                            }
                        }
                        .disabled(store.codexAccounts.isEmpty || isRunning)

                        TextField("New name", text: $renameTarget)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!hasSelectedAccount || isRunning)

                        HStack(spacing: 8) {
                            Button {
                                let oldName = selectedAccountName
                                let newName = normalizedRenameTarget
                                runCommand(["rename", oldName, newName]) {
                                    selectedAccountName = newName
                                    renameTarget = ""
                                }
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .disabled(!canRename || isRunning)

                            Button(role: .destructive) {
                                if removeConfirmationName == selectedAccountName {
                                    let name = selectedAccountName
                                    runCommand(["remove", name]) {
                                        removeConfirmationName = nil
                                        selectedAccountName = store.codexAccounts.first { $0.name != name }?.name ?? ""
                                    }
                                } else {
                                    removeConfirmationName = selectedAccountName
                                }
                            } label: {
                                Label(removeConfirmationName == selectedAccountName ? "Confirm Remove" : "Remove", systemImage: "trash")
                            }
                            .disabled(!canRemove || isRunning)
                        }
                        Text("The active account cannot be removed until you switch away from it.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                ClaudeAuthSummary()

                if let commandOutput {
                    CommandOutputView(output: commandOutput)
                }
            }
            .padding(18)
        }
        .onAppear {
            if selectedAccountName.isEmpty {
                selectedAccountName = store.codexAccounts.first?.name ?? ""
            }
        }
        .onChange(of: store.codexAccounts.map(\.name)) { names in
            if !names.contains(selectedAccountName) {
                selectedAccountName = names.first ?? ""
            }
        }
    }

    private var normalizedAccountName: String {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedRenameTarget: String {
        renameTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedBackupName: String {
        let value = backupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidAccountName(value) ? value : ""
    }

    private var canUseTypedName: Bool {
        isValidAccountName(normalizedAccountName)
    }

    private var hasSelectedAccount: Bool {
        !selectedAccountName.isEmpty
    }

    private var canRename: Bool {
        hasSelectedAccount
            && isValidAccountName(normalizedRenameTarget)
            && normalizedRenameTarget != selectedAccountName
    }

    private var canRemove: Bool {
        guard hasSelectedAccount else { return false }
        return store.codexAccounts.first { $0.name == selectedAccountName }?.isActive != true
    }

    private func isValidAccountName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains(":")
            && name != "."
            && name != ".."
            && !["help", "-h", "--help"].contains(name.lowercased())
    }

    private func runCommand(
        _ arguments: [String],
        promptResponse: String? = nil,
        onSuccess: (() -> Void)? = nil
    ) {
        isRunning = true
        removeConfirmationName = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runner.run(arguments, promptResponse: promptResponse)
            DispatchQueue.main.async {
                commandOutput = result
                isRunning = false
                if result.succeeded {
                    onSuccess?()
                    store.refreshNow()
                }
            }
        }
    }

    private func openLogin(accountName: String) {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runner.openCodexLoginTerminal(accountName: accountName)
            DispatchQueue.main.async {
                commandOutput = result
                isRunning = false
            }
        }
    }
}

private struct ActionSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }
}

private struct CodexCommandAccountRow: View {
    let account: UsageAccount
    let isRunning: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(account.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if account.isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    }
                    if account.snapshot?.isFreePlan == true {
                        Text("Free")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(account.message.isEmpty ? account.statusLabel : account.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Switch", action: onSwitch)
                .disabled(account.isActive || isRunning)
        }
        .padding(.vertical, 8)
    }
}

private extension UsageAccount {
    var statusLabel: String {
        switch status {
        case "ok":
            return stale ? "Cached usage" : "Ready"
        case "missing_credentials", "missing_token", "unauthorized", "login_expired":
            return "Login needed"
        case "network_error":
            return "Network error"
        case "no_cache":
            return "Checking"
        default:
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct ActionEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct ClaudeAuthSummary: View {
    var body: some View {
        ActionSection(
            title: "Claude auth",
            subtitle: "Current finding, profile switching is not automated yet."
        ) {
            VStack(spacing: 0) {
                InfoRow(label: "Credential", value: "Keychain service: Claude Code-credentials")
                Divider()
                InfoRow(label: "Account", value: "Keychain account: macOS user")
                Divider()
                InfoRow(label: "Metadata", value: "~/.claude.json, oauthAccount")
                Divider()
                InfoRow(label: "Desktop", value: "~/Library/Application Support/Claude/config.json")
            }
            Text("A Claude profile switcher would need to save and restore the Keychain credential payload, plus account metadata if Claude Code depends on it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}

private struct CommandOutputView: View {
    let output: AccountCommandOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: output.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(output.succeeded ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed))
                Text(output.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(output.detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(output.succeeded ? Color(nsColor: .systemGreen).opacity(0.4) : Color(nsColor: .systemRed).opacity(0.5), lineWidth: 1)
        )
    }
}

private struct AboutScreen: View {
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppInfo.displayName)
                        .font(.system(size: 18, weight: .semibold))
                    Text(AppInfo.versionLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                AboutRow(label: "Bundle", value: AppInfo.bundleIdentifier)
                Divider()
                AboutRow(label: "Usage source", value: "codex-account-switch")
                Divider()
                AboutRow(label: "Cost source", value: "context-bar")
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            )

            Spacer()

            HStack {
                Button(role: .destructive) {
                    onQuit()
                } label: {
                    Label("Quit AI Usage Bar", systemImage: "power")
                }
                Spacer()
            }
        }
        .padding(18)
    }
}

private struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }
}

private enum AppInfo {
    static var displayName: String {
        bundleString("CFBundleDisplayName")
            ?? bundleString("CFBundleName")
            ?? "AI Usage Bar"
    }

    static var versionLine: String {
        "Version \(version) (\(build))"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier
            ?? bundleString("CFBundleIdentifier")
            ?? "unknown"
    }

    private static var version: String {
        bundleString("CFBundleShortVersionString") ?? "0.1.0"
    }

    private static var build: String {
        bundleString("CFBundleVersion") ?? "1"
    }

    private static func bundleString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

private struct CostHistoryCard: View {
    @ObservedObject var store: UsageStore
    @State private var selectedDayID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cost history")
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let history = store.costHistory {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(MoneyText.usd(history.totalCost))
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("30d total")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if store.isRefreshingCost {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let history = store.costHistory {
                if let error = store.costErrorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label("Refresh failed: \(error)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Retry") {
                            store.refreshCostHistory(force: true)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.isRefreshingCost)
                    }
                }
                let focusedDay = selectedDay(in: history)
                CostBarChart(history: history, selectedDayID: $selectedDayID)
                    .frame(height: 106)

                if let focusedDay {
                    CostDayBreakdown(day: focusedDay)
                }

                HStack(spacing: 0) {
                    CostMetric(label: "Today", value: MoneyText.usd(history.todayCost))
                    Divider().frame(height: 24)
                    CostMetric(label: "Daily avg", value: MoneyText.usd(history.totalCost / Double(max(1, history.days.count))))
                    Divider().frame(height: 24)
                    CostMetric(label: "Tokens", value: TokenText.compact(history.totalTokens))
                }

                Text(estimateText(for: history))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let error = store.costErrorMessage {
                CostUnavailableView(message: error) {
                    store.refreshCostHistory(force: true)
                }
            } else {
                CostLoadingView()
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }

    private var subtitle: String {
        if store.isRefreshingCost {
            return "Loading 30 days from context-bar"
        }
        if let history = store.costHistory {
            if store.costErrorMessage != nil {
                return "Refresh failed · cached \(TimeText.relativeAge(history.generatedAt))"
            }
            return "30 days · \(TimeText.relativeAge(history.generatedAt))"
        }
        return "30 days · estimated from local transcripts"
    }

    private func estimateText(for history: CostHistory) -> String {
        let pricing = history.pricingSource.map { " · pricing: \($0)" } ?? ""
        let estimate = history.pricingIsEstimate ? "Estimated" : "Calculated"
        return "\(estimate) by \(history.source)\(pricing)"
    }

    private func selectedDay(in history: CostHistory) -> CostDay? {
        history.days.first { $0.id == selectedDayID } ?? history.days.last
    }
}

private struct CostBarChart: View {
    let history: CostHistory
    @Binding var selectedDayID: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(history.days) { day in
                        StackedCostBar(
                            day: day,
                            maxCost: history.maxCost,
                            availableHeight: proxy.size.height,
                            isHovered: selectedDayID == day.id
                        )
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                selectedDayID = day.id
                            }
                        }
                        .onTapGesture {
                            selectedDayID = day.id
                        }
                        .help("\(DateText.day(day.date)): \(MoneyText.usd(day.cost)) · \(TokenText.compact(day.tokens)) tokens")
                    }
                }
            }
            HStack {
                if let first = history.days.first {
                    Text(DateText.shortDay(first.date))
                }
                Spacer()
                if let last = history.days.last {
                    Text(DateText.shortDay(last.date))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

private struct StackedCostBar: View {
    let day: CostDay
    let maxCost: Double
    let availableHeight: CGFloat
    let isHovered: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if day.cost > 0, !segments.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(segments.reversed().enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(height: segmentHeight(for: segment, totalHeight: barHeight))
                    }
                }
                .frame(height: barHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .overlay(selectionStroke)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.45))
                    .frame(height: 3)
                    .overlay(selectionStroke)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var barHeight: CGFloat {
        guard maxCost > 0, day.cost > 0 else {
            return 3
        }
        let scaled = CGFloat(day.cost / maxCost) * availableHeight
        return max(5, scaled)
    }

    private var segments: [CostStackSegment] {
        let entries = day.breakdown.map {
            CostStackSegment(
                name: $0.name,
                cost: $0.cost,
                color: BreakdownColor.color(for: $0.name)
            )
        }

        let representedCost = entries.reduce(0) { $0 + $1.cost }
        guard day.cost > representedCost + 0.01 else {
            return entries
        }

        return entries + [
            CostStackSegment(
                name: "Unattributed",
                cost: day.cost - representedCost,
                color: Color(nsColor: .tertiaryLabelColor).opacity(0.65)
            )
        ]
    }

    private var selectionStroke: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .stroke(isHovered ? Color(nsColor: .labelColor).opacity(0.86) : .clear, lineWidth: 1.4)
    }

    private func segmentHeight(for segment: CostStackSegment, totalHeight: CGFloat) -> CGFloat {
        guard day.cost > 0, segment.cost > 0 else { return 0 }
        return max(0.75, CGFloat(segment.cost / day.cost) * totalHeight)
    }
}

private struct CostStackSegment {
    let name: String
    let cost: Double
    let color: Color
}

private struct CostDayBreakdown: View {
    let day: CostDay

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(DateText.day(day.date))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(MoneyText.usd(day.cost)) · \(TokenText.compact(day.tokens)) tokens")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if day.breakdown.isEmpty {
                Text("No breakdown available")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(day.breakdown.enumerated()), id: \.offset) { _, entry in
                            CostBreakdownRow(entry: entry, totalCost: day.cost)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

private struct CostBreakdownRow: View {
    let entry: CostBreakdownEntry
    let totalCost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(BreakdownColor.color(for: entry.name))
                    .frame(width: 7, height: 7)
                Text(entry.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(MoneyText.usd(entry.cost))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Text("\(Int(share.rounded()))%")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 7) {
                Color.clear.frame(width: 7, height: 1)
                BudgetBar(value: share / 100, color: BreakdownColor.color(for: entry.name))
                    .frame(height: 4)
                Text(TokenText.compact(entry.tokens))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .help(helpText)
    }

    private var share: Double {
        guard totalCost > 0 else { return 0 }
        return max(0, min(100, (entry.cost / totalCost) * 100))
    }

    private var helpText: String {
        if entry.models.isEmpty {
            return "\(entry.name): \(MoneyText.usd(entry.cost))"
        }
        return "\(entry.name): \(MoneyText.usd(entry.cost)) · \(entry.models.joined(separator: ", "))"
    }
}

private struct CostMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }
}

private struct CostUnavailableView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 18))
                .foregroundStyle(Color(nsColor: .systemOrange))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cost history unavailable")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    onRetry()
                }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
    }
}

private struct CostLoadingView: View {
    private let heights: [CGFloat] = [
        0.28, 0.45, 0.36, 0.18, 0.62, 0.78, 0.52, 0.18, 0.14, 0.08,
        0.30, 0.22, 0.18, 0.16, 0.09, 0.12, 0.24, 0.18, 0.14, 0.20,
        0.22, 0.18, 0.12, 0.10, 0.16, 0.38, 0.48, 0.43, 0.31, 0.24
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(nsColor: .separatorColor).opacity(0.45))
                        .frame(height: max(4, 88 * height))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 88)
            Text("Preparing local cost history")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct SummaryStrip: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 10) {
            if let active = store.activeCodexAccount {
                SummaryTile(title: "Codex", account: active, store: store)
            }
            if let claude = store.claudeAccount {
                SummaryTile(title: "Claude", account: claude, store: store)
            }
        }
    }
}

private struct SummaryTile: View {
    let title: String
    let account: UsageAccount
    @ObservedObject var store: UsageStore

    var body: some View {
        let selection = BudgetPeriod.allCases
            .map { period in (period, store.pace(for: account, period: period)) }
            .max { $0.1.severity < $1.1.severity }
        let period = selection?.0 ?? .current
        let pace = selection?.1 ?? .learning
        let remaining = account.snapshot.flatMap { period.remaining(in: $0) }
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                PaceBadge(assessment: pace)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(TimeText.percent(remaining))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(period.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            BudgetBar(
                value: (remaining ?? 0) / 100,
                color: pace.severity.color
            )
            Text(pace.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

private struct AccountSection: View {
    let title: String
    let accounts: [UsageAccount]
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    AccountRow(account: account, store: store)
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: UsageAccount
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    if account.isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if account.isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if account.hasProblem {
                    Text(statusLabel(account.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(nsColor: .systemRed))
                } else {
                    PaceBadge(assessment: store.worstPace(for: account))
                }
            }

            if let message = account.message.nilIfEmpty, account.hasProblem {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let snapshot = account.snapshot {
                if snapshot.isFreePlan {
                    Text("Free plan")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    BudgetLine(account: account, period: .current, store: store)
                    BudgetLine(account: account, period: .weekly, store: store)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(account.isActive ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(account.isActive ? 0.8 : 0.45), lineWidth: 1)
        )
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "missing_credentials", "missing_token", "unauthorized", "login_expired":
            return "Login needed"
        case "network_error":
            return "Network"
        case "no_cache":
            return "Checking"
        default:
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct BudgetLine: View {
    let account: UsageAccount
    let period: BudgetPeriod
    @ObservedObject var store: UsageStore

    var body: some View {
        let snapshot = account.snapshot
        let remaining = snapshot.flatMap { period.remaining(in: $0) }
        let pace = store.pace(for: account, period: period)
        let values = store.historyValues(for: account, period: period)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(period.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                Text(TimeText.percent(remaining))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .leading)
                BudgetBar(value: (remaining ?? 0) / 100, color: pace.severity.color)
                Sparkline(values: values)
                    .stroke(pace.severity.color.opacity(values.count > 1 ? 0.95 : 0.25), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 58, height: 18)
                Text(TimeText.relativeReset(snapshot.flatMap { period.resetDate(in: $0) }, hideMinutesIfDays: period == .weekly))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Text("\(pace.label): \(pace.detail)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 34)
        }
    }
}

private struct BudgetBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(1, value)) * proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.32))
                Capsule()
                    .fill(color)
                    .frame(width: max(width, value > 0 ? 3 : 0))
            }
        }
        .frame(height: 7)
    }
}

private struct PaceBadge: View {
    let assessment: PaceAssessment

    var body: some View {
        Text(assessment.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(assessment.severity.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(assessment.severity.color.opacity(0.12))
            )
    }
}

private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        let points = values.suffix(48)
        guard points.count > 1 else {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }

        let normalized = points.map { max(0, min(100, $0)) }
        let step = rect.width / CGFloat(max(1, normalized.count - 1))
        var path = Path()
        for (index, value) in normalized.enumerated() {
            let x = rect.minX + CGFloat(index) * step
            let y = rect.maxY - CGFloat(value / 100) * rect.height
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

private struct ErrorState: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(message)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum MoneyText {
    static func usd(_ value: Double) -> String {
        if value >= 100 {
            return String(format: "$%.0f", value)
        }
        if value >= 10 {
            return String(format: "$%.1f", value)
        }
        return String(format: "$%.2f", value)
    }
}

private enum TokenText {
    static func compact(_ value: UInt64) -> String {
        let number = Double(value)
        if number >= 1_000_000_000 {
            return String(format: "%.1fB", number / 1_000_000_000)
        }
        if number >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return "\(value)"
    }
}

private enum DateText {
    static func day(_ date: Date) -> String {
        formatter(dateStyle: .medium).string(from: date)
    }

    static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func formatter(dateStyle: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .none
        return formatter
    }
}

private enum BreakdownColor {
    static func color(for name: String) -> Color {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "unattributed" || normalized == "other" {
            return Color(nsColor: .tertiaryLabelColor).opacity(0.65)
        }

        let hash = stableHash(normalized)
        let hue = Double(hash % 3_600) / 3_600
        let saturation = 0.58 + Double((hash >> 12) % 18) / 100
        let brightness = 0.74 + Double((hash >> 24) % 16) / 100
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
