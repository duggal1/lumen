import Foundation
import LumenProject
import LumenCore

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/lumen-seed")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let bundle = try ProjectBundle.create(named: "Seed", in: outDir)
let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 40, backingScale: 2, originX: 0, originY: 0)
let meta = ProjectMeta(name: "Seed", source: src, clock: RecordingClock())
var tl = Timeline(duration: 40)
tl.clips = [TimelineClip(path: outDir.appendingPathComponent("screen.mov").path, duration: 40, start: 0)]
let base = "/Users/harshitduggal/workspace/Lumen/studio/App/public/assets/music"
var a = AudioLane(role: .music, path: "\(base)/calm/Majestic Hills - Kevin MacLeod [USUAN1100423].mp3", placement: 0, gainDb: -18)
var b = AudioLane(role: .music, path: "\(base)/epic/Noble Race - Kevin MacLeod [USUAN1100888].mp3", placement: 12, gainDb: -16)
b.trimDuration = 22
var c = AudioLane(role: .music, path: "\(base)/futuristic/On the Run ｜ Dark Sci-Fi⧸Orchestral Original [JOVvb7tIW8Q].mp3", placement: 6, gainDb: -20)
c.trimDuration = 14
tl.audio.lanes = [a, b, c]
let file = ProjectFile(meta: meta, timeline: tl)
try bundle.save(file)
print("saved \(bundle.projectURL.path)")
