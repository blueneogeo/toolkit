import Foundation

// Usage: parity-swift <list-file>
// Each line of the list file is "<file on disk>\t<path to report>". Prints the parity JSON on stdout.

guard CommandLine.arguments.count == 2,
      let list = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
else {
    FileHandle.standardError.write(Data("usage: parity-swift <list-file>\n".utf8))
    exit(2)
}

var files: [[String: Any]] = []
for line in list.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    guard let source = try? String(contentsOfFile: parts[0], encoding: .utf8) else {
        FileHandle.standardError.write(Data("parity-swift: cannot read \(parts[0])\n".utf8))
        exit(1)
    }
    files.append(FileExtractor(path: parts[1], source: source).extract())
}

let output: [String: Any] = ["schema": 1, "platform": "ios", "files": files]
do {
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("parity-swift: \(error)\n".utf8))
    exit(1)
}
