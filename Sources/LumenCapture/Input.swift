import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import os
import Synchronization
import LumenCore
import LumenProject

/// Single-producer/single-consumer ring. Producer = event tap thread, consumer = writer queue.
/// Overflow is counted (never silent).
final class EventRing: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<InputEvent>
    private let cap: Int
    private let head = Atomic<Int>(0), tail = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    init(capacity: Int) { cap = capacity; buf = .allocate(capacity: capacity); buf.initialize(repeating: InputEvent(), count: capacity) }
    deinit { buf.deallocate() }
    var overflow: Int { dropped.load(ordering: .relaxed) }
    func push(_ e: InputEvent) {
        let h = head.load(ordering: .relaxed)
        if h - tail.load(ordering: .acquiring) >= cap { dropped.store(dropped.load(ordering: .relaxed) + 1, ordering: .relaxed); return }
        buf[h % cap] = e
        head.store(h + 1, ordering: .releasing)
    }
    func drain(_ body: (InputEvent) -> Void) {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        while t < h { body(buf[t % cap]); t += 1 }
        tail.store(t, ordering: .releasing)
    }
}

extension StockCursor {
    var ns: NSCursor {
        switch self {
        case .arrow: .arrow; case .iBeam: .iBeam; case .pointingHand: .pointingHand; case .crosshair: .crosshair
        case .openHand: .openHand; case .closedHand: .closedHand; case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown; case .notAllowed: .operationNotAllowed; case .contextMenu: .contextualMenu
        }
    }
}

/// Classifies NSCursor.currentSystem against stock cursors by bitmap hash. Main-actor only (AppKit).
@MainActor public final class CursorCatalog {
    private var stock: [Int: UInt16] = [:], custom: [Int: UInt16] = [:]
    public private(set) var customs: [(id: UInt16, png: Data, hotX: Double, hotY: Double)] = []
    public init() {
        for s in StockCursor.allCases { if let h = Self.hash(s.ns) { stock[h] = s.rawValue } }
    }
    static func hash(_ c: NSCursor) -> Int? { c.image.tiffRepresentation?.hashValue }
    public func classify() -> UInt16 {
        guard let c = NSCursor.currentSystem, let h = Self.hash(c) else { return 0 }
        if let s = stock[h] { return s }
        if let s = custom[h] { return s }
        guard customs.count < 24 else { return 0 }
        let id = UInt16(1000 + customs.count)
        custom[h] = id
        if let tiff = c.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            customs.append((id, png, c.hotSpot.x, c.hotSpot.y))
        }
        return id
    }
    public func writeJSON(to url: URL) {
        struct C: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
        let arr = customs.map { C(id: $0.id, png: $0.png, hotX: $0.hotX, hotY: $0.hotY) }
        try? JSONEncoder().encode(arr).write(to: url)
    }
}

public enum ClockCalibration {
    /// Calibrates the CGEvent timestamp unit by sampling CGEvent, mach and
    /// CLOCK_UPTIME_RAW together (PLAN 7.1). Picks the unit whose conversion
    /// lands within 1 ms of the host clock. Never assumes; derives.
    public static func eventUnit() -> EventTimeUnit {
        let now = HostClock.now()
        guard let ev = CGEventCreate(nil) else { return .nanoseconds }
        let ts = ev.timestamp
        let asNsec = Double(ts) / 1e9
        let asMach = HostClock.seconds(machTicks: ts)
        let nsecErr = abs(asNsec - now)
        let machErr = abs(asMach - now)
        // Prefer the closer conversion; default to nanoseconds (documented unit).
        if machErr < nsecErr && machErr <= 1 { return .machTicks }
        return .nanoseconds
    }

    /// SCK PTS is on the host clock (mach-based). Events converted via the
    /// calibrated unit above share that timeline, so hover/cursor sync error
    /// is bounded by the calibration error (<1 ms) with no drift (both are
    /// host-time based, not wall-clock). Per-source audio latency offsets are
    /// stored in TrackMeta and applied in the mixer.
    public static func hostSecondsForEvent(_ ts: UInt64, unit: EventTimeUnit) -> Double {
        unit == .machTicks ? HostClock.seconds(machTicks: ts) : Double(ts) / 1e9
    }

    /// Convert timestamps from REAL event callbacks. A synthetic calibration
    /// event may report a different clock (or zero). Never discard a genuine
    /// mouse-down because the saved calibration guessed the wrong unit.
    public static func alignedHostSeconds(eventTimestamp: UInt64, clock: RecordingClock,
                                          receivedAt now: Double) -> Double {
        let preferred = clock.hostSeconds(eventTimestamp: eventTimestamp)
        if preferred.isFinite && abs(preferred - now) <= 1 { return preferred }
        let alternate = clock.eventUnit == .machTicks
            ? Double(eventTimestamp) / 1e9 : HostClock.seconds(machTicks: eventTimestamp)
        if alternate.isFinite && abs(alternate - now) <= 1 { return alternate }
        // The event tap is listen-only and invoked synchronously. Receipt time
        // is a better bounded estimate than silently losing the click entirely.
        return now
    }
}

/// Listen-only CGEventTap on its own high-QoS thread. Coordinates converted to source pixels once, here.
public final class InputRecorder: @unchecked Sendable {
    private let ring = EventRing(capacity: 1 << 16)
    private let liveEventHook = OSAllocatedUnfairLock<(@Sendable (InputEvent) -> Void)?>(initialState: nil)
    public func setLiveEventHook(_ hook: (@Sendable (InputEvent) -> Void)?) { liveEventHook.withLock { $0 = hook } }
    private let url: URL, origin: CGPoint, scale: Double, clock: RecordingClock, axURL: URL
    private let shape = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let loop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    private let axFrames = OSAllocatedUnfairLock<[AXFrame]>(initialState: [])
    private let axTrusted = OSAllocatedUnfairLock(initialState: false)
    private let axQ = DispatchQueue(label: "lumen.ax", qos: .utility)
    private var tap: CFMachPort?
    private var fh: FileHandle?
    private var timer: DispatchSourceTimer?
    private let writeQ = DispatchQueue(label: "lumen.events.write")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let catalog: CursorCatalog

    @MainActor public init(url: URL, axURL: URL, origin: CGPoint, scale: Double, clock: RecordingClock) {
        self.url = url; self.axURL = axURL; self.origin = origin; self.scale = scale; self.clock = clock; catalog = CursorCatalog()
    }

    @MainActor public func start() throws {
        FileManager.default.createFile(atPath: url.path, contents: EventCodec.header())
        fh = try FileHandle(forWritingTo: url); try fh?.seekToEnd()
        running.withLock { $0 = true }
        axTrusted.withLock { $0 = AXIsProcessTrusted() }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let cb: CGEventTapCallBack = { @Sendable _, type, event, refcon in
            if let refcon { Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                        callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw CaptureError.writer("event tap denied (Input Monitoring)") }
        tap = t
        let th = Thread { @Sendable [self] in
            guard let t = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            loop.withLock { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.qualityOfService = .userInteractive; th.start()
        startFlushTimer()
        Task { @MainActor [weak self] in           // cursor shape poll @ 10 Hz (was 30 Hz: per-tick main churn)
            while let self, self.running.withLock({ $0 }) {
                let cursorShape = self.catalog.classify()
                self.shape.withLock { $0 = cursorShape }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func startFlushTimer() {
        let tm = DispatchSource.makeTimerSource(queue: writeQ)
        tm.schedule(deadline: .now() + 0.25, repeating: 0.25)
        tm.setEventHandler { @Sendable [self] in flush() }
        tm.resume(); timer = tm
    }

    @MainActor public func stop() async {
        running.withLock { $0 = false }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        loop.withLock { if let l = $0 { CFRunLoopStop(l) } }
        timer?.cancel()
        await withCheckedContinuation { continuation in
            writeQ.async { [self] in
                flush(); try? fh?.close()
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            axQ.async { continuation.resume() }
        }
        catalog.writeJSON(to: url.deletingLastPathComponent().appendingPathComponent("cursors.json"))
        if let d = try? JSONEncoder().encode(axFrames.withLock { $0 }) { try? d.write(to: axURL) }
    }

    private func flush() {
        var b: [UInt8] = []
        ring.drain { EventCodec.encode($0, into: &b) }
        if !b.isEmpty { try? fh?.write(contentsOf: Data(b)) }
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        let eventHost = ClockCalibration.alignedHostSeconds(
            eventTimestamp: e.timestamp, clock: clock, receivedAt: HostClock.now())
        var ev = InputEvent(t: eventHost)
        let loc = e.location                                   // Quartz global space: already top-left origin
        ev.x = Float((loc.x - origin.x) * scale); ev.y = Float((loc.y - origin.y) * scale)
        ev.cursorShape = shape.withLock { $0 }
        ev.flags = UInt16(truncatingIfNeeded: e.flags.rawValue >> 16)
        switch type {
        case .mouseMoved: ev.kind = .move
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: ev.kind = .drag
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ev.kind = .down; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
            ev.axFrameIndex = reserveAX(loc)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            ev.kind = .up; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel:
            ev.kind = .scroll
            // Wheel delta was previously discarded entirely; without it no
            // scroll smoothing (or even scroll velocity) is possible.
            let lines = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let fixed = e.getIntegerValueField(CGEventField(rawValue: 93)!)   // FixedPtDeltaAxis1, 1/16 line
            ev.scrollDelta = lines != 0 ? Float(lines) : Float(fixed) / 16.0
        case .keyDown:
            guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            ev.kind = .keyDown; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))   // key codes only, never characters
        case .keyUp: ev.kind = .keyUp; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: ev.kind = .flagsChanged
        default: return
        }
        liveEventHook.withLock { $0 }?(ev)
        ring.push(ev)
    }

    private func reserveAX(_ p: CGPoint) -> UInt32 {
        guard axTrusted.withLock({ $0 }) else { return 0 }
        let idx = axFrames.withLock { $0.append(AXFrame(x: 0, y: 0, w: 0, h: 0)); return $0.count }
        axQ.async { [self] in
            if let f = queryAX(p) { axFrames.withLock { if idx >= 1, idx <= $0.count { $0[idx - 1] = f } } }
        }
        return UInt32(idx)
    }

    private func queryAX(_ p: CGPoint) -> AXFrame? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return nil }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return nil }
        return AXFrame(x: (pos.x - origin.x) * scale, y: (pos.y - origin.y) * scale, w: size.width * scale, h: size.height * scale)
    }
}
