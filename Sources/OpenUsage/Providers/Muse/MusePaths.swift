import Foundation

/// Where Muse Code keeps its local data on this machine, shared by the auth store (reads
/// `auth.json`) and the usage scanner (reads the session logs). Resolution mirrors muse itself:
/// an explicit `MUSE_CONFIG_DIR` / `XDG_CONFIG_HOME` wins for config, `XDG_DATA_HOME` for data,
/// else the `~/.config/muse` and `~/.local/share/muse` defaults.
enum MusePaths {
    static func configDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "MUSE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        if let xdg = environment.value(for: "XDG_CONFIG_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/muse"
        }
        return homeDirectory.appendingPathComponent(".config/muse").path
    }

    /// The credential file written by `muse login` (Meta-account device flow) or
    /// `muse auth set --api-key-stdin`. `MUSE_AUTH_PATH` names the file directly when set.
    static func authFilePath(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: "MUSE_AUTH_PATH")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override)
        }
        return configDirectory(environment: environment, homeDirectory: homeDirectory) + "/auth.json"
    }

    static func dataDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let xdg = environment.value(for: "XDG_DATA_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(xdg).trimmingTrailingSlashes + "/muse"
        }
        return homeDirectory.appendingPathComponent(".local/share/muse").path
    }

    /// Date-partitioned session logs: `<data>/muse/sessions/YYYY/MM/DD/<session-id>/session.jsonl`.
    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        dataDirectory(environment: environment, homeDirectory: homeDirectory) + "/sessions"
    }
}
