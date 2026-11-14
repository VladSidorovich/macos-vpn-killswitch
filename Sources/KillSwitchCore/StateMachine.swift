import Foundation

public enum Mode: String, Codable, Sendable { case on, off }

public enum Command: Equatable, Sendable {
    case on(trialSeconds: Int?, force: Bool)
    case confirm
    case off
    case pause(seconds: Int)
    case resume
}

public struct Caller: Equatable, Sendable {
    public let isRoot: Bool
    public init(isRoot: Bool) { self.isRoot = isRoot }
}

public enum CommandError: Error, Equatable {
    case rootRequired
    case noEndpoints
    case pauseTooLong(max: Int)
    case notInTrial
    case notArmed
    case alreadyPaused
    case invalidDuration
}

/// What the daemon should have loaded in pf.
public struct Desired: Equatable, Sendable {
    public let ruleset: Ruleset?   // nil = no rules loaded, pf token released
    public init(ruleset: Ruleset?) { self.ruleset = ruleset }
}

/// Pure state machine: no clock, no pf, no I/O. The caller passes `now`.
public struct StateMachine: Sendable {
    public private(set) var mode: Mode
    public internal(set) var pauseUntil: Date?
    public internal(set) var trialDeadline: Date?
    public let config: Config

    public init(config: Config, mode: Mode = .off) {
        self.config = config
        self.mode = mode
    }

    public mutating func apply(_ cmd: Command, caller: Caller, endpointIPs: [String], now: Date) throws {
        tick(now: now)
        switch cmd {
        case let .on(trial, force):
            // --force (no known endpoints) is only allowed with a trial, so a lockout reverts itself.
            if endpointIPs.isEmpty && !(force && trial != nil) { throw CommandError.noEndpoints }
            if let trial, !(10...3600).contains(trial) { throw CommandError.invalidDuration }
            let wasOn = mode == .on
            mode = .on
            pauseUntil = nil
            // A trial reverts to off, so it may only start from off. While already on, a
            // trial would let a non-root caller switch a locked kill switch off.
            if !wasOn { trialDeadline = trial.map { now.addingTimeInterval(TimeInterval($0)) } }
            // A plain `on` makes the state permanent, like `confirm`.
            else if trial == nil { trialDeadline = nil }
        case .confirm:
            guard trialDeadline != nil else { throw CommandError.notInTrial }
            trialDeadline = nil
        case .off:
            if config.locked && !caller.isRoot { throw CommandError.rootRequired }
            mode = .off
            pauseUntil = nil
            trialDeadline = nil
        case let .pause(seconds):
            if config.locked && !caller.isRoot { throw CommandError.rootRequired }
            guard mode == .on else { throw CommandError.notArmed }
            guard seconds >= 1 else { throw CommandError.invalidDuration }
            guard pauseUntil == nil else { throw CommandError.alreadyPaused }
            guard seconds <= config.maxPauseSeconds else { throw CommandError.pauseTooLong(max: config.maxPauseSeconds) }
            pauseUntil = now.addingTimeInterval(TimeInterval(seconds))
        case .resume:
            pauseUntil = nil
        }
    }

    /// Expire pause and revert an unconfirmed trial.
    public mutating func tick(now: Date) {
        if let p = pauseUntil, now >= p { pauseUntil = nil }
        if let t = trialDeadline, now >= t {
            trialDeadline = nil
            mode = .off
            pauseUntil = nil
        }
    }

    public func isEnforcing(now: Date) -> Bool {
        guard mode == .on else { return false }
        if let p = pauseUntil, now < p { return false }
        return true
    }

    public func desired(tunnel: TunnelState?, endpointIPs: [String], now: Date) throws -> Desired {
        guard isEnforcing(now: now) else { return Desired(ruleset: nil) }
        let up = tunnel?.isUp ?? false
        let rules = try RulesetBuilder.build(
            config: config, tunnelInterface: tunnel?.interface, endpointIPs: endpointIPs, tunnelUp: up)
        return Desired(ruleset: rules)
    }
}
