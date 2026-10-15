import Foundation

struct Entry {
    let key: Character
    let win: Win
}

let pool = Array("asdfghjklqwertyuiopzxcvbnm1234567890")
private var remembered: [UInt32: Character] = [:]

/// Pinned keys from rules first; then every other window keeps the letter it
/// had last time; new windows take the first free letter of their app name,
/// else the next free letter from a home-row-first pool. Pinned keys are
/// reserved even when their app isn't open, so they never move. `blocked`
/// keys (the "previous window" key) are never handed out, not even by rules.
func assign(_ wins: [Win], rules: [Rule], blocked: Set<Character> = []) -> [UInt32: Character] {
    var result: [UInt32: Character] = [:]
    var used = blocked
    let reserved = Set(rules.compactMap { $0.key?.lowercased().first })

    for rule in rules {
        guard let k = rule.key?.lowercased().first, !used.contains(k) else { continue }
        let candidates = wins.filter { result[$0.id] == nil && rule.matches($0) }
        // Prefer the window that held the key last time, so two windows of
        // the same app don't swap letters.
        if let w = candidates.first(where: { remembered[$0.id] == k }) ?? candidates.first {
            result[w.id] = k
            used.insert(k)
        }
    }

    func free(_ c: Character) -> Bool { pool.contains(c) && !used.contains(c) && !reserved.contains(c) }

    for w in wins where result[w.id] == nil {
        if let c = remembered[w.id], free(c) {
            result[w.id] = c
            used.insert(c)
        }
    }
    for w in wins where result[w.id] == nil {
        if let c = w.app.lowercased().first(where: free) ?? pool.first(where: free) {
            result[w.id] = c
            used.insert(c)
        }
    }

    // Window ids aren't reused for a long time, so remembering letters for
    // windows that are temporarily gone (minimized, hidden) is harmless.
    remembered.merge(result) { $1 }
    if remembered.count > 1000 { remembered = result }
    return result
}

func entries(_ config: Config) -> (Backend, [Entry]) {
    let (backend, all) = resolveWindows(config.backend)
    let ignore = config.ignore ?? []
    let wins = all
        .filter { w in !ignore.contains { $0.matches(w) } }
        .sorted { ($0.space, $0.app.lowercased(), $0.id) < ($1.space, $1.app.lowercased(), $1.id) }
    let keys = assign(wins, rules: config.rules ?? [], blocked: Set([config.previous.reservedChar].compactMap { $0 }))
    return (backend, wins.compactMap { w in keys[w.id].map { Entry(key: $0, win: w) } })
}
