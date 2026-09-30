// Logic behind Status view

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum AppVersion {
    static let fallback = "0.1.0-dev"

    static var bundled: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }
}

struct StatusSnapshot: Sendable {
    var steam: SteamDeployment
    var steamRunning: Bool
    var updateBlocked: Bool
    var crossOver: [CrossOverInstall]
    var crossOverLicense: [String: CrossOverLicense.Status] = [:]
    var runner: RunnerState
    var payload: PayloadState
    var installedRunners: [RunnerBuild] = []
    var orphanedRunners: [String] = []
    var damagedRunners: [String] = []

    static func capture(bundledVersion: String) -> StatusSnapshot {
        let installs = CrossOverSource.discover()
        var licenses: [String: CrossOverLicense.Status] = [:]
        for install in installs where install.isUsable {
            licenses[install.id] = CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }

        let runner = RunnerStore.state()
        let installed = RunnerStore.installedBuilds()

        return StatusSnapshot(
            steam: SteamBundle.deployment(bundledVersion: bundledVersion),
            steamRunning: SteamBundle.isRunning,
            updateBlocked: UpdateBlock.isPresent(),
            crossOver: installs,
            crossOverLicense: licenses,
            runner: runner,
            payload: PayloadInspector.inspect(builds: installed),
            installedRunners: installed,
            orphanedRunners: RunnerStore.orphanedClones(),
            damagedRunners: RunnerStore.damagedClones()
        )
    }
}

@MainActor
@Observable
final class SystemStatus {

    var snapshot: StatusSnapshot?
    var isRefreshing = false
    var activity: String?
    var outcome: String?
    private(set) var failure: String?
    private(set) var failureRemedy: Remedy?

    private var runInFlight = false
    // Tests replace the refresh so a run does not modify the real Steam/support folders
    // if run on an actual user's machine.
    @ObservationIgnored var refreshAfterRun: @MainActor (SystemStatus) async -> Void = { await $0.refresh() }
    private var checkingLicense = false

    var isBusy: Bool { activity != nil || runInFlight || checkingLicense }
    var isIdle: Bool { !isBusy && !isRefreshing }

    enum Confirmation: Identifiable, Hashable {
        case replaceSteam
        case blockUpdates
        case installUnlicensed
        case toolUnlicensed
        case removeBuild
        case removeEverything

        var id: Self { self }
    }

    var pendingConfirmation: Confirmation?
    var generation = 0

    func beginRun(_ label: String) -> Int {
        activity = label
        AppLog.note("run begin: \(label)")
        return generation
    }

    func report(_ run: Int, _ label: String) {
        guard run == generation else { return }
        activity = label
        AppLog.note("run step: \(label)")
    }

    func endRun() {
        generation += 1
        activity = nil
        AppLog.note("run end\(failure == nil ? "" : " (failed)")")
    }

    private func record(_ error: Error) {
        setFailure(error)
        if let refusal = error as? WriteRefused {
            AppLog.note("run failed: cannot write \(refusal.path)")
        } else {
            AppLog.note("run failed: \(error.localizedDescription)")
        }
    }

    func setFailure(_ message: String) {
        failure = message
        failureRemedy = nil
    }

    func setFailure(_ error: Error) {
        let report = FailureReport([error])
        failure = report?.message
        failureRemedy = report?.remedy
    }

    func clearFailure() {
        failure = nil
        failureRemedy = nil
    }

    var usableCrossOver: CrossOverInstall? {
        snapshot?.crossOver.first(where: \.isUsable)
    }

    var usableCrossOvers: [CrossOverInstall] {
        snapshot?.crossOver.filter(\.isUsable) ?? []
    }

    var crossOverRows: [CrossOverRow] {
        guard let snapshot else { return [] }
        var unpatched: [String] = []
        if case .unpatched(let builds, _) = snapshot.runner { unpatched = builds }
        return CrossOverRow.rows(
            installs: snapshot.crossOver,
            licenses: snapshot.crossOverLicense,
            installed: snapshot.installedRunners,
            damaged: snapshot.damagedRunners,
            orphaned: snapshot.orphanedRunners,
            unpatched: unpatched
        )
    }

    var repairSource: CrossOverInstall? {
        let builds = snapshot?.runner.builds ?? []
        for wanted in builds {
            let found = usableCrossOvers.first { install in
                if case .supported(let build) = install.support { return build.id == wanted }
                return false
            }
            if let found { return found }
        }
        return nil
    }

    var setupSource: CrossOverInstall? { repairSource ?? usableCrossOver }

    func checkLicense(for chosen: CrossOverInstall? = nil) async -> CrossOverLicense.Status? {
        guard let install = chosen ?? usableCrossOver else { return nil }
        let status = await Task.detached(priority: .userInitiated) {
            CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        }.value
        snapshot?.crossOverLicense[install.id] = status
        return status
    }

    enum Request {
        case install
        case compatibilityTool
    }

    nonisolated static func activationQuestion(
        _ request: Request, licensed: Bool?, runner: RunnerState
    ) -> Confirmation? {
        guard licensed == false else { return nil }
        switch request {
        case .install: return runner == RunnerState.none ? .installUnlicensed : nil
        case .compatibilityTool: return .toolUnlicensed
        }
    }

    func requestInstall() async {
        guard isIdle else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        if let question = Self.activationQuestion(
            .install,
            licensed: await checkLicense()?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingConfirmation = question
        } else {
            await installIntoSteam()
        }
    }

    func requestCompatibilityTool(
        from chosen: CrossOverInstall? = nil, replacingExisting: Bool = false
    ) async {
        guard isIdle else { return }
        checkingLicense = true
        defer { checkingLicense = false }
        let install = chosen ?? setupSource
        if let question = Self.activationQuestion(
            .compatibilityTool,
            licensed: await checkLicense(for: install)?.licensed,
            runner: snapshot?.runner ?? RunnerState.none
        ) {
            pendingConfirmation = question
        } else {
            await setUpRunner(from: install, replacingExisting: replacingExisting)
        }
    }

    private(set) var pendingRemoval: String?

    func requestBuildRemoval(_ build: String) {
        guard isIdle else { return }
        pendingRemoval = build
        pendingConfirmation = .removeBuild
    }

    func cancelBuildRemoval() {
        pendingRemoval = nil
    }

    func removePendingBuild() async {
        guard let build = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(from: RunnerInstaller.removeStep) { _ in
            let changed = try await Task.detached(priority: .userInitiated) {
                try RunnerInstaller.removeClone(forBuild: build)
            }.value
            let removed = "Removed build \(SupportedRunners.displayVersion(forID: build))."
            return changed && SteamBundle.isRunning ? "\(removed) \(Self.toolsRestartHint)" : removed
        }
    }

    func addCrossOver() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        panel.message = "Select a copy of CrossOver."
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)

        guard panel.runModal() == .OK, let picked = panel.url else { return }

        clearFailure()
        outcome = nil

        guard CrossOverSource.looksLikeCrossOver(picked) else {
            setFailure("\(picked.lastPathComponent) is not a valid copy of CrossOver.")
            AppLog.note("crossOver choice refused: \(picked.path(percentEncoded: false))")
            return
        }

        let found = snapshot?.crossOver.contains {
            $0.bundle.standardizedFileURL == picked.standardizedFileURL
        } ?? false
        if !found {
            CrossOverSource.addManualBundle(picked)
            AppLog.note("crossOver added: \(picked.path(percentEncoded: false))")
        }
        await refresh()
    }

    func removeFromList(_ install: CrossOverInstall) async {
        guard isIdle else { return }
        clearFailure()
        outcome = nil
        CrossOverSource.removeManualBundle(install.bundle)
        AppLog.note("crossOver removed from list: \(install.id)")
        await refresh()
    }

    private static let toolsRestartHint = "Restart Steam to update its list of compatibility tools."

    private func runnerOutcome(_ result: RunnerSetup.Outcome) -> String {
        if result.stagedNothing { return "Compatibility tool is already set up." }
        guard result.toolsChanged, SteamBundle.isRunning else { return "Compatibility tool ready." }
        return "Compatibility tool ready. \(Self.toolsRestartHint)"
    }

    func perform(
        from first: String,
        _ body: (_ progress: @escaping @Sendable (String) -> Void) async throws -> String?
    ) async {
        guard !runInFlight else {
            AppLog.note("run refused: '\(first)' overlaps a run already in flight")
            return
        }
        runInFlight = true
        defer { runInFlight = false }

        clearFailure()
        outcome = nil
        let run = beginRun(first)
        defer { endRun() }

        do {
            outcome = try await body { label in
                Task { @MainActor in self.report(run, label) }
            }
        } catch {
            record(error)
        }

        await refreshAfterRun(self)
    }

    private func setUpRunner(from install: CrossOverInstall?, replacingExisting: Bool = false) async {
        guard let install else {
            setFailure("No supported copy of CrossOver found.")
            AppLog.note("run refused: no supported CrossOver")
            outcome = nil
            return
        }

        await perform(from: RunnerSetup.Phase.cloning.label) { progress in
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: replacingExisting) {
                    progress($0.label)
                }
            }.value

            return runnerOutcome(result)
        }
    }

    func fetchValveBinaries() async {
        await perform(from: ValveFetcher.Phase.verifying.label) { progress in
            let result = try await ValveFetcher.run { progress($0.label) }
            return result.wroteNothing ? nil : "Downloaded missing components."
        }
    }

    private static let restartHint = "Steam was stopped, so start it again."

    private static let toolNotActivated =
        "The compatibility tool was not set up because CrossOver is not activated."

    func installIntoSteam() async {
        await perform(from: InstallPhase.checkingPayload.label) { progress in
            let result = try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.run(report: { progress($0.label) })
            }.value

            var parts = ["NotProton successfully installed."]
            if result.stoppedClient { parts.append(Self.restartHint) }
            let install = usableCrossOver
            let state = await Task.detached(priority: .userInitiated) {
                (runner: RunnerStore.state(),
                 payload: PayloadInspector.inspect(),
                 license: install.map { CrossOverLicense.check(crossOverRoot: $0.crossOverRoot) })
            }.value

            if let install, state.license?.licensed == true, state.runner == .none {
                progress("Setting up compatibility tool")
                // A tool that came up is the expected case and goes unsaid. Failure
                // throws, and an unactivated CrossOver is reported below.
                _ = try await Task.detached(priority: .userInitiated) {
                    try RunnerSetup.run(from: install) { progress($0.label) }
                }.value
            } else if install != nil, state.license?.licensed == false, state.runner == .none {
                // Not a failure, NotProton was installed but without a compatibility tool
                parts.append(Self.toolNotActivated)
            }

            // Fetch binaries from Valve
            if state.payload.missing.contains(where: { $0.origin.isFetchable }) {
                progress("Downloading missing components")
                _ = try await ValveFetcher.run { progress($0.label) }
            }

            return parts.joined(separator: " ")
        }
    }

    func setUpdateBlock(_ blocked: Bool) async {
        await perform(from: blocked ? "Blocking Steam client updates"
                                    : "Allowing Steam client updates") { _ in
            if blocked {
                try UpdateBlock.write()
                return "Steam client updates are blocked."
            }

            try UpdateBlock.remove()
            return "Steam client updates are allowed."
        }
    }

    func repairSteam() async {
        await perform(from: RepairPhase.checking.label) { progress in
            let result = try await SteamRepair.run { progress($0.label) }

            var parts = ["Steam restored to its original state."]
            if result.stoppedClient { parts.append(Self.restartHint) }
            return parts.joined(separator: " ")
        }
    }

    func removeEverything() async {
        await perform(from: UninstallPhase.stoppingClient.label) { progress in
            let result = try await Uninstall.run { progress($0.label) }

            return result.restoredValveSignature
                ? "NotProton has been removed."
                : "NotProton has been removed. Steam needs to be redownloaded. "
                    + "Please run Repair Steam again once you are online."
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let version = AppVersion.bundled
        let captured = await Task.detached(priority: .userInitiated) {
            do {
                if try CompatToolList.sync() { AppLog.note("tool list rewritten") }
            } catch {
                AppLog.note("tool list not written: \(error.localizedDescription)")
            }
            for failure in NtdllPatcher.stageInstalled() {
                AppLog.note("ntdll for \(failure.build) not staged: \(failure.error.localizedDescription)")
            }
            return StatusSnapshot.capture(bundledVersion: version)
        }.value
        snapshot = captured
        AppLog.note(captured)
        await measureRunnerSizes()
    }

    private(set) var runnerSizes: [String: Int64] = [:]

    func measureRunnerSizes() async {
        let known = Set(runnerSizes.keys)
        let present = await Task.detached(priority: .utility) {
            Set(RunnerStore.clonedBuilds())
        }.value

        for stale in known.subtracting(present) { runnerSizes[stale] = nil }

        for build in present.subtracting(known) {
            runnerSizes[build] = await Task.detached(priority: .utility) {
                RunnerStore.cloneSize(forBuild: build)
            }.value
        }
    }
}
