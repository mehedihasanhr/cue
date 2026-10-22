import Foundation

// `RecordKitCrashProbe <folder> <name>`
//
// Starts a made-up take in <folder> and records it in real time, saying how far it has got
// on standard output after every half second:
//
//     package /path/to/<name>.cuerec
//     recorded 0.5
//     recorded 1.0
//
// It never finishes the take. The test that runs it kills it with SIGKILL part-way through,
// which is a crash as far as the files are concerned. If nobody kills it, it gives up after
// thirty seconds and exits without finishing either, so a test that fails can never leave
// it running.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: RecordKitCrashProbe <folder> <name>\n".utf8))
    exit(64)
}

do {
    let take = try SyntheticTake(named: arguments[2], in: URL(fileURLWithPath: arguments[1]))
    print("package \(take.package.url.path(percentEncoded: false))")
    var seconds = 0.0
    while seconds < 30 {
        take.record(seconds: 0.5)
        seconds += 0.5
        print("recorded \(seconds)")
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
