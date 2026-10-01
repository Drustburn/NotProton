// One row per CrossOver build on the Status pane

import Foundation

struct CrossOverRow: Identifiable, Equatable {

    enum Copy: Equatable {
        case none
        case ready
        case unpatched
        case damaged
        case unsupported
    }

    let buildID: String
    let install: CrossOverInstall?
    let copy: Copy
    let licensed: Bool?
    let unsupportedVersion: String?

    var id: String { install?.id ?? buildID }
    var build: RunnerBuild? { SupportedRunners.build(id: buildID) }

    var title: String {
        if let install { return install.name }
        return "CrossOver \(SupportedRunners.displayVersion(forID: buildID))"
    }

    var canSetUp: Bool { install != nil && unsupportedVersion == nil }
    var isManual: Bool { install?.isManual ?? false }

    static func == (a: CrossOverRow, b: CrossOverRow) -> Bool {
        a.buildID == b.buildID && a.install?.id == b.install?.id && a.copy == b.copy
            && a.licensed == b.licensed && a.unsupportedVersion == b.unsupportedVersion
    }

    static func rows(
        installs: [CrossOverInstall],
        licenses: [String: CrossOverLicense.Status],
        installed: [RunnerBuild],
        damaged: [String],
        orphaned: [String],
        unpatched: String?
    ) -> [CrossOverRow] {
        var rows: [CrossOverRow] = []
        var seen: Set<String> = []

        func copy(of build: String) -> Copy {
            if build == unpatched { return .unpatched }
            if installed.contains(where: { $0.id == build }) { return .ready }
            if damaged.contains(build) { return .damaged }
            return .none
        }

        for install in installs {
            switch install.support {
            case .supported(let build):
                guard seen.insert(build.id).inserted else { continue }
                rows.append(CrossOverRow(
                    buildID: build.id, install: install, copy: copy(of: build.id),
                    licensed: licenses[install.id]?.licensed, unsupportedVersion: nil
                ))
            case .unsupportedBuild(let version):
                rows.append(CrossOverRow(
                    buildID: "", install: install, copy: .none, licensed: nil, unsupportedVersion: version
                ))
            case .unreadable:
                continue
            }
        }

        let copies = installed.map(\.id) + damaged
        for build in copies where seen.insert(build).inserted {
            rows.append(CrossOverRow(
                buildID: build, install: nil, copy: copy(of: build), licensed: nil, unsupportedVersion: nil
            ))
        }
        for build in orphaned where seen.insert(build).inserted {
            rows.append(CrossOverRow(
                buildID: build, install: nil, copy: .unsupported, licensed: nil, unsupportedVersion: nil
            ))
        }
        return rows
    }
}
