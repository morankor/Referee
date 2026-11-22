import Foundation

/// The cold streams the engine's jobs return (plan.md sections 2.3 and 6.1).
///
/// - Cold: the job's task starts when the stream is first iterated. A stream that is never iterated sends nothing.
/// - The job runs in a task of its own and hands its events over through `JobSink`; it always ends with one final event
///   (a `.finished`), which `finish(final:)` delivers after every event before it.
/// - Cancelling the consumer cancels the job. A consumer cancelled while it waits for the next event still receives the
///   final event (the job's `.finished` with a cancelled run), skipping anything in between, and then the end of the
///   stream. A consumer cancelled between two events sees the stream end at once, as with any
///   `AsyncThrowingStream(unfolding:)`: a consumer must treat an end without `.finished` as a cancellation.
/// - A consumer that drops the stream also cancels the job.
/// - The stream never throws: failures are reported in the final event's run status (section 6.6).
enum JobStream {
    static func make<Event: Sendable>(_ job: @escaping @Sendable (JobSink<Event>) async -> Void) -> AsyncThrowingStream<Event, Error> {
        let handle = JobHandle(channel: JobChannel<Event>(job: job))
        return AsyncThrowingStream(unfolding: {
            handle.channel.startIfNeeded()
            return await handle.channel.next()
        })
    }
}

/// What a job uses to emit its events.
struct JobSink<Event: Sendable>: Sendable {
    fileprivate let channel: JobChannel<Event>
    func send(_ event: Event) { channel.send(event) }
    /// The last event. Anything sent afterwards is dropped.
    func finish(final event: Event) { channel.finish(final: event) }
}

/// Owned only by the stream's closure: when the stream goes away, so does the job.
private final class JobHandle<Event: Sendable>: @unchecked Sendable {
    let channel: JobChannel<Event>
    init(channel: JobChannel<Event>) { self.channel = channel }
    deinit { channel.cancelJob() }
}

/// A queue between the job's task and the consumer, guarded by a lock. Its waiting is not cancellable by itself: the
/// consumer's cancellation is forwarded to the job, and the consumer is answered when the job's final event arrives.
private final class JobChannel<Event: Sendable>: @unchecked Sendable {
    private enum Ready {
        case event(Event)
        case end
        var value: Event? {
            if case .event(let event) = self { return event }
            return nil
        }
    }

    private let lock = NSLock()
    private let job: @Sendable (JobSink<Event>) async -> Void
    private var task: Task<Void, Never>?
    private var started = false
    private var buffer: [Event] = []
    private var head = 0
    private var finalEvent: Event?
    private var ended = false
    private var finalDelivered = false
    private var consumerCancelled = false
    private var waiter: CheckedContinuation<Event?, Never>?

    init(job: @escaping @Sendable (JobSink<Event>) async -> Void) { self.job = job }

    func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let sink = JobSink(channel: self)
        let job = self.job
        task = Task { await job(sink) }
    }

    func cancelJob() {
        lock.lock()
        let running = task
        lock.unlock()
        running?.cancel()
    }

    func next() async -> Event? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Event?, Never>) in
                lock.lock()
                if let ready = readyLocked() {
                    lock.unlock()
                    continuation.resume(returning: ready.value)
                } else {
                    waiter = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            consumerCancelled = true
            var resume: (CheckedContinuation<Event?, Never>, Event?)?
            if let waiting = waiter, let ready = readyLocked() {
                waiter = nil
                resume = (waiting, ready.value)
            }
            let running = task
            lock.unlock()
            running?.cancel()
            if let (waiting, value) = resume { waiting.resume(returning: value) }
        }
    }

    fileprivate func send(_ event: Event) {
        lock.lock()
        guard !ended, !consumerCancelled else { lock.unlock(); return }
        if let waiting = waiter, head == buffer.count {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: event)
            return
        }
        buffer.append(event)
        lock.unlock()
    }

    fileprivate func finish(final event: Event) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        finalEvent = event
        var resume: (CheckedContinuation<Event?, Never>, Event?)?
        if let waiting = waiter, let ready = readyLocked() {
            waiter = nil
            resume = (waiting, ready.value)
        }
        lock.unlock()
        if let (waiting, value) = resume { waiting.resume(returning: value) }
    }

    /// What the consumer gets now, or nil when it has to wait. Call with the lock held.
    private func readyLocked() -> Ready? {
        if consumerCancelled {
            guard ended else { return nil }
            buffer.removeAll()
            head = 0
            return finalLocked()
        }
        if head < buffer.count {
            let event = buffer[head]
            head += 1
            if head > 64, head * 2 > buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            return .event(event)
        }
        return ended ? finalLocked() : nil
    }

    private func finalLocked() -> Ready {
        guard !finalDelivered, let event = finalEvent else { return .end }
        finalDelivered = true
        return .event(event)
    }
}
