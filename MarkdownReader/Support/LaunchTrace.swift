import Foundation

/// Optional startup timing, printed to stderr when MDR_TRACE=1 is set.
enum LaunchTrace {
    static let enabled = ProcessInfo.processInfo.environment["MDR_TRACE"] == "1"
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }()

    static func mark(_ label: String) {
        guard enabled else { return }
        FileHandle.standardError.write(String(format: "[trace] %6.1f ms  %@\n",
                                              Date().timeIntervalSince(processStart) * 1000, label).data(using: .utf8)!)
    }
}
