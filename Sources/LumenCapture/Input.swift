import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import os
import Synchronization
import LumenCore
import LumenProject

/// Process-wide capture diagnostics. Losing input events to a full ring is a
/// resource-exhaustion signal: it must be visible, not a private counter nobody
/// reads. `eventOverflow` is monotonic for the life of the process and is
/// exposed so a headless test can prove the overflow is reported.
public enum CaptureDiagnostics {
    public static let eventOverflow = OSAllocatedUnfairLock<Int>(initialState: 0)
    public static var overflowCount: Int { eventOverflow.withLock { $0 } }
    public static func resetEventOverflow() { eventOverflow.withLock { $0 = 0 } }
}

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
        if h - tail.load(ordering: .acquiring) >= cap {
            dropped.store(dropped.load(ordering: .relaxed) + 1, ordering: .relaxed)
            let total = CaptureDiagnostics.eventOverflow.withLock { value -> Int in
                value += 1
                return value
            }
            // Rate-limit the log so a wedged consumer cannot flood the console.
            if total == 1 || total % 256 == 0 {
                os_log("input event ring overflow: %d events dropped", log: .default, type: .error, total)
            }
            return
        }
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
    private var lastIdentity: ObjectIdentifier?, lastValue: UInt16 = 0
    public init() {
        for s in StockCursor.allCases { if let h = Self.hash(s.ns) { stock[h] = s.rawValue } }
    }
    static func hash(_ c: NSCursor) -> Int? { c.image.tiffRepresentation?.hashValue }
    /// The system reuses one NSCursor instance per shape, so identity is a
    /// cheap change detector. The bitmap hash runs only when the shape
    /// actually changes; a 60 Hz poll of an idle cursor stays O(1).
    public func classify() -> UInt16 {
        guard let c = NSCursor.currentSystem else { return 0 }
        let identity = ObjectIdentifier(c)
        if identity == lastIdentity { return lastValue }
        let value = Self.classifyUncached(c, stock: stock, custom: &custom, customs: &customs)
        lastIdentity = identity
        lastValue = value
        return value
    }
    private static func classifyUncached(_ c: NSCursor, stock: [Int: UInt16],
                                         custom: inout [Int: UInt16],
                                         customs: inout [(id: UInt16, png: Data, hotX: Double, hotY: Double)]) -> UInt16 {
        guard let h = hash(c) else { return 0 }
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
    public func encodedSnapshot() -> Data? {
        struct C: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
        let arr = customs.map { C(id: $0.id, png: $0.png, hotX: $0.hotX, hotY: $0.hotY) }
        return try? JSONEncoder().encode(arr)
    }
}

public enum ClockCalibration {
    /// Calibrates the CGEvent timestamp unit by sampling CGEvent, mach and
    /// CLOCK_UPTIME_RAW together (PLAN 7.1). Picks the unit whose conversion
    /// lands within 1 ms of the host clock. Never assumes; derives.
    public static func eventUnit() -> EventTimeUnit {
        let now = HostClock.now()
        guard let ev = CGEvent(source: nil) else { return .nanoseconds }
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

/// One accessibility focus observation, with the evidence needed to tell
/// whether it belongs to the event that asked for it. `context` is a stable
/// token for the focused element (identifier, or role/subrole/title), not the
/// text value, so ordinary typing does not look like a focus change.
struct FocusProbe: Sendable {
    var frame: AXFrame
    var context: String
    var appName: String?
    var windowID: Int?
    var host: String?
}

private enum LiveFocusDelivery: Sendable { case none, event, focus }

/// A key-down's own AX reservation. `index` is never shared with another
/// event: a pending query for field A cannot be published as field B's caret.
private struct FocusFlight: Sendable {
    let index: UInt32
    let event: InputEvent
    let live: LiveFocusDelivery
}

private struct FocusState: Sendable {
    var inFlight: FocusFlight?
    var queued: FocusFlight?
    var epoch: UInt32 = 0
    var lastContext: String?
    var lastGood: (frame: AXFrame, at: Double, epoch: UInt32, context: String)?
    var lastDelivered: UInt32 = 0
    /// Newest event that has already carried a *focus sample* to the consumer.
    /// An older late sample cannot move the camera back, but each event still
    /// keeps its own resolved evidence instead of being thrown away.
    var lastFocusIndex: UInt32 = 0
}

private struct MouseAXState: Sendable {
    var inFlight = false
    var last = -Double.infinity
}

/// Baseline of surfaces seen at the previous click. A dialog is evidence only
/// when it is *new* relative to this set; clicking inside an already-open
/// dialog must not emit a second window frame or bump the focus epoch.
private struct SurfaceWatch: Sendable {
    var known: Set<Int> = []
    var established = false
}

/// Listen-only CGEventTap on its own high-QoS thread. Coordinates converted to source pixels once, here.
public final class InputRecorder: @unchecked Sendable {
    private let ring = EventRing(capacity: 1 << 16)
    // AGENT: virtual actuator events bypass the global event tap and are buffered until the normal event flush.
    private let injected = OSAllocatedUnfairLock<[InputEvent]>(initialState: [])
    private let liveFocusHook = OSAllocatedUnfairLock<(@Sendable (InputEvent, AXFrame) -> Void)?>(initialState: nil)
    public func setLiveFocusHook(_ hook: (@Sendable (InputEvent, AXFrame) -> Void)?) { liveFocusHook.withLock { $0 = hook } }
    private let liveEventHook = OSAllocatedUnfairLock<(@Sendable (InputEvent) -> Void)?>(initialState: nil)
    public func setLiveEventHook(_ hook: (@Sendable (InputEvent) -> Void)?) { liveEventHook.withLock { $0 = hook } }
    private let url: URL, clock: RecordingClock, axURL: URL
    private let origin: OSAllocatedUnfairLock<CGPoint>
    private let sourceScale: OSAllocatedUnfairLock<SIMD2<Double>>
    private let windowID: CGWindowID?
    private let shape = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let loop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    /// AX frames are addressed by a stable 1-based reservation, never by an
    /// array position: focus, click and secure-field samples share the space,
    /// so a late writer can never shift another event's frame.
    private let axStore = OSAllocatedUnfairLock<[UInt32: AXFrame]>(initialState: [:])
    private let axNextIndex = OSAllocatedUnfairLock(initialState: UInt32(1))
    private let focusState = OSAllocatedUnfairLock(initialState: FocusState())
    private let mouseAX = OSAllocatedUnfairLock(initialState: MouseAXState())
    private let axTrusted = OSAllocatedUnfairLock(initialState: false)
    private let axQ = DispatchQueue(label: "lumen.ax", qos: .utility)
    /// Focus queries get their own queue so the secure-field walk and click
    /// hit-tests cannot stretch focus latency.
    private let focusQ = DispatchQueue(label: "lumen.ax.focus", qos: .userInteractive)
    /// Live delivery is off the event-tap thread.
    private let liveQ = DispatchQueue(label: "lumen.input.live", qos: .userInteractive)
    /// Native dialogs can appear a frame after the click. AX reads are slow and
    /// can block a CGEventTap long enough for the tap to be disabled, so they
    /// run here, off the tap thread, stamped with the click's own event time.
    private let surfaceQ = DispatchQueue(label: "lumen.ax.surfaces", qos: .userInteractive)
    private let windowOriginQ = DispatchQueue(label: "lumen.window.origin", qos: .utility)
    private var axTimer: DispatchSourceTimer?
    private var windowOriginTimer: DispatchSourceTimer?
    private var enhancedApps: Set<pid_t> = []
    private let launcherPIDs = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
    private static let launcherIDs: Set<String> = [
        "com.apple.Spotlight", "com.apple.dock", "com.raycast.macos", "com.runningwithcrayons.Alfred",
        "com.apple.apps.launcher"
    ]
    private var tap: CFMachPort?
    private var fh: FileHandle?
    private var timer: DispatchSourceTimer?
    private let writeQ = DispatchQueue(label: "lumen.events.write")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let catalog: CursorCatalog
    // In-process verification seams. They replace the real event tap / AX
    // server only when a test sets them; production never does.
    private let debugAXTrusted = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private let debugFocusProbe = OSAllocatedUnfairLock<(@Sendable (UInt32, InputEvent) -> FocusProbe?)?>(initialState: nil)
    private let debugFocusDelay = OSAllocatedUnfairLock(initialState: 0.004)
    private let debugRunning = OSAllocatedUnfairLock(initialState: false)
    /// Headless replacement for `WindowContent.visibleSurfaces()`. When set,
    /// click-time dialog detection is synchronous and deterministic; no real
    /// CGWindowList or AX server is touched.
    private let debugSurfaceProbe = OSAllocatedUnfairLock<(@Sendable (InputEvent) -> [AXSurface]?)?>(initialState: nil)
    private let surfaceWatch = OSAllocatedUnfairLock(initialState: SurfaceWatch())

    @MainActor public init(url: URL, axURL: URL, origin: CGPoint, scale: Double, clock: RecordingClock,
                           windowID: CGWindowID? = nil) {
        self.url = url
        self.axURL = axURL
        self.origin = OSAllocatedUnfairLock(initialState: origin)
        self.sourceScale = OSAllocatedUnfairLock(initialState: SIMD2(repeating: scale))
        self.clock = clock
        self.windowID = windowID
        catalog = CursorCatalog()
    }

    func setSourceScale(_ scale: SIMD2<Double>) {
        guard scale.x.isFinite, scale.y.isFinite, scale.x > 0, scale.y > 0 else { return }
        sourceScale.withLock { $0 = scale }
    }

    private var axTrustedNow: Bool { debugAXTrusted.withLock { $0 } ?? axTrusted.withLock { $0 } }
    private var isRunning: Bool { debugRunning.withLock { $0 } || running.withLock { $0 } }

    private func reserveSlot() -> UInt32 {
        axNextIndex.withLock { i -> UInt32 in let v = i; i += 1; return v }
    }

    private func publish(_ frame: AXFrame, at index: UInt32) {
        guard index > 0 else { return }
        axStore.withLock { $0[index] = frame }
    }

    /// Materializes the reservation space in index order. A reservation that
    /// never resolved is an explicit unresolved placeholder (`resolved == false`),
    /// never a zeroed sample a consumer could mistake for a real field.
    var axFramesSnapshot: [AXFrame] {
        axStore.withLock { store -> [AXFrame] in
            guard let max = store.keys.max(), max >= 1 else { return [] }
            var out = [AXFrame](); out.reserveCapacity(Int(max))
            for i in UInt32(1)...max {
                out.append(store[i] ?? AXFrame(x: 0, y: 0, w: 0, h: 0,
                                               anchor: FocusAnchor(resolved: false)))
            }
            return out
        }
    }

    @MainActor public func start() throws {
        FileManager.default.createFile(atPath: url.path, contents: EventCodec.header())
        fh = try FileHandle(forWritingTo: url); try fh?.seekToEnd()
        running.withLock { $0 = true }
        axTrusted.withLock { $0 = AXIsProcessTrusted() }
        refreshWindowOrigin()
        startWindowOriginMonitor()
        refreshLauncherPIDs()
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
        startAXTimer()
        startCursorShapeSampler()
        Task { @MainActor [weak self] in
            var ticks = 0
            while let self, self.running.withLock({ $0 }) {
                if ticks % 20 == 0 { self.refreshLauncherPIDs() }
                ticks += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Samples the stock cursor shape at 10 Hz. Identity is the change
    /// detector, so a tick costs one pointer compare, but every tick still
    /// wakes the main actor; at 60 Hz that competed with the stop click for no
    /// visible gain. Click events stamp the last sampled shape, and a shape
    /// that lives for less than a tenth of a second is not something a viewer
    /// of the recording can see.
    private func startCursorShapeSampler() {
        Task { @MainActor [weak self] in
            while let self, self.running.withLock({ $0 }) {
                let sampled = self.catalog.classify()
                self.shape.withLock { $0 = sampled }
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
        axTimer?.cancel(); axTimer = nil
        windowOriginTimer?.cancel(); windowOriginTimer = nil
        // Every drain below is bounded. A wedged AX query (a hung app, VoiceOver
        // walking a dead tree) used to hold Stop forever, because the wait was a
        // plain continuation with no way out.
        await Self.drain(writeQ) { [self] in flush(); try? fh?.close() }
        await Self.drain(axQ)
        await Self.drain(focusQ)
        await Self.drain(surfaceQ)
        await Self.drain(liveQ)
        let cursors = catalog.encodedSnapshot()
        let frames = axFramesSnapshot
        await Task.detached(priority: .userInitiated) { [self] in
            try? cursors?.write(to: url.deletingLastPathComponent().appendingPathComponent("cursors.json"), options: .atomic)
            if let d = try? JSONEncoder().encode(frames) { try? d.write(to: axURL, options: .atomic) }
        }.value
    }

    /// Runs `work` on `queue`, then continues — but never waits longer than
    /// `seconds`. The timeout lives on a separate queue: a timer scheduled on a
    /// blocked queue would never fire, which is the hang it must escape.
    private static func drain(_ queue: DispatchQueue, seconds: Double = 2,
                              _ work: (@Sendable () -> Void)? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let fired = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable () -> Void = {
                let first = fired.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume() }
            }
            queue.async {
                work?()
                resume()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { resume() }
        }
    }

    private func flush() {
        var b: [UInt8] = []
        // AGENT: the project loader sorts by host time, so encode the tap ring directly without allocating a second event array on the capture queue.
        ring.drain { EventCodec.encode($0, into: &b) }
        let extra = injected.withLock { pending -> [InputEvent] in
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
        for event in extra { EventCodec.encode(event, into: &b) }
        if !b.isEmpty { try? fh?.write(contentsOf: Data(b)) }
    }

    /// Converts intended screen points into the active recording's source-pixel space.
    // AGENT: virtual pointer motion must render and drive click analysis without moving the user's cursor.
    func injectPointer(kind: InputEvent.Kind, screenPoint: CGPoint, button: UInt8 = 0,
                       keyCode: UInt16 = 0, flags: UInt16 = 0, scrollDelta: Float = 0) {
        var event = InputEvent(t: HostClock.now(), kind: kind)
        let sourceOrigin = origin.withLock { $0 }
        let scale = sourceScale.withLock { $0 }
        event.x = Float((screenPoint.x - sourceOrigin.x) * scale.x)
        event.y = Float((screenPoint.y - sourceOrigin.y) * scale.y)
        event.button = button
        event.keyCode = keyCode
        event.flags = flags
        event.cursorShape = shape.withLock { $0 }
        event.scrollDelta = scrollDelta
        let completedEvent = event
        injected.withLock { $0.append(completedEvent) }
    }

    // In-process verification only. These exercise the same reservation and
    // delivery path as the tap callback without a real event tap or AX server.
    func debugRecord(_ ev: InputEvent) {
        var e = ev
        if e.kind == .keyDown { e.axFrameIndex = reserveFocus(event: e) }
        else if e.kind == .down {
            // reserveAX performs the one live delivery with its own index.
            e.axFrameIndex = reserveAX(CGPoint(x: Double(e.x), y: Double(e.y)), event: e)
        } else { liveEventHook.withLock { $0 }?(e) }
        ring.push(e)
    }
    func debugSetAXTrusted(_ value: Bool) { debugAXTrusted.withLock { $0 = value } }
    func debugSetFocusProbe(_ probe: (@Sendable (UInt32, InputEvent) -> FocusProbe?)?) {
        debugFocusProbe.withLock { $0 = probe }
    }
    func debugSetFocusDelay(_ value: Double) { debugFocusDelay.withLock { $0 = value } }
    func debugSetRunning(_ value: Bool) { debugRunning.withLock { $0 = value } }
    /// Installs a deterministic frontmost-surface observation for headless tests.
    func debugSetSurfaceProbe(_ probe: (@Sendable (InputEvent) -> [AXSurface]?)?) {
        debugSurfaceProbe.withLock { $0 = probe }
        surfaceWatch.withLock { $0 = SurfaceWatch() }
    }
    /// Seeds the "already open" set so a test can assert that only a genuinely
    /// new window/sheet emits a frame.
    func debugSetKnownSurfaceIDs(_ ids: [Int]) {
        surfaceWatch.withLock { $0 = SurfaceWatch(known: Set(ids), established: true) }
    }
    func debugDrainEvents() -> [InputEvent] {
        var out: [InputEvent] = []
        ring.drain { out.append($0) }
        return out
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        let eventHost = ClockCalibration.alignedHostSeconds(
            eventTimestamp: e.timestamp, clock: clock, receivedAt: HostClock.now())
        var ev = InputEvent(t: eventHost)
        var liveDelivered = false
        let loc = e.location                                   // Quartz global space: already top-left origin
        let sourceOrigin = origin.withLock { $0 }
        let scale = sourceScale.withLock { $0 }
        ev.x = Float((loc.x - sourceOrigin.x) * scale.x); ev.y = Float((loc.y - sourceOrigin.y) * scale.y)
        ev.cursorShape = shape.withLock { $0 }
        ev.flags = UInt16(truncatingIfNeeded: e.flags.rawValue >> 16)
        switch type {
        case .mouseMoved: ev.kind = .move
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: ev.kind = .drag
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ev.kind = .down; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
            ev.axFrameIndex = reserveAX(loc, event: ev)
            liveDelivered = true                              // reserveAX owned the single delivery
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            ev.kind = .up; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
            observeSurfacesAsync(at: ev.t)   // dialogs that appear just after the click
        case .scrollWheel:
            ev.kind = .scroll
            // Wheel delta was previously discarded entirely; without it no
            // scroll smoothing (or even scroll velocity) is possible.
            let lines = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let fixed = e.getIntegerValueField(CGEventField(rawValue: 93)!)   // FixedPtDeltaAxis1, 1/16 line
            ev.scrollDelta = lines != 0 ? Float(lines) : Float(fixed) / 16.0
        case .keyDown:
            ev.kind = .keyDown; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))   // key codes only, never characters
        case .keyUp: ev.kind = .keyUp; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: ev.kind = .flagsChanged
        default: return
        }
        if type == .keyDown { ev.axFrameIndex = reserveFocus(event: ev) }
        if type != .keyDown, !liveDelivered { liveEventHook.withLock { $0 }?(ev) }
        ring.push(ev)
    }

    /// Resolves a click's accessibility evidence. The old implementation
    /// coalesced every click to one hit-test per 120 ms and never looked at the
    /// window stack, so a click that *opened* a dialog resolved to nothing (or
    /// arrived a frame late) and the camera stayed on the background. Now each
    /// click compares the visible surface set against the last one and publishes
    /// a resolved frame for any new window/sheet/popover, stamped with the
    /// click's own time. In production the AX work is off the tap thread; with
    /// a headless probe it is synchronous and deterministic. Only the
    /// fine-grained point hit-test below stays throttled.
    private func reserveAX(_ p: CGPoint, event ev: InputEvent) -> UInt32 {
        let probeInstalled = debugSurfaceProbe.withLock { $0 } != nil
        guard axTrustedNow || probeInstalled else { return 0 }
        let index = reserveSlot()

        if probeInstalled {
            if let surfaces = debugSurfaceProbe.withLock({ $0 })?(ev) {
                emitNewSurfaces(surfaces, at: ev.t)
            }
        } else if running.withLock({ $0 }) {
            observeSurfacesAsync(at: ev.t)
        }

        // The click still reaches the live consumer exactly once, then the
        // throttled element hit-test enriches this same slot.
        var live = ev
        live.axFrameIndex = index
        liveEventHook.withLock { $0 }?(live)
        scheduleHitTest(p, index: index)
        return index
    }

    /// A native sheet often appears between down and up, not at down. Observe
    /// the release too: the resulting frame still carries the up event's time,
    /// within a frame or two of the click that caused it.
    private func observeSurfacesAsync(at time: Double) {
        guard debugSurfaceProbe.withLock({ $0 }) == nil, running.withLock({ $0 }) else { return }
        surfaceQ.async { [self] in
            guard isRunning else { return }
            emitNewSurfaces(WindowContent.visibleSurfaces(), at: time)
        }
    }

    /// Dialog frames live in their own reservations. The click keeps its own
    /// slot for the element it actually hit: the planner ignores a "dialog"
    /// that is also the click's target, so aliasing the two loses the re-aim.
    private func emitNewSurfaces(_ surfaces: [AXSurface], at time: Double) {
        for surface in newSurfaces(in: surfaces) {
            publish(dialogFrame(surface, at: time), at: reserveSlot())
        }
    }

    private func newSurfaces(in surfaces: [AXSurface]) -> [AXSurface] {
        surfaceWatch.withLock { watch -> [AXSurface] in
            if !watch.established {
                // First observation only seeds the baseline. A surface that is
                // already a dialog/sheet at that instant is still new evidence.
                watch.established = true
                watch.known = Set(surfaces.filter { $0.kind == .window }.map(\.id))
                return surfaces.filter { $0.kind != .window }
            }
            let fresh = surfaces.filter { !watch.known.contains($0.id) }
            watch.known = Set(surfaces.map(\.id))
            return fresh
        }
    }

    private func dialogFrame(_ surface: AXSurface, at clickTime: Double) -> AXFrame {
        let now = clickTime > 0 ? clickTime : HostClock.now()
        let sourceOrigin = origin.withLock { $0 }
        let scale = sourceScale.withLock { $0 }
        var frame = AXFrame(x: (surface.frame.minX - sourceOrigin.x) * scale.x,
                            y: (surface.frame.minY - sourceOrigin.y) * scale.y,
                            w: surface.frame.width * scale.x,
                            h: surface.frame.height * scale.y,
                            label: surface.axLabel)
        frame.sampledAt = now
        let value = epoch(for: surface.token)
        frame.anchor = FocusAnchor(epoch: value, sampledAt: now, host: nil,
                                   windowID: surface.id, appName: surface.appName,
                                   resolved: true)
        return frame
    }

    /// Bumps the focus epoch only when the resolved context actually changes —
    /// a new window/dialog is a context change exactly like a new text field.
    private func epoch(for context: String) -> UInt32 {
        focusState.withLock { state -> UInt32 in
            if let last = state.lastContext, last == context { return state.epoch }
            state.epoch += 1
            state.lastContext = context
            return state.epoch
        }
    }

    private func scheduleHitTest(_ p: CGPoint, index: UInt32) {
        let now = HostClock.now()
        let shouldQuery = mouseAX.withLock { state -> Bool in
            guard !state.inFlight, now - state.last >= 0.12 else { return false }
            state.inFlight = true
            state.last = now
            return true
        }
        guard shouldQuery else { return }
        axQ.async { [self] in
            defer { mouseAX.withLock { $0.inFlight = false } }
            guard isRunning, let f = queryAX(p) else { return }
            var frame = f
            let ctx = focusedAppContext()
            frame.sampledAt = HostClock.now()
            frame.anchor = FocusAnchor(epoch: focusState.withLock { $0.epoch },
                                       sampledAt: frame.sampledAt ?? HostClock.now(),
                                       host: ctx.host, windowID: ctx.windowID,
                                       appName: ctx.appName, resolved: true)
            publish(frame, at: index)
        }
    }

    /// Reserves this key-down's own AX slot. A reservation is never reused for
    /// another event: if a query is already in flight, this event gets its own
    /// (queued) reservation or none, never the in-flight one. The key itself is
    /// always delivered to the live consumer exactly once, even when AX is
    /// untrusted or the query later fails.
    private func reserveFocus(event ev: InputEvent) -> UInt32 {
        guard axTrustedNow else {
            // No AX at all: the key still reaches the live consumer, once,
            // with no invented focus frame.
            let bare = ev
            liveQ.async { [self] in liveEventHook.withLock { $0 }?(bare) }
            return 0
        }
        // The immediate delivery is the bare event: it says "a key was
        // pressed" and nothing else. A cached caret belongs to the *previous*
        // sample, so presenting it as this key's focus would aim the camera at
        // a stale caret until the query returns. The resolved sample follows
        // as an update to this same event identity.
        let cached = cachedFocusFrame()
        let kind: LiveFocusDelivery
        if liveEventHook.withLock({ $0 }) != nil { kind = .event }
        else if cached != nil, liveFocusHook.withLock({ $0 }) != nil { kind = .focus }
        else { kind = .none }

        let index = reserveSlot()
        var flightEvent = ev
        flightEvent.axFrameIndex = index
        let flight = FocusFlight(index: index, event: flightEvent, live: kind)
        let startNow = focusState.withLock { state -> Bool in
            if state.inFlight == nil { state.inFlight = flight; return true }
            // Latest wins for the follow-up. The superseded event keeps its
            // own unresolved slot and is never given this flight's frame.
            state.queued = flight
            return false
        }
        let delay = debugFocusDelay.withLock { $0 }
        liveQ.async { [self] in
            deliverLive(flight, cached: cached)
            if startNow {
                focusQ.asyncAfter(deadline: .now() + delay) { [self] in runFocusQuery(flight) }
            }
        }
        return index
    }

    /// A held sample is usable as this key's immediate target only when it is
    /// resolved, positive-sized, recent AND still the current focus context.
    /// A sample from before a dialog or a field change is stale evidence — it
    /// must never be presented as the new field's caret.
    private func cachedFocusFrame() -> AXFrame? {
        focusState.withLock { state -> AXFrame? in
            guard let g = state.lastGood, g.frame.w > 0, g.frame.h > 0,
                  g.frame.anchor?.resolved == true,
                  g.context == state.lastContext,
                  HostClock.now() - g.at <= 0.75 else { return nil }
            return g.frame
        }
    }

    /// Exactly one live delivery per key-down. A cached, same-context sample is
    /// the best evidence available before the query returns; otherwise the
    /// bare event says "typing happened" without claiming a target.
    private func deliverLive(_ flight: FocusFlight, cached: AXFrame?) {
        focusState.withLock { state in
            if flight.index > state.lastDelivered { state.lastDelivered = flight.index }
        }
        switch flight.live {
        case .focus:
            if let cached, let hook = liveFocusHook.withLock({ $0 }) {
                focusState.withLock { $0.lastFocusIndex = max($0.lastFocusIndex, flight.index) }
                hook(flight.event, cached)
            }
        case .event:
            liveEventHook.withLock { $0 }?(flight.event)
            // AppModel installs both hooks. Without this, address-bar typing
            // reached the live camera as a bare key and the camera waited for
            // a second AX round-trip before it knew which field to aim at.
            // The focus hook is a distinct channel, so this is not a duplicate
            // event; lastFocusIndex makes the later enrichment for this same
            // key a no-op. A cached frame is reused only when the field is
            // still the focused one — a new context gets its own epoch from
            // the query instead of inheriting the previous field's frame.
            let cachedContext = focusState.withLock { $0.lastContext }
            if let cached, let cachedContext, let hook = liveFocusHook.withLock({ $0 }),
               currentFocusContext(for: flight) == cachedContext {
                let claimed = focusState.withLock { state -> Bool in
                    guard flight.index > state.lastFocusIndex else { return false }
                    state.lastFocusIndex = flight.index
                    return true
                }
                if claimed { hook(flight.event, cached) }
            }
        case .none:
            break
        }
    }

    private func runFocusQuery(_ flight: FocusFlight) {
        guard isRunning else { finishFocusQuery(flight, probe: nil); return }
        finishFocusQuery(flight, probe: probeFocus(flight))
    }

    private func probeFocus(_ flight: FocusFlight) -> FocusProbe? {
        if let override = debugFocusProbe.withLock({ $0 }) { return override(flight.index, flight.event) }
        return liveFocusProbe()
    }

    /// Cheap check that a cached field is still the focused one before its rect
    /// is published as this key's immediate target. Uses the same probe the
    /// query would use (headless) or a context-only AX read (production), so a
    /// focus change cannot inherit the previous field's epoch.
    private func currentFocusContext(for flight: FocusFlight) -> String? {
        if debugFocusProbe.withLock({ $0 }) != nil { return probeFocus(flight)?.context }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        return focusedContextKey(system)
    }

    private func finishFocusQuery(_ flight: FocusFlight, probe: FocusProbe?) {
        var next: FocusFlight?
        if let probe {
            let now = HostClock.now()
            let settled = focusState.withLock { state -> (frame: AXFrame, queued: FocusFlight?) in
                if state.inFlight?.index == flight.index { state.inFlight = nil }
                let value: UInt32
                if let context = state.lastContext, context == probe.context { value = state.epoch }
                else { value = state.epoch + 1; state.lastContext = probe.context }
                state.epoch = value
                // The cached sample carries the same provenance as the stored
                // one: a consumer must be able to tell a fresh AX caret from a
                // held guess and to see which focus epoch it belongs to.
                var frame = probe.frame
                frame.sampledAt = now
                frame.anchor = FocusAnchor(epoch: value, sampledAt: now, host: probe.host,
                                           windowID: probe.windowID, appName: probe.appName,
                                           resolved: true)
                state.lastGood = (frame, now, value, probe.context)
                let queued = state.queued
                state.queued = nil
                return (frame, queued)
            }
            let frame = settled.frame
            next = settled.queued
            publish(frame, at: flight.index)
            // Enrichment is an update to the same event identity, never a
            // second key-down. If a newer key was already delivered, this
            // older sample must not pull the camera backwards.
            if flight.live == .event {
                var focused = flight.event
                let point = caretCenter(frame)
                focused.x = Float(point.x)
                focused.y = Float(point.y)
                liveQ.async { [self] in
                    let stale = focusState.withLock { state -> Bool in
                        guard flight.index > state.lastFocusIndex else { return true }
                        state.lastFocusIndex = flight.index
                        return false
                    }
                    guard !stale, let hook = liveFocusHook.withLock({ $0 }) else { return }
                    hook(focused, frame)
                }
            }
        } else {
            // A failed query is not "no evidence" when the same field is still
            // focused and a recent sample exists. Publish the held caret under
            // this event's own reservation, keeping its original anchor so the
            // planner can tell a held sample from a fresh one.
            let held: AXFrame? = focusState.withLock { state -> AXFrame? in
                guard let g = state.lastGood, g.frame.w > 0, g.frame.h > 0,
                      HostClock.now() - g.at <= 1.5, g.context == state.lastContext else { return nil }
                return g.frame
            }
            if let held, focusedContextKey(AXUIElementCreateSystemWide()) == focusState.withLock({ $0.lastContext }) {
                publish(held, at: flight.index)
                if flight.live == .event {
                    var focused = flight.event
                    let point = caretCenter(held)
                    focused.x = Float(point.x)
                    focused.y = Float(point.y)
                    liveQ.async { [self] in
                        let stale = focusState.withLock { state -> Bool in
                            guard flight.index > state.lastFocusIndex else { return true }
                            state.lastFocusIndex = flight.index
                            return false
                        }
                        guard !stale, let hook = liveFocusHook.withLock({ $0 }) else { return }
                        hook(focused, held)
                    }
                }
            }
            next = focusState.withLock { state -> FocusFlight? in
                if state.inFlight?.index == flight.index { state.inFlight = nil }
                let queued = state.queued
                state.queued = nil
                return queued
            }
        }
        if let next {
            focusState.withLock { $0.inFlight = next }
            let delay = debugFocusDelay.withLock { $0 }
            focusQ.asyncAfter(deadline: .now() + delay) { [self] in runFocusQuery(next) }
        }
    }

    private func caretCenter(_ frame: AXFrame) -> SIMD2<Double> {
        if let c = frame.caret { return SIMD2(c.x + c.w / 2, c.y + c.h / 2) }
        return SIMD2(frame.x + frame.w / 2, frame.y + frame.h / 2)
    }

    @MainActor private func refreshLauncherPIDs() {
        let pids = NSWorkspace.shared.runningApplications
            .filter { Self.launcherIDs.contains($0.bundleIdentifier ?? "") }
            .map(\.processIdentifier)
        launcherPIDs.withLock { $0 = pids }
    }

    private func startWindowOriginMonitor() {
        guard windowID != nil else { return }
        let source = DispatchSource.makeTimerSource(queue: windowOriginQ)
        source.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in self?.refreshWindowOrigin() }
        source.resume()
        windowOriginTimer = source
    }

    private func refreshWindowOrigin() {
        guard let windowID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary],
              let entry = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.origin.x.isFinite, frame.origin.y.isFinite else { return }
        origin.withLock { $0 = frame.origin }
    }

    private func enableAccessibility(_ app: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        if enhancedApps.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private struct FocusedInfo {
        var frame: AXFrame
        var token: String
        var appName: String?
        var windowID: Int?
        var host: String?
        var contextKey: String { "\(appName ?? "")|\(windowID.map(String.init) ?? "")|\(token)" }
    }

    private struct AppContext {
        var appName: String?
        var windowID: Int?
        var host: String?
    }

    private func launcherFocusInfo() -> FocusedInfo? {
        for pid in launcherPIDs.withLock({ $0 }) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.04)
            enableAccessibility(app)
            guard (attribute(app, kAXHiddenAttribute) as? Bool) != true else { continue }
            guard let value = attribute(app, kAXFocusedUIElementAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.04)
            guard (attribute(element, kAXHiddenAttribute) as? Bool) != true else { continue }
            var windowID: Int?
            if let value = attribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                AXUIElementSetMessagingTimeout(window, 0.04)
                guard (attribute(window, kAXHiddenAttribute) as? Bool) != true,
                      (attribute(window, kAXMinimizedAttribute) as? Bool) != true,
                      let windowFrame = frame(window), windowFrame.w > 0, windowFrame.h > 0 else { continue }
                if let number = attribute(window, "AXWindowNumber") as? NSNumber,
                   let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary],
                   !windows.contains(where: { ($0[kCGWindowNumber] as? NSNumber) == number }) { continue }
                if let number = attribute(window, "AXWindowNumber") as? NSNumber { windowID = number.intValue }
            }
            let role = (attribute(element, kAXRoleAttribute) as? String) ?? ""
            guard role.contains("Text") || role.contains("Search") || role.contains("ComboBox"),
                  let focused = frame(element) else { continue }
            return FocusedInfo(frame: focused, token: elementToken(element),
                               appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
                               windowID: windowID, host: nil)
        }
        return nil
    }

    /// Reads the focused element without making a second app/window pass when
    /// the caller already has the app element.
    private func focusedInfo(_ system: AXUIElement) -> FocusedInfo? {
        if let info = launcherFocusInfo() { return info }
        // Resolve the focused app before reading any element: a system-wide
        // focused-element query aimed at Lumen itself materialises our SwiftUI
        // accessibility on this queue, so this process is skipped up front.
        let app = focusedApplication(system)
        if let app, isSelf(app) { return nil }
        guard let value = attribute(app ?? system, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        guard !isSelf(element), let frame = frame(element) else { return nil }
        let ctx = app.map { appContext(for: $0, system: system) } ?? AppContext()
        return FocusedInfo(frame: frame, token: elementToken(element),
                           appName: ctx.appName, windowID: ctx.windowID, host: ctx.host)
    }

    private func liveFocusProbe() -> FocusProbe? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        guard let info = focusedInfo(system) else { return nil }
        // If focus moved while the frame was being read, the sample belongs to
        // neither the old nor the new field. Drop it rather than publish it.
        guard focusedContextKey(system) == info.contextKey else { return nil }
        var frame = info.frame
        frame.sampledAt = HostClock.now()
        return FocusProbe(frame: frame, context: info.contextKey, appName: info.appName,
                          windowID: info.windowID, host: info.host)
    }

    private func focusedContextKey(_ system: AXUIElement) -> String? {
        guard let info = focusedInfo(system) else { return nil }
        return info.contextKey
    }

    private func focusedApplication(_ system: AXUIElement) -> AXUIElement? {
        if let value = attribute(system, kAXFocusedApplicationAttribute),
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let app = value as! AXUIElement
            AXUIElementSetMessagingTimeout(app, 0.05)
            enableAccessibility(app)
            return app
        }
        return nil
    }

    private func focusedAppContext() -> AppContext {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        guard let app = focusedApplication(system) else { return AppContext() }
        return appContext(for: app, system: system)
    }

    /// App/window/host evidence for a sample. The host is derived only from a
    /// real browser AXURL, never from a title or a search, and the full URL is
    /// discarded immediately.
    private func appContext(for app: AXUIElement, system: AXUIElement) -> AppContext {
        guard !isSelf(app) else { return AppContext() }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let running = NSRunningApplication(processIdentifier: pid)
        let rawWindow = attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXWindowAttribute)
        let window: AXUIElement? = rawWindow.flatMap { raw -> AXUIElement? in
            CFGetTypeID(raw) == AXUIElementGetTypeID() ? (raw as! AXUIElement) : nil
        }
        var windowID: Int?
        var url: String?
        if let window {
            AXUIElementSetMessagingTimeout(window, 0.05)
            if let number = attribute(window, "AXWindowNumber") as? NSNumber { windowID = number.intValue }
            url = attribute(window, "AXURL") as? String ?? attribute(window, kAXURLAttribute) as? String
        }
        if url == nil { url = attribute(app, kAXURLAttribute) as? String }
        return AppContext(appName: running?.localizedName, windowID: windowID,
                          host: Self.verifiedHost(url: url, bundleID: running?.bundleIdentifier))
    }

    private func elementToken(_ element: AXUIElement) -> String {
        if let id = attribute(element, kAXIdentifierAttribute) as? String, !id.isEmpty { return "id:" + id }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        return "\(role)|\(subrole)|\(title)"
    }

    /// Known browser app identifiers. Capture does not integrate with a
    /// browser; it only recognises the app that already exposes AXURL.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser", "com.brave.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi"
    ]

    /// Returns a verified registrable host, or nil. A full URL never leaves
    /// this function: only the host component is returned.
    static func verifiedHost(url: String?, bundleID: String?) -> String? {
        guard let bundleID = bundleID, browserBundleIDs.contains(bundleID),
              var raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard normalized.count <= 253, normalized.contains("."), !normalized.contains(".."),
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }),
              normalized.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.count <= 63 }),
              normalized.range(of: #"^\d+(\.\d+){3}$"#, options: .regularExpression) == nil else { return nil }
        return normalized
    }

    private func startAXTimer() {
        let timer = DispatchSource.makeTimerSource(queue: axQ)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.sampleSecureFields() }
        timer.resume(); axTimer = timer
    }

    private func sampleSecureFields() {
        let trusted = AXIsProcessTrusted()
        axTrusted.withLock { $0 = trusted }
        guard trusted, isRunning else { return }
        // The 1500-node walk is the heaviest AX job in capture. Never let it
        // compete with a focus query for the same serial AX server.
        guard focusState.withLock({ $0.inFlight == nil }) else { return }
        let system = AXUIElementCreateSystemWide(), now = HostClock.now()
        AXUIElementSetMessagingTimeout(system, 0.03)
        guard let value = attribute(system, kAXFocusedApplicationAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let app = value as! AXUIElement
        // Lumen's own tree is never walked: this timer is the heaviest AX job
        // and must not drag our SwiftUI graph onto the AX queue.
        guard !isSelf(app) else { return }
        AXUIElementSetMessagingTimeout(app, 0.03)
        enableAccessibility(app)
        let ctx = appContext(for: app, system: system)
        let epoch = focusState.withLock { $0.epoch }
        guard let window = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() else { return }
        var pending = [window as! AXUIElement], visited = 0
        while visited < pending.count, visited < 1500, HostClock.now() - now < 0.25 {
            let element = pending[visited]
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.03)
            let labels = [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
                .compactMap { attribute(element, $0) as? String }.joined(separator: " ")
            if labels.range(of: "secure|email|password|passcode|card|cvv|cvc|ssn", options: .regularExpression.union(.caseInsensitive)) != nil,
               var field = frame(element), field.secure {
                field.sampledAt = now
                field.anchor = FocusAnchor(epoch: epoch, sampledAt: now, host: ctx.host,
                                           windowID: ctx.windowID, appName: ctx.appName,
                                           resolved: true)
                publish(field, at: reserveSlot())
            }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(max(1500 - pending.count, 0)))
            }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// AX is only ever read for other processes. Reading our own element tree
    /// makes AppKit materialise SwiftUI accessibility nodes on the calling
    /// queue, which evaluates main-actor isolated view bodies off the main
    /// thread and traps in dispatch_assert_queue (seen when the Settings
    /// window was frontmost during a recording).
    private func isSelf(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    private func queryAX(_ p: CGPoint) -> AXFrame? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &element) == .success,
              let element, !isSelf(element) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return frame(element)
    }

    private func frame(_ element: AXUIElement) -> AXFrame? {
        guard let pv = attribute(element, kAXPositionAttribute), let sv = attribute(element, kAXSizeAttribute),
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"]
        let label = names.compactMap { attribute(element, $0) as? String }.joined(separator: " ")
        let secure = label.range(of: "secure|email|password|passcode|card|cvv|cvc|ssn", options: .regularExpression.union(.caseInsensitive)) != nil
        let sourceOrigin = origin.withLock { $0 }
        let scale = sourceScale.withLock { $0 }
        var result = AXFrame(x: (pos.x - sourceOrigin.x) * scale.x, y: (pos.y - sourceOrigin.y) * scale.y,
                             w: size.width * scale.x, h: size.height * scale.y, secure: secure, label: label)
        result.sampledAt = HostClock.now()
        if let range = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var selection = CFRange(location: 0, length: 0)
            if AXValueGetValue(range as! AXValue, .cfRange, &selection) {
                let insertionPoint = selection.length == 0
                let glyphBefore = insertionPoint && selection.location > 0
                var probe = insertionPoint
                    ? CFRange(location: glyphBefore ? selection.location - 1 : 0, length: 1)
                    : selection
                if let probeValue = AXValueCreate(.cfRange, &probe) {
                    var bounds: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                 probeValue, &bounds) == .success,
                       let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                        var rect = CGRect.zero
                        if AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 {
                            if insertionPoint {
                                rect = CGRect(x: glyphBefore ? rect.maxX : rect.minX,
                                              y: rect.minY, width: 1, height: rect.height)
                            }
                            result.caret = AXFrame.Rect(x: (rect.minX - sourceOrigin.x) * scale.x, y: (rect.minY - sourceOrigin.y) * scale.y,
                                                       w: max(rect.width * scale.x, 1), h: rect.height * scale.y)
                        }
                    }
                }
            }
        }
        return result
    }
}
