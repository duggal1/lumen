import Foundation

/// v3 -> v4 JSON migration (pure, idempotent, preserves unknown fields).
/// timeline.audio.targetLUFS (Double) -> timeline.audio.targetLUFSOverride (Double?).
/// Rules: stored == old default for mode (Standard -16, Loud -12) or == new default
/// for its mode (Standard -14, Loud -12, Podcast -16) -> nil; else keep as override.
/// timeline.schemaVersion -> 4.
public enum LUFS_Migrate {
    public static func migrate_3_to_4(_ root: [String: Any]) -> [String: Any] {
        var out = root
        guard let tl = root["timeline"] as? [String: Any] else { return out }
        var timeline = tl
        timeline["schemaVersion"] = 4
        if var audio = tl["audio"] as? [String: Any] {
            let mode = (audio["micMode"] as? String) ?? "standard"
            let oldDefault: Double = mode == "loud" ? -12 : -16
            let newDefault: Double = mode == "loud" ? -12 : (mode == "podcast" ? -16 : -14)
            let legacy = (audio["targetLUFS"] as? Double) ?? (audio["targetLUFS"] as? Int).map(Double.init)
            if let existing = audio["targetLUFSOverride"] {
                // Already v4: keep override untouched, drop legacy for idempotence.
                _ = existing
            } else if let l = legacy {
                if abs(l - oldDefault) < 1e-9 || abs(l - newDefault) < 1e-9 {
                    // nil: omit override key
                } else {
                    audio["targetLUFSOverride"] = l
                }
            }
            // Drop legacy key so re-running is a no-op.
            audio.removeValue(forKey: "targetLUFS")
            // In dictionaries, a missing key == nil override. Explicit null
            // is also accepted by the decoder via opt. Keep absence for tests.
            timeline["audio"] = audio
        }
        out["timeline"] = timeline
        return out
    }
}
