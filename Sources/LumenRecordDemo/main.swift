// LumenRecordDemo — headless Lumen recording for the zoom scripted demo.
// Records a display, one window, or one display region plus the full input
// event stream for N seconds from the first captured frame, then prints the
// .lumen bundle path. Drive the fixture with Tools/Verify/drive while this
// runs. No HUD, no countdown: timed by the caller.
import Foundation
import CoreGraphics
import LumenCapture

@main struct RecordDemo {
    static func main() async {
        var seconds = 62.0
        var library = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
        var fps = 30
        var resolution = RecordingConfig.Resolution.p1080
        var source = "display"
        var windowID: CGWindowID = 0
        var region = CGRect.zero
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--seconds": i += 1; seconds = Double(args[i]) ?? seconds
            case "--library": i += 1; library = URL(fileURLWithPath: args[i])
            case "--fps": i += 1; fps = Int(args[i]) ?? fps
            case "--resolution":
                i += 1
                resolution = RecordingConfig.Resolution(rawValue: args[i]) ?? resolution
            case "--source": i += 1; source = args[i]
            case "--window": i += 1; windowID = CGWindowID(UInt32(args[i]) ?? 0)
            case "--region":
                i += 1
                let v = args[i].split(separator: ",").compactMap { Double($0) }
                if v.count == 4 { region = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
            default: break
            }
            i += 1
        }
        if source == "window", windowID == 0 {
            windowID = frontWindowID(owner: "Google Chrome") ?? 0
        }
        if source == "window", windowID == 0 {
            fputs("no window id: pass --window <id>\n", stderr); exit(2)
        }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var cfg: RecordingConfig
        switch source {
        case "window": cfg = RecordingConfig(source: .window(windowID))
        case "region":
            guard region.width > 16, region.height > 16 else { fputs("bad --region x,y,w,h\n", stderr); exit(2) }
            cfg = RecordingConfig(source: .region(CGMainDisplayID(), region))
        default: cfg = RecordingConfig(source: .display(CGMainDisplayID()))
        }
        cfg.fps = fps
        cfg.mic = false
        cfg.systemAudio = false
        cfg.resolution = resolution
        cfg.quality = .high
        let session = RecordingSession()
        do {
            try await session.prepare(cfg, library: library)
            try await session.start()
            // The first frame defines source time 0; the driver starts when
            // READY is printed so the script and the video share an origin.
            let deadline = Date().addingTimeInterval(15)
            while await session.stats().elapsed <= 0 {
                if Date() > deadline { throw CaptureError.writer("no frame arrived after start") }
                try await Task.sleep(for: .milliseconds(20))
            }
            print("READY for \(seconds)s")
            fflush(stdout)
            while await session.stats().elapsed < seconds {
                try await Task.sleep(for: .milliseconds(50))
            }
            let bundle = try await session.stop()
            print("BUNDLE \(bundle.url.path)")
        } catch {
            fputs("record failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Largest normal-layer on-screen window owned by `owner` (front to back).
    static func frontWindowID(owner: String) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matches = list.filter { item in
            (item[kCGWindowOwnerName as String] as? String) == owner
                && (item[kCGWindowLayer as String] as? Int ?? 0) == 0
                && (item[kCGWindowBounds as String] as? [String: Any]) != nil
        }
        let best = matches.max { a, b in
            func area(_ item: [String: Any]) -> Double {
                guard let d = item[kCGWindowBounds as String] as? [String: Any],
                      let w = d["Width"] as? Double, let h = d["Height"] as? Double else { return 0 }
                return w * h
            }
            return area(a) < area(b)
        }
        return best.flatMap { $0[kCGWindowNumber as String] as? Int }.map { CGWindowID($0) }
    }
}
