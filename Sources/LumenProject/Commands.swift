import Foundation
import LumenCore

/// Which derived tracks a command invalidates (plan 4.6).
public struct Effects: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let timeMap = Effects(rawValue: 1 << 0)
    public static let cursor = Effects(rawValue: 1 << 1)
    public static let zoom = Effects(rawValue: 1 << 2)
    public static let camera = Effects(rawValue: 1 << 3)
    public static let layout = Effects(rawValue: 1 << 4)
    public static let webcam = Effects(rawValue: 1 << 5)
    public static let masks = Effects(rawValue: 1 << 6)
    public static let captions = Effects(rawValue: 1 << 7)
    public static let audio = Effects(rawValue: 1 << 8)
    public static let backdrop = Effects(rawValue: 1 << 9)
    public static let replan: Effects = [.timeMap, .cursor, .zoom, .camera, .layout, .webcam, .masks, .captions, .audio]
}

/// Captured at dispatch so "at playhead" can never read stale pointer state. `playhead` is OUTPUT seconds.
public struct ReduceContext: Sendable {
    public var playhead: Double, selection: UUID?, duration: Double
    public init(playhead: Double, selection: UUID? = nil, duration: Double) { self.playhead = playhead; self.selection = selection; self.duration = duration }
}

public enum CommandError: Error, Sendable { case notFound(UUID), invalid(String) }

/// One case per user-visible action. Views, hotkeys, CLI, MCP and App Intents all dispatch these. Times are SOURCE seconds unless named Output/Playhead.
public enum Command: Codable, Sendable {
    case addCut(start: Double, end: Double), cutOutputRange(start: Double, end: Double), cutAtPlayhead(length: Double)
    case deleteCut(UUID), trim(start: Double, end: Double)
    case addSpeedRamp(start: Double, end: Double, speed: Double), deleteSpeedRamp(UUID)
    case addZoom(ZoomSegment), addZoomAtPlayhead(duration: Double, scale: Double), moveZoom(UUID, start: Double, end: Double)
    case setZoomScale(UUID, Double), setZoomFocus(UUID, Focus), setZoomEasing(UUID, ZoomEasing?), deleteZoom(UUID), setZoomPreset(ZoomPreset)
    case setStyle(Style), setCursor(CursorStyle), setCamera(CameraParams), setAudio(AudioPlan), setWebcam(WebcamLayout?), setCaptions(CaptionPlan)
    case setPrivacy(PrivacyPlan)
    case deleteWords([Int]), restoreWords([Int]), editWord(index: Int, text: String)
    case setCaptionsEnabled(Bool)
    case setLayout(LayoutSegment), deleteLayout(UUID), setLayoutSettings(LayoutKind, LayoutSettings)
    case addMask(Mask), addMaskAtPlayhead(x: Double, y: Double, w: Double, h: Double, mode: MaskMode)
    case approveMasks([UUID]), rejectMasks([UUID]), deleteMask(UUID)
    case addHighlight(Highlight), deleteHighlight(UUID), addLoupe(Loupe), deleteLoupe(UUID)
    case addTapAtPlayhead(x: Double, y: Double), deleteTap(UUID)
    case addText(TextBlock), deleteText(UUID)
    case applyAutoTidy([CutRange]), clearAutoTidy
}

/// Pure: (state, command, context) -> new state + effects. The only place user intent mutates the timeline.
public func reduce(_ t: inout Timeline, _ c: Command, ctx: ReduceContext) throws -> Effects {
    let tm = t.timeMap
    let playSrc = tm.source(atOutput: ctx.playhead)
    func zi(_ id: UUID) throws -> Int {
        guard let i = t.zoom.firstIndex(where: { $0.id == id }) else { throw CommandError.notFound(id) }
        return i
    }
    let zoomFx: Effects = [.zoom, .camera, .audio]
    switch c {
    case .addCut(let s, let e):
        guard e > s else { throw CommandError.invalid("cut end <= start") }
        t.timeMap.cuts.append(CutRange(start: s, end: e)); return .replan
    case .cutOutputRange(let s, let e):
        guard e > s else { throw CommandError.invalid("cut end <= start") }
        t.timeMap.cuts.append(CutRange(start: tm.source(atOutput: s), end: tm.source(atOutput: e))); return .replan
    case .cutAtPlayhead(let len):
        guard len > 0.05 else { throw CommandError.invalid("cut too short") }
        t.timeMap.cuts.append(CutRange(start: playSrc, end: min(playSrc + len, tm.trimEnd))); return .replan
    case .deleteCut(let id): t.timeMap.cuts.removeAll { $0.id == id }; return .replan
    case .trim(let s, let e):
        guard s >= 0, e > s, e <= tm.sourceDuration + 0.001 else { throw CommandError.invalid("bad trim") }
        t.timeMap.trimStart = s; t.timeMap.trimEnd = e; return .replan
    case .addSpeedRamp(let s, let e, let v):
        guard e > s, v > 0 else { throw CommandError.invalid("bad ramp") }
        t.timeMap.ramps.append(SpeedRamp(start: s, end: e, speed: v, origin: .manual)); return .replan
    case .deleteSpeedRamp(let id): t.timeMap.ramps.removeAll { $0.id == id }; return .replan

    case .addZoom(let z): t.zoom.append(z); return zoomFx
    case .addZoomAtPlayhead(let d, let sc):
        let e = min(tm.source(atOutput: ctx.playhead + d), tm.trimEnd)
        guard e - playSrc > 0.2 else { throw CommandError.invalid("no room for a zoom here") }
        t.zoom.append(ZoomSegment(start: playSrc, end: e, scale: max(sc, 1.1), focus: .follow, origin: .manual)); return zoomFx
    case .moveZoom(let id, let s, let e):
        let i = try zi(id); guard e > s else { throw CommandError.invalid("zoom end <= start") }
        t.zoom[i].start = s; t.zoom[i].end = e; t.zoom[i].origin = .manual; return zoomFx
    case .setZoomScale(let id, let sc): let i = try zi(id); t.zoom[i].scale = max(sc, 1.1); t.zoom[i].origin = .manual; return zoomFx
    case .setZoomFocus(let id, let f): let i = try zi(id); t.zoom[i].focus = f; t.zoom[i].origin = .manual; return zoomFx
    case .setZoomEasing(let id, let e): let i = try zi(id); t.zoom[i].easing = e; t.zoom[i].origin = .manual; return zoomFx
    case .deleteZoom(let id): t.zoom.removeAll { $0.id == id }; return zoomFx
    case .setZoomPreset(let p): t.camera.apply(preset: p); return zoomFx

    case .setStyle(let s):
        let o = t.style; t.style = s
        var fx: Effects = [.backdrop]
        if o.padding != s.padding || o.paddingInsets != s.paddingInsets || o.cornerRadius != s.cornerRadius || o.cornerRadii != s.cornerRadii
            || o.canvas != s.canvas || o.customAspect != s.customAspect { fx.formUnion([.zoom, .camera, .layout, .webcam, .captions]) }
        return fx
    case .setCursor(let s): t.cursor = s; return [.cursor, .camera, .audio]
    case .setCamera(let s): t.camera = s; return [.zoom, .camera, .audio]
    case .setAudio(let s): t.audio = s; return [.timeMap, .audio, .zoom, .camera]
    case .setWebcam(let w): t.webcam = w; return [.webcam, .layout]
    case .setCaptions(let p): t.captions = p; return [.captions]
    case .setPrivacy(let p): t.overlays.privacy = p; return .masks
    case .deleteWords(let ix): t.captions.deletedWords = Array(Set(t.captions.deletedWords).union(ix)).sorted(); return .replan
    case .restoreWords(let ix): t.captions.deletedWords.removeAll { ix.contains($0) }; return .replan
    case .editWord(let i, let s): t.captions.textEdits[String(i)] = s; return .captions
    case .setCaptionsEnabled(let b): t.captions.enabled = b; return .captions

    case .setLayout(let seg):
        if let i = t.layouts.firstIndex(where: { $0.id == seg.id }) { t.layouts[i] = seg } else { t.layouts.append(seg) }
        return [.zoom, .camera, .layout, .webcam, .captions]
    case .deleteLayout(let id): t.layouts.removeAll { $0.id == id }; return [.zoom, .camera, .layout, .webcam, .captions]
    case .setLayoutSettings(let k, let s): t.layoutSettings[k] = s; return [.zoom, .camera, .layout, .webcam]

    case .addMask(let m): t.overlays.masks.append(m); return .masks
    case .addMaskAtPlayhead(let x, let y, let w, let h, let mode):
        guard w > 1, h > 1 else { throw CommandError.invalid("empty mask") }
        let e = min(playSrc + 3, tm.trimEnd)
        t.overlays.masks.append(Mask(start: playSrc, end: e, mode: mode, keys: [MaskKey(t: playSrc, x: x, y: y, w: w, h: h)])); return .masks
    case .approveMasks(let ids):
        for i in t.overlays.masks.indices where ids.contains(t.overlays.masks[i].id) {
            t.overlays.masks[i].approved = true
            t.overlays.privacy.decisions[t.overlays.masks[i].id.uuidString] = true
        }
        return .masks
    case .rejectMasks(let ids):
        for id in ids where t.overlays.masks.first(where: { $0.id == id })?.origin == .auto {
            t.overlays.privacy.decisions[id.uuidString] = false
        }
        t.overlays.masks.removeAll { ids.contains($0.id) }
        return .masks
    case .deleteMask(let id): t.overlays.masks.removeAll { $0.id == id }; return .masks
    case .addHighlight(let h): t.overlays.highlights.append(h); return .masks
    case .deleteHighlight(let id): t.overlays.highlights.removeAll { $0.id == id }; return .masks
    case .addLoupe(let l): t.overlays.loupes.append(l); return .masks
    case .deleteLoupe(let id): t.overlays.loupes.removeAll { $0.id == id }; return .masks
    case .addTapAtPlayhead(let x, let y): t.overlays.taps.append(TapIndicator(t: playSrc, x: x, y: y)); return [.cursor, .audio]
    case .deleteTap(let id): t.overlays.taps.removeAll { $0.id == id }; return [.cursor, .audio]
    case .addText(let b): t.overlays.texts.append(b); return .captions
    case .deleteText(let id): t.overlays.texts.removeAll { $0.id == id }; return .captions

    case .applyAutoTidy(let cuts):
        t.timeMap.cuts.removeAll { $0.origin == .autoTidy }
        t.timeMap.cuts.append(contentsOf: cuts.map { CutRange(id: $0.id, start: $0.start, end: $0.end, origin: .autoTidy) }); return .replan
    case .clearAutoTidy: t.timeMap.cuts.removeAll { $0.origin == .autoTidy }; return .replan
    }
}
