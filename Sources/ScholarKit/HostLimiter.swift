import Foundation

/// The two services the resolver asks (plan.md section 8.7). Nothing else is called, except the host of an
/// open-access PDF the user asked for.
enum ServiceHost: String, Sendable, CaseIterable {
    case crossref = "api.crossref.org"
    case openAlex = "api.openalex.org"
}

/// The limits of plan.md section 8.7 for one host.
struct HostPolicy: Sendable, Equatable {
    var requestsPerSecond: Double
    var maxConcurrent: Int

    /// Seconds between two request starts. The bucket holds one token, so requests never come in a burst.
    var interval: Double { 1 / requestsPerSecond }

    /// Public pool: 1 request/s, 1 at a time. With a contact address (the polite pool): 3 requests/s, 3 at a time.
    static func crossref(polite: Bool) -> HostPolicy {
        polite ? HostPolicy(requestsPerSecond: 3, maxConcurrent: 3) : HostPolicy(requestsPerSecond: 1, maxConcurrent: 1)
    }

    /// 5 requests/s, half of what OpenAlex allows without a key.
    static let openAlex = HostPolicy(requestsPerSecond: 5, maxConcurrent: 5)
}

/// One token bucket per host, with a cap on the requests in flight to it. `acquire` waits for a slot (first come,
/// first served) and then for the host's next start time; the caller holds the slot until `release`, whether the
/// request succeeded or not. After a 429 or a 5xx, `holdOff` keeps every request to that host back for the time
/// the server asked for.
actor HostLimiter {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>   // true: admitted with a slot; false: withdrawn (cancelled)
    }

    private struct Gate {
        var policy = HostPolicy.crossref(polite: false)
        var nextStart: Double = 0                             // uptime before which no request to the host starts
        var inFlight = 0
        var waiters: [Waiter] = []
    }

    private let clock: any ResolverClock
    private var gates: [ServiceHost: Gate] = [:]
    private var lastWaiterID: UInt64 = 0

    init(clock: any ResolverClock) {
        self.clock = clock
    }

    /// Takes a slot and waits for the host's next start time. Throws `CancellationError`, holding nothing, when the
    /// task is cancelled while it waits. The policy is the one in force now (settings are read at call time).
    func acquire(_ host: ServiceHost, policy: HostPolicy) async throws {
        gates[host, default: Gate()].policy = policy
        admitWaiters(host)                                    // a larger allowance applies to those already waiting
        try await takeSlot(host)
        let now = clock.uptime()
        let start = max(now, gates[host, default: Gate()].nextStart)
        gates[host, default: Gate()].nextStart = start + policy.interval
        guard start > now else { return }
        do {
            try await clock.sleep(untilUptime: start)
        } catch {
            release(host)
            throw error
        }
    }

    /// Gives back the slot taken by `acquire`.
    func release(_ host: ServiceHost) {
        guard var gate = gates[host], gate.inFlight > 0 else { return }
        gate.inFlight -= 1
        gates[host] = gate
        admitWaiters(host)
    }

    /// No request to the host starts earlier than `seconds` from now.
    func holdOff(_ host: ServiceHost, seconds: Double) {
        let until = clock.uptime() + max(0, seconds)
        let current = gates[host, default: Gate()].nextStart
        gates[host, default: Gate()].nextStart = max(current, until)
    }

    /// Slots held and tasks waiting for one (for tests, which wait on this instead of on time).
    func occupancy(_ host: ServiceHost) -> (inFlight: Int, waiting: Int) {
        let gate = gates[host, default: Gate()]
        return (gate.inFlight, gate.waiters.count)
    }

    // ---- slots ----

    private func takeSlot(_ host: ServiceHost) async throws {
        let gate = gates[host, default: Gate()]
        if gate.waiters.isEmpty && gate.inFlight < gate.policy.maxConcurrent {
            gates[host, default: Gate()].inFlight += 1
            return
        }
        lastWaiterID += 1
        let id = lastWaiterID
        // The waiter is queued before this task first suspends, so a withdrawal (which needs the actor) always
        // finds it, even when the task was cancelled before it got here.
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                gates[host, default: Gate()].waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.withdraw(host, id: id) }
        }
        if !admitted { throw CancellationError() }
    }

    /// Hands free slots to the waiters, in order of arrival.
    private func admitWaiters(_ host: ServiceHost) {
        guard var gate = gates[host] else { return }
        var admitted: [Waiter] = []
        while gate.inFlight < gate.policy.maxConcurrent, !gate.waiters.isEmpty {
            admitted.append(gate.waiters.removeFirst())
            gate.inFlight += 1
        }
        gates[host] = gate
        for waiter in admitted { waiter.continuation.resume(returning: true) }
    }

    /// A cancelled waiter leaves the queue without a slot; one that was admitted meanwhile is not affected.
    private func withdraw(_ host: ServiceHost, id: UInt64) {
        guard var gate = gates[host], let index = gate.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = gate.waiters.remove(at: index)
        gates[host] = gate
        waiter.continuation.resume(returning: false)
    }
}
