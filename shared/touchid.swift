// Asks the person at this Mac for Touch ID (or their login password) and
// exits 0 only when they give it. Usage: swift touchid.swift "<reason>"
import Foundation
import LocalAuthentication

let reason = CommandLine.arguments.dropFirst().joined(separator: " ")
let context = LAContext()
var error: NSError?
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    FileHandle.standardError.write(Data("Touch ID unavailable: \(error?.localizedDescription ?? "unknown")\n".utf8))
    exit(2)
}
let done = DispatchSemaphore(value: 0)
var granted = false
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason.isEmpty ? "approve a live change" : reason) { ok, _ in
    granted = ok
    done.signal()
}
done.wait()
exit(granted ? 0 : 1)
