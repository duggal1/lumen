import Testing
import LumenProject

@Test func musicPreviewAndExportShareLoopAndFadeSamples() {
    let track = MusicBed.PCM(left: [1, 1, 1, 1, 1, 1, 1, 1], right: [1, 1, 1, 1, 1, 1, 1, 1])
    let bed = MusicBed(assetPath: "fixture", placement: 0, gainDb: 0, fadeIn: 0, fadeOut: 0)
    let plan = MusicBed.plan(bed, track: track, outputSamples: 13, fs: 8)
    let full = MusicBed.render(plan, track: track, duck: nil, outputSamples: 13, fs: 8)
    #expect(full.left == Array(repeating: Float(1), count: 13))
    for i in 0..<13 {
        let frame = MusicBed.sample(plan, track: track, duck: nil, at: i, fs: 8)
        #expect(frame.left == full.left[i])
        #expect(frame.right == full.right[i])
    }
}

@Test func musicPlanRejectsExtremeTimesWithoutIntegerTrap() {
    let track = MusicBed.PCM(left: [0.2, 0.4], right: [0.2, 0.4])
    let bed = MusicBed(assetPath: "fixture", placement: .greatestFiniteMagnitude)
    let plan = MusicBed.plan(bed, track: track, outputSamples: 48_000, fs: 48_000)
    #expect(!plan.isRenderable)
    let trim = MusicBed(assetPath: "fixture", trimStart: .greatestFiniteMagnitude)
    #expect(!MusicBed.plan(trim, track: track, outputSamples: 48_000, fs: 48_000).isRenderable)
    #expect(MusicBed.duckGain([0.5], atSample: Int.max, fs: 48_000) == 0.5)
}
