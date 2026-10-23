import Darwin
import Foundation

// Observes only the selected PID. No task suspension, debugger attachment, game writes or affinity changes.
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    fputs("usage: PerformanceRecorder <pid> <new-output-folder>\n", stderr)
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let sampleURL = output.appendingPathComponent("resources.ndjson")
guard fm.createFile(atPath: sampleURL.path, contents: nil) else { exit(1) }
let samples = try FileHandle(forWritingTo: sampleURL)
@MainActor func write(_ row: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    data.append(10)
    try samples.write(contentsOf: data)
}
@MainActor func outputHandle(_ name: String) throws -> FileHandle {
    let path = output.appendingPathComponent(name).path
    fm.createFile(atPath: path, contents: nil)
    return try FileHandle(forWritingTo: URL(fileURLWithPath: path))
}
let metal = Process()
metal.executableURL = URL(fileURLWithPath: "/usr/bin/log")
metal.arguments = ["stream", "--style", "ndjson", "--level", "debug", "--predicate",
                   "processID == \(pid) AND (subsystem CONTAINS[c] 'metal' OR eventMessage CONTAINS[c] 'metal-HUD')"]
let metalHandle = try outputHandle("metal.ndjson")
let errorHandle = try outputHandle("metal-errors.txt")
metal.standardOutput = metalHandle; metal.standardError = errorHandle; metal.standardInput = FileHandle.nullDevice
try metal.run()

var initial = proc_taskinfo()
let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &initial, taskSize) == taskSize else {
    metal.terminate()
    try write(["event": "error", "message": "Cannot read selected process", "errno": errno])
    exit(1)
}
let started = ProcessInfo.processInfo.systemUptime
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
@MainActor func taskNanoseconds(_ ticks: UInt64) -> UInt64 {
    let numerator = UInt64(timebase.numer), denominator = UInt64(timebase.denom)
    return (ticks / denominator) * numerator + ((ticks % denominator) * numerator) / denominator
}
var previousTime = started
var lastSystem: TimeInterval = -.infinity
var threadCapacity = max(256, Int(initial.pti_threadnum) + 128)
var tick = 0
try write(["event": "start", "pid": pid, "wall": Date().timeIntervalSince1970,
           "uptime": started, "interval_ms": 100,
           "cpu_time_unit": "nanoseconds; task Mach ticks converted using mach_timebase_info; thread values already nanoseconds",
           "thread_id_kind": "pthread handle from PROC_PIDLISTTHREADS; duplicate handles excluded",
           "thread_state": "1=running,2=stopped,3=waiting,4=uninterruptible,5=halted",
           "scope": "game PID only; state is an instantaneous observation, not a wait-duration measurement"])
var reason = "time-limit"
while ProcessInfo.processInfo.systemUptime - started < 600 {
    let begin = ProcessInfo.processInfo.systemUptime
    if fm.fileExists(atPath: output.appendingPathComponent("STOP").path) { reason = "user-finished"; break }
    var task = proc_taskinfo()
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { reason = "process-ended"; break }
    threadCapacity = max(threadCapacity, Int(task.pti_threadnum) + 128)
    var tids = [UInt64](repeating: 0, count: threadCapacity)
    let bytes = tids.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count))
    }
    var threads: [[String: Any]] = []
    if bytes > 0 {
        for tid in Set(tids.prefix(Int(bytes) / MemoryLayout<UInt64>.size)) {
            var thread = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            // Verified on the translated game: LISTTHREADS returns pthread handles;
            // flavor 15 returns ESRCH. Zero is a valid handle for Rosetta's server.
            guard proc_pidinfo(pid, PROC_PIDTHREADINFO, tid, &thread, size) == size else { continue }
            let name = withUnsafeBytes(of: thread.pth_name) { raw -> String in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            threads.append(["tid": tid, "name": name, "user_ns": thread.pth_user_time,
                            "system_ns": thread.pth_system_time, "state": thread.pth_run_state,
                            "priority": thread.pth_curpri])
        }
    }
    var row: [String: Any] = ["event": "sample", "wall": Date().timeIntervalSince1970,
                              "uptime": begin, "elapsed": begin - started, "interval": begin - previousTime,
                              "user_ns": taskNanoseconds(task.pti_total_user), "system_ns": taskNanoseconds(task.pti_total_system),
                              "resident_bytes": task.pti_resident_size, "pageins": task.pti_pageins,
                              "faults": task.pti_faults, "context_switches": task.pti_csw,
                              "mach_calls": task.pti_syscalls_mach, "unix_calls": task.pti_syscalls_unix,
                              "thread_count": task.pti_threadnum, "threads": threads]
    if begin - lastSystem >= 1 {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if ok == 0 {
            row["disk_read_bytes"] = usage.ri_diskio_bytesread
            row["disk_write_bytes"] = usage.ri_diskio_byteswritten
            row["footprint_bytes"] = usage.ri_phys_footprint
        }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            row["system_vm"] = ["page_bytes": UInt64(sysconf(_SC_PAGESIZE)), "compressions": vm.compressions,
                                "decompressions": vm.decompressions, "swapins": vm.swapins, "swapouts": vm.swapouts,
                                "compressor_pages": vm.compressor_page_count]
        }
        row["thermal_state"] = ProcessInfo.processInfo.thermalState.rawValue
        lastSystem = begin
    }
    row["observer_collection_ms"] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    try write(row)
    previousTime = begin
    tick += 1
    if tick % 10 == 0 { try samples.synchronize() }
    Thread.sleep(forTimeInterval: max(0.005, 0.1 - (ProcessInfo.processInfo.systemUptime - begin)))
}
try write(["event": "end", "wall": Date().timeIntervalSince1970, "reason": reason])
if metal.isRunning { metal.terminate() }
// Bound shutdown even if the system logger fails to exit promptly.
let logDeadline = Date().addingTimeInterval(3)
while metal.isRunning && Date() < logDeadline { Thread.sleep(forTimeInterval: 0.05) }
if metal.isRunning { kill(metal.processIdentifier, SIGKILL) }
try samples.close(); try metalHandle.close(); try errorHandle.close()
print("Recording finished: \(reason). Game process was not modified or stopped.")
