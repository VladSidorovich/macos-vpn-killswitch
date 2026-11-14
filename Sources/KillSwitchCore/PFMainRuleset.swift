import Foundation

/// Checks `pfctl -sr` (the main ruleset) for the two ways the kill switch anchor can silently
/// stop being evaluated: the `com.apple/*` anchor reference is gone, or another product put a
/// `quick` pass rule in front of it. Pure; the daemon only reports, it never rewrites pf.conf.
public enum PFMainRuleset {
    public static func check(_ text: String) -> [String] {
        var problems: [String] = []
        var foreign: [String] = []
        var sawAnchor = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("anchor \"com.apple/*\"") { sawAnchor = true; break }
            if line.hasPrefix("pass") && line.contains(" quick") { foreign.append(line) }
        }
        if !sawAnchor { problems.append("pf main ruleset has no anchor \"com.apple/*\"; the kill switch rules are not evaluated") }
        if sawAnchor, let first = foreign.first {
            problems.append("a quick pass rule precedes the kill switch anchor: \(first)")
        }
        return problems
    }
}

/// Decides the starting state from the bytes of state.json.
public enum StateLoading {
    /// Missing file: fresh install, start off. Present but unreadable: if the config is locked
    /// the safe reading of "I don't know" is on (the owner can still `sudo ksctl off`).
    public static func load(data: Data?, locked: Bool) -> (state: PersistedState, note: String?) {
        guard let data else { return (PersistedState(), nil) }
        if let s = try? JSONDecoder().decode(PersistedState.self, from: data) { return (s, nil) }
        if locked {
            return (PersistedState(mode: .on), "state.json is unreadable; starting ON because the config is locked")
        }
        return (PersistedState(), "state.json is unreadable; starting off")
    }
}
