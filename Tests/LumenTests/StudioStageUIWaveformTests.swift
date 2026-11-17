import Testing
import Foundation
@testable import LumenUI

/// The audio tape's live state: head and played cells advance with the
/// playhead, live level comes from the envelope, and silence stays a gap.
@Suite struct StudioStageUIWaveformTests {
    private func tone(seconds: Double = 10) -> [Float] {
        // A small offset keeps every sampled column above digital silence, so
        // the live-level assertion measures the mapping and not a sine zero.
        (0..<Int(seconds * 100)).map { i in
            Float(0.5 * sin(Double(i) * 2 * .pi * 220 / 100) + 0.05)
        }
    }

    @Test func emptyEnvelopeIsAnHonestEmptyBand() {
        let s = WaveformPlaybackState(peaks: [], duration: 10, playhead: 3, isPlaying: true)
        let snap = s.snapshot(columns: WaveformPlaybackState.tapeColumns)
        #expect(snap.isEmpty)
        #expect(!snap.isLive)
        #expect(snap.headColumn == 0)
        #expect(snap.playedColumns == 0)
        #expect(snap.activeLevel == 0)
        #expect(snap == .empty)
    }

    @Test func digitalSilenceIsNeverColouredOrLive() {
        let silent = [Float](repeating: 0, count: 1000)
        let s = WaveformPlaybackState(peaks: silent, duration: 10, playhead: 5, isPlaying: true)
        let snap = s.snapshot(columns: 60)
        #expect(!snap.isEmpty)
        #expect(snap.isSilent)
        #expect(!snap.isLive)
        #expect(snap.activeLevel == 0)
    }

    @Test func playedFrontAdvancesWithThePlayhead() {
        let s = WaveformPlaybackState(peaks: tone(), duration: 10, isPlaying: true)
        let columns = WaveformPlaybackState.tapeColumns
        let start = s.snapshot(columns: columns)
        let middle = s.updated(playhead: 5, isPlaying: true).snapshot(columns: columns)
        let end = s.updated(playhead: 9.9, isPlaying: true).snapshot(columns: columns)
        #expect(start.headColumn == 0)
        #expect(start.playedColumns == 0)
        #expect(middle.headColumn == columns / 2)
        #expect(middle.playedColumns == middle.headColumn)
        #expect(end.headColumn == columns - 1)
        #expect(start.headColumn < middle.headColumn)
        #expect(middle.headColumn < end.headColumn)
    }

    @Test func liveLevelComesFromTheEnvelopeAndPausingFreezesIt() {
        let s = WaveformPlaybackState(peaks: tone(), duration: 10, playhead: 2, isPlaying: true)
        let playing = s.snapshot(columns: 60)
        #expect(playing.isLive)
        #expect(playing.activeLevel > 0)
        #expect((0...4).contains(playing.activeLevel))
        let paused = s.updated(playhead: 2, isPlaying: false).snapshot(columns: 60)
        #expect(!paused.isLive)
        #expect(paused.headColumn == playing.headColumn)
        #expect(paused.activeLevel == playing.activeLevel)
    }

    @Test func seekingBackwardsMovesTheHeadBack() {
        let s = WaveformPlaybackState(peaks: tone(), duration: 10, isPlaying: true)
        let late = s.updated(playhead: 8, isPlaying: true).snapshot(columns: 60)
        let early = s.updated(playhead: 1, isPlaying: true).snapshot(columns: 60)
        #expect(early.headColumn < late.headColumn)
        #expect(early.playedColumns < late.playedColumns)
    }

    @Test func outOfRangeAndNonFiniteTimesClamp() {
        let s = WaveformPlaybackState(peaks: tone(), duration: 10, playhead: 100, isPlaying: true)
        #expect(s.snapshot(columns: 60).headColumn == 59)
        let early = WaveformPlaybackState(peaks: tone(), duration: 10, playhead: -5, isPlaying: true)
        #expect(early.snapshot(columns: 60).headColumn == 0)
        let broken = WaveformPlaybackState(peaks: tone(), duration: .nan, playhead: .infinity, isPlaying: true)
        #expect(broken.snapshot(columns: 60).headColumn == 0)
        #expect(!broken.snapshot(columns: 60).isLive)
        #expect(WaveformPlaybackState(peaks: tone(), duration: 10, playhead: 3).snapshot(columns: 0).headColumn == 0)
    }

    @Test func snapshotsAreDeterministic() {
        let a = WaveformPlaybackState(peaks: tone(), duration: 10, playhead: 4.25, isPlaying: true)
        let b = WaveformPlaybackState(peaks: tone(), duration: 10, playhead: 4.25, isPlaying: true)
        #expect(a.snapshot(columns: 60) == b.snapshot(columns: 60))
    }
}
