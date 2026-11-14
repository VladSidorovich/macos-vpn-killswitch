import AppKit
import KillSwitchClient
import KillSwitchCore

/// Read-only: polls `status` off the main thread and feeds the controller. Never sends a verb that changes state.
final class Poller {
    private let client: DaemonClient
    private let onState: (UIState, IPCResponse?) -> Void
    private let queue = DispatchQueue(label: "killswitch.poller")
    private var inFlight = false
    private var lastGood: Date?
    private var streak = 0
    private var lastResponse: IPCResponse?
    private var timer: Timer?

    init(client: DaemonClient, onState: @escaping (UIState, IPCResponse?) -> Void) {
        self.client = client
        self.onState = onState
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [client] in
            var response: IPCResponse?
            var failure: ClientError?
            do { response = try client.send(IPCRequest(verb: .status)) }
            catch let e as ClientError { failure = e } catch let e { failure = .other("\(e)") }
            DispatchQueue.main.async { [weak self] in self?.finish(response, failure) }
        }
    }

    private func finish(_ response: IPCResponse?, _ error: ClientError?) {
        inFlight = false
        let now = Date()
        if let r = response { lastGood = now; lastResponse = r
            streak = UIStateDeriver.looksInconsistent(r) ? streak + 1 : 0 }
        let snap = Snapshot(response: error == nil ? response : nil, error: error,
                            ageOfLastGood: lastGood.map { now.timeIntervalSince($0) },
                            inconsistentStreak: streak, now: now)
        onState(UIStateDeriver.derive(snap), error == nil ? response : nil)
    }
}
