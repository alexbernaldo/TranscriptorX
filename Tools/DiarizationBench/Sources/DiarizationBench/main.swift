import Darwin
import FluidAudio
import Foundation

// Usage: DiarizationBench <audio> <models-dir> <config: default|precise> <out.tsv>
//
// Runs FluidAudio's offline diarizer exactly as the app does (`default`) or with the
// higher-accuracy settings FluidAudio documents (`precise`: stepRatio 0.1 and no
// minimum embedding segment duration), and writes the raw turns before any
// assignment to text: start, end, speaker.

let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write("usage: DiarizationBench <audio> <models-dir> <default|precise> <out.tsv>\n".data(using: .utf8)!)
    exit(2)
}
let audio = URL(fileURLWithPath: args[1])
let modelsDir = URL(fileURLWithPath: args[2], isDirectory: true)
let configName = args[3]
let output = URL(fileURLWithPath: args[4])

var config = OfflineDiarizerConfig.default
switch configName {
case "default":
    break
case "precise":
    config.segmentationStepRatio = 0.1
    config.embedding.minSegmentDurationSeconds = 0.0
default:
    FileHandle.standardError.write("unknown config \(configName)\n".data(using: .utf8)!)
    exit(2)
}

func peakRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576  // bytes on macOS
}

let loadStart = Date()
let models = try await OfflineDiarizerModels.load(from: modelsDir, configuration: nil) { _ in }
let loadSeconds = Date().timeIntervalSince(loadStart)

let manager = OfflineDiarizerManager(config: config)
manager.initialize(models: models)

let start = Date()
let result = try await manager.process(audio) { _, _ in }
let seconds = Date().timeIntervalSince(start)

var tsv = "start\tend\tspeaker\n"
for segment in result.segments {
    tsv += String(format: "%.3f\t%.3f\t%@\n", segment.startTimeSeconds, segment.endTimeSeconds, segment.speakerId)
}
try tsv.write(to: output, atomically: true, encoding: .utf8)

let speakers = Set(result.segments.map(\.speakerId)).count
print(String(format: "config=%@ segments=%d speakers=%d load=%.1fs process=%.1fs peakRSS=%.0fMB",
             configName, result.segments.count, speakers, loadSeconds, seconds, peakRSSMegabytes()))
