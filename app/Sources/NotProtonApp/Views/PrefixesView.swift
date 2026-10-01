// Prefix management UI inside NotProton, also see PrefixesModel

import SwiftUI

struct PrefixesView: View {

    @Environment(PrefixesModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Looking for prefixes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.prefixes.isEmpty {
                ContentUnavailableView(
                    "No Prefixes",
                    systemImage: "externaldrive",
                    description: Text(
                        "A prefix appears here once a Windows game has been launched through NotProton."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle("Prefixes")
        .safeAreaInset(edge: .bottom) {
            if let failed = model.report {
                report(
                    StatusRow(
                        title: "Failed",
                        value: failed.message,
                        tone: .bad,
                        action: failed.settingsPane.map { pane in
                            StatusAction(label: Remedy.settingsButton) { Remedy.openSettings(pane) }
                        }
                    )
                )
            } else if let outcome = model.outcome {
                report(
                    StatusRow(
                        title: "Done",
                        value: outcome,
                        tone: .ok
                    )
                )
            }
        }
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItemGroup(placement: .primaryAction) { strip }
                    .visibilityPriority(.high)
            } else {
                ToolbarItemGroup(placement: .primaryAction) { strip }
            }
        }
        .task { if model.prefixes.isEmpty { await model.load() } }
        .confirmationDialog(
            PrefixPrompt.deleteTitle(deleting),
            isPresented: asking(.delete),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.deleteButton(deleting), role: .destructive) {
                let targets = deleting
                model.pendingConfirmation = nil
                Task { await model.delete(targets) }
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(PrefixPrompt.deleteMessage(deleting))
        }
        .confirmationDialog(
            PrefixPrompt.rebuildTitle(rebuilding, for: rebuildTool),
            isPresented: asking(.rebuild),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.rebuildWithBackupButton(rebuilding)) {
                model.confirmRebuild()
            }
            .keyboardShortcut(.defaultAction)
            Button(PrefixPrompt.rebuildWithoutBackupButton(rebuilding)) {
                model.confirmRebuild(keepBackup: false)
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.rebuildMessage())
        }
        .confirmationDialog(
            PrefixPrompt.backUpTitle(backingUp),
            isPresented: asking(.backUp),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.backUpButton(backingUp)) {
                let targets = backingUp
                model.pendingConfirmation = nil
                Task { await model.backUp(targets) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.backUpMessage(backingUp))
        }
    }

    private enum Question {
        case delete, rebuild, backUp
    }

    private var deleting: [WinePrefix] {
        if case .delete(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuilding: [WinePrefix] {
        if case .rebuild(let targets, _) = model.pendingConfirmation { return targets }
        return []
    }

    private var rebuildTool: InstalledTool? {
        if case .rebuild(_, let tool) = model.pendingConfirmation { return tool }
        return nil
    }

    private var backingUp: [WinePrefix] {
        if case .backUp(let targets) = model.pendingConfirmation { return targets }
        return []
    }

    private func isAsking(_ question: Question) -> Bool {
        switch (question, model.pendingConfirmation) {
        case (.delete, .delete): true
        case (.rebuild, .rebuild(_, _)): true
        case (.backUp, .backUp): true
        default: false
        }
    }

    private func asking(_ question: Question) -> Binding<Bool> {
        Binding(
            get: { isAsking(question) },
            set: { shown in
                if !shown, isAsking(question) { model.pendingConfirmation = nil }
            }
        )
    }

    @ViewBuilder
    private var strip: some View {
        Menu {
            toolButtons(for: model.selectedPrefix)
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(model.selectedPrefix == nil || model.isBusy)
        .help("Run a program or open a Wine tool in the selected prefix.")

        Button("Reveal in Finder", systemImage: "folder") {
            if let prefix = model.selectedPrefix { model.reveal(prefix) }
        }
        .disabled(model.selectedPrefix == nil)
        .help("Show the selected prefix in the Finder.")

        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("List the prefixes again and update their sizes.")
    }

    private func lastUsed(_ prefix: WinePrefix) -> String {
        prefix.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "Never"
    }

    private var libraryWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(\.library.displayName)) ?? 120
    }

    private var toolWidth: CGFloat {
        TextWidth.widest(model.prefixes.compactMap(model.lastTool)) ?? 60
    }

    private var lastUsedWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(lastUsed)) ?? 110
    }

    private var gameWidth: CGFloat {
        let widths = model.prefixes.map { prefix -> CGFloat in
            var width = TextWidth.of(prefix.title)
            if model.isStale(prefix) { width += 22 }
            if prefix.name == nil {
                width += TextWidth.of("No longer installed", size: NSFont.smallSystemFontSize) + 6
            }
            return width
        }
        guard let widest = widths.max() else { return 240 }
        return widest + TextWidth.cellPadding
    }

    private var table: some View {
        @Bindable var model = model
        return Table(model.prefixes, selection: $model.selection) {
            TableColumn("Game") { prefix in
                HStack(spacing: 6) {
                    if model.isStale(prefix) {
                        Menu {
                            rebuildChoices([prefix])
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isBusy || model.tools.isEmpty)
                        .help(
                            "Last run by a build that is no longer set up, so the game cannot "
                                + "start. Click to rebuild the prefix."
                        )
                        .accessibilityLabel("Needs rebuilding")
                    }
                    Text(prefix.title).help(prefix.title)
                    if prefix.name == nil {
                        Text("No longer installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.busy.contains(prefix.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .width(min: 60, ideal: gameWidth)

            TableColumn("Tool") { prefix in
                if let tool = model.lastTool(prefix) {
                    Text(tool).foregroundStyle(.secondary).help(tool)
                } else {
                    Text("None")
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                }
            }
            .width(min: 60, ideal: toolWidth)

            TableColumn("App ID") { prefix in
                Text(prefix.appID).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("Library") { prefix in
                Text(prefix.library.displayName)
                    .foregroundStyle(.secondary)
                    .help(prefix.library.displayName)
            }
            .width(min: 44, ideal: libraryWidth)

            TableColumn("Size") { prefix in
                if let usage = model.usage[prefix.id] {
                    Text(usage.bytes.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Calculating…")
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                }
            }
            .width(min: 56, ideal: 90)

            TableColumn("Last used") { prefix in
                Text(lastUsed(prefix))
                    .foregroundStyle(.secondary)
                    .help(lastUsed(prefix))
            }
            .width(min: 60, ideal: lastUsedWidth)


        }
        .contextMenu(forSelectionType: WinePrefix.ID.self) { ids in
            actions(for: ids)
        }
        .onDeleteCommand {
            let targets = model.selectedPrefixes
            if !model.isBusy, !targets.isEmpty {
                model.pendingConfirmation = .delete(targets)
            }
        }
    }

    @ViewBuilder
    private func actions(for ids: Set<WinePrefix.ID>) -> some View {
        let targets = model.prefixes.filter { ids.contains($0.id) }
        Group {
            if let prefix = single(ids) {
                toolButtons(for: prefix)
                Divider()
                Button("Reveal in Finder") { model.reveal(prefix) }
            }
            if !targets.isEmpty {
                Divider()
                Button(PrefixPrompt.backUpButton(targets)) {
                    model.pendingConfirmation = .backUp(targets)
                }
                if model.tools.count > 1 {
                    Menu(PrefixPrompt.rebuildButton(targets)) { rebuildChoices(targets) }
                } else {
                    rebuildChoices(targets, label: PrefixPrompt.rebuildButton(targets))
                }
                Button(PrefixPrompt.deleteButton(targets), role: .destructive) {
                    model.pendingConfirmation = .delete(targets)
                }
            }
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private func rebuildChoices(_ targets: [WinePrefix], label: String? = nil) -> some View {
        ForEach(model.tools) { tool in
            Button(label ?? tool.display) {
                model.pendingConfirmation = .rebuild(targets, tool)
            }
        }
    }

    @ViewBuilder
    private func toolButtons(for prefix: WinePrefix?) -> some View {
        Button("Run Program…") {
            if let prefix { model.chooseExecutable(for: prefix) }
        }
        Divider()
        ForEach(WineTool.allCases, id: \.self) { tool in
            Button(tool.label) {
                if let prefix { model.open(tool, for: prefix) }
            }
        }
    }

    private func single(_ ids: Set<WinePrefix.ID>) -> WinePrefix? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.prefixes.first { $0.id == id }
    }

    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
