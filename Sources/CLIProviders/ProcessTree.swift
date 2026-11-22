import Darwin

/// A process as it was seen at one moment: its id and its start time. A signal is only ever sent to a process whose
/// start time still matches, so a process id that the system has given to an unrelated process in the meantime is
/// never hit (plan.md section 5.6.3: the whole tree is killed, collected with proc_listchildpids).
struct ProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startTime: UInt64          // microseconds since 1970, from proc_pidinfo
}

enum ProcessTree {
    private static let bsdInfoSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    private static let zombieStatus: UInt32 = 5            // SZOMB in <sys/proc.h>

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let written = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bsdInfoSize)
        return written == bsdInfoSize ? info : nil
    }

    static func identity(of pid: pid_t) -> ProcessIdentity? {
        guard let info = bsdInfo(pid) else { return nil }
        return ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    /// True while the process exists and is not a zombie waiting to be reaped.
    static func isRunning(_ pid: pid_t) -> Bool {
        if let info = bsdInfo(pid) { return info.pbi_status != zombieStatus }
        return Darwin.kill(pid, 0) == 0
    }

    /// True while this very process (same id and start time) exists and is not a zombie.
    static func isRunning(_ process: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(process.pid) else { return false }
        let start = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        return start == process.startTime && info.pbi_status != zombieStatus
    }

    static func children(of pid: pid_t) -> [pid_t] {
        var capacity = 64
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
            guard count > 0 else { return [] }
            // The return value is a count of ids on current systems; reading it as a count and dropping zeros is also
            // correct if it were a count of bytes.
            if Int(count) < capacity || capacity >= 16_384 {
                return buffer.prefix(min(Int(count), capacity)).filter { $0 > 0 }
            }
            capacity *= 4
        }
    }

    /// The process and every descendant that exists now, parents before children.
    static func snapshot(root: pid_t) -> [ProcessIdentity] {
        guard let rootIdentity = identity(of: root) else { return [] }
        var result = [rootIdentity]
        var seen: Set<pid_t> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children(of: parent) where !seen.contains(child) {
                seen.insert(child)
                if let id = identity(of: child) {
                    result.append(id)
                    queue.append(child)
                }
            }
            if seen.count > 4_096 { break }        // a fork bomb is not our problem to enumerate
        }
        return result
    }

    /// Sends `signal` to every listed process that still has the start time it was listed with.
    static func signal(_ processes: [ProcessIdentity], _ signal: Int32) {
        for process in processes where isRunning(process) {
            _ = Darwin.kill(process.pid, signal)
        }
    }

    /// The members of process group `group` that exist now.
    static func groupMembers(_ group: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 1_024)
        let count = buffer.withUnsafeMutableBytes { proc_listpgrppids(group, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
    }

    /// SIGKILL to every running member of the root's process group that started no earlier than the root.
    ///
    /// `Process` makes the CLI the leader of a group of its own, and its children stay in it unless they leave on
    /// purpose. This catches a child whose fork was under way while the group was being killed: it is not in any
    /// snapshot, and once its parent is dead it is not anyone's descendant either. A group id cannot be given to
    /// another process while the group still has members, and the start time rules out an unrelated process that
    /// had the id before.
    static func killGroup(of root: ProcessIdentity) {
        for pid in groupMembers(root.pid) {
            guard let member = identity(of: pid), member.startTime >= root.startTime, isRunning(member) else { continue }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }
}
