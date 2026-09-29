//
//  ToolExecutor.swift
//  Otto
//
//  Runs the client tool calls of one round: validates each input, applies the policy (availability,
//  rate limits, decline fatigue, hard blocks, provenance, private-data echo, consent, remembered
//  scopes, macOS permissions), shows one dock card at a time and waits for an armed, hardware-confirmed
//  answer, runs the approved calls with timeouts, and records every call in the activity log. Every
//  call of a round ends with a terminal status and the exact tool_result Claude receives.
//

import Foundation
import Observation
import os

@MainActor @Observable final class ToolExecutor: ToolExecuting {
    /// Declines in earlier rounds of a reply after which later card-requiring calls are declined without asking.
    /// (The approval timeout is `ToolLimits.approvalTimeout`.)
    static let maxDeclinesBeforeFatigue = 2
    /// Undo notes kept waiting for their conversation's next message; the oldest go first.
    static let maxQueuedContextNotes = 50

    /// The dock's current tool-loop prompt.
    private(set) var pendingApproval: PendingApproval?

    @ObservationIgnored var onAttentionNeeded: ((PendingApproval) -> Void)?

    /// Builds the environment for `OttoTool.isAvailable(in:)` (the pre-check and the re-check right before a call
    /// runs). AppComposition sets it from the settings, the permissions center and the demo flag. When nil, every
    /// tool in the round's snapshot counts as available (the loop offered only available tools this turn).
    @ObservationIgnored var makeEnvironment: (@MainActor (ModelOption) -> ToolEnvironment)?

    /// Settings → Actions safety policy; AppComposition: `{ settings.actionSafetyMode }`. `.fewerPrompts` lets an
    /// "Always allow" shortcut run after web content (not after a fresh file, image, clipboard, browser tab or
    /// tool output) and returns no web pause.
    @ObservationIgnored var safetyMode: @MainActor () -> ActionSafetyMode = { .safer }

    @ObservationIgnored private let permissions: PermissionProviding
    @ObservationIgnored private let approvals: ApprovalStore
    @ObservationIgnored private let log: ActionLog?
    @ObservationIgnored private let limiter: ToolRateLimiter
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let logFullScripts: @MainActor () -> Bool

    @ObservationIgnored private var declines = 0
    @ObservationIgnored private var declinesBeforeRound = 0
    /// Per-reply counters as each reply's last round left them, so Retry continues a failed reply with its
    /// spent limits and declines (`resumeTurn`). Only the latest `maxRememberedTurns` replies are kept.
    @ObservationIgnored private var turnCounters: [(messageID: UUID, counters: TurnCounters)] = []
    static let maxRememberedTurns = 20
    /// Undo notes, each with the assistant message whose action was undone (so it only reaches that conversation).
    @ObservationIgnored private var contextNotes: [(messageID: UUID, text: String)] = []
    /// Every tool Undo may resolve a token's tool from, by name: those registered (`registerUndoTools`, the
    /// whole registry, so an action restored from History can be undone after a relaunch) and those seen in a round.
    @ObservationIgnored private var knownTools: [String: any OttoTool] = [:]
    /// Calls whose undo is running: a second click (a double-click) must not undo again, because a second
    /// `tool.undo` finds the item gone and falls back to deleting a same-looking one.
    @ObservationIgnored private var undoInFlight: Set<String> = []
    @ObservationIgnored private var approvalWait: ApprovalWait?
    @ObservationIgnored private var runs: [String: CallRun] = [:]
    @ObservationIgnored private var active: ActiveRound?
    @ObservationIgnored private var logTail: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.jalenedusei.otto", category: "Tools")

    init(permissions: PermissionProviding, approvals: ApprovalStore, log: ActionLog?,
         limiter: ToolRateLimiter = ToolRateLimiter(), now: @escaping () -> Date = Date.init,
         logFullScripts: @escaping @MainActor () -> Bool = { false }) {
        self.permissions = permissions
        self.approvals = approvals
        self.log = log
        self.limiter = limiter
        self.now = now
        self.logFullScripts = logFullScripts
    }

    // MARK: - ToolExecuting

    func beginTurn() {
        limiter.beginTurn()
        declines = 0
        declinesBeforeRound = 0
    }

    func resumeTurn(messageID: UUID, calls: [ToolCall]) {
        let counters = turnCounters.last(where: { $0.messageID == messageID })?.counters
            ?? TurnCounters(recountingFrom: calls)
        limiter.resumeTurn(runs: counters.runs)
        declines = counters.declines
        declinesBeforeRound = counters.declines
    }

    func registerUndoTools(_ tools: [any OttoTool]) {
        for tool in tools where knownTools[tool.name] == nil { knownTools[tool.name] = tool }
    }

    func execute(_ round: ToolRound, store: ToolCallStore) async throws -> ToolRoundOutcome {
        try Task.checkCancellation()
        for (name, tool) in round.knownTools where knownTools[name] == nil { knownTools[name] = tool }
        for (name, tool) in round.tools { knownTools[name] = tool }
        let state = ActiveRound(round: round, store: store)
        active = state
        declinesBeforeRound = declines
        defer {
            if active === state { active = nil }
            rememberCounters(for: round.messageID)
        }

        do {
            let outcome = try await withTaskCancellationHandler {
                try await executeRound(round, store: store, state: state)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelAll() }
            }
            await flushLog()
            return outcome
        } catch {
            await flushLog()
            throw error
        }
    }

    func resolve(_ decision: ApprovalDecision, callID: String, hardwareConfirmed: Bool, visibleSince: Date?) {
        guard let wait = approvalWait, wait.approval.callID == callID else { return }
        switch decision {
        case .run:
            guard hardwareConfirmed else {
                Self.logger.notice("blocked_synthetic_input for \(wait.approval.toolName, privacy: .public)")
                record(ActionLogEntry(id: UUID(), date: now(), tool: wait.approval.toolName,
                                      decision: "blocked_synthetic_input", outcome: "not_run",
                                      summary: wait.approval.presentation.title, provenance: wait.plan.provenance,
                                      caution: wait.plan.caution, durationMs: nil,
                                      scriptSHA256: nil, script: nil, target: nil))
                return
            }
            guard let visibleSince else {
                Self.logger.info("Ignored an approval for a card that isn't visible")
                return
            }
            guard now() >= wait.approval.armedAt(visibleSince: visibleSince) else {
                Self.logger.info("Ignored an approval before the card armed")
                return
            }
            finishApproval(decision)
        case .cancelled:
            cancelAll()
        case .deny, .denyAll, .expired:
            finishApproval(decision)
        }
    }

    func cancelAll() {
        guard let state = active else {
            if approvalWait != nil { finishApproval(.cancelled) }
            return
        }
        state.cancelled = true
        let store = state.store
        let messageID = state.round.messageID

        if let wait = approvalWait {
            store?.updateToolCall(wait.approval.callID, in: messageID) { call in
                Self.settle(&call, status: .cancelled, result: .error(Copy.cancelledBeforeRun), at: self.now())
            }
            record(logEntry(for: wait.plan, decision: "cancelled", outcome: "not_run"))
            finishApproval(.cancelled)
        }
        for (callID, run) in runs {
            store?.updateToolCall(callID, in: messageID) { call in
                Self.settle(&call, status: .cancelled, result: .error(Copy.cancelledWhileRunning), at: self.now())
            }
            record(logEntry(for: run.plan, decision: run.decision, outcome: "error:cancelled",
                            durationMs: run.elapsedMilliseconds))
            run.finish(.cancelled)
        }
        runs = [:]
        for callID in state.round.callIDs {
            guard let call = store?.toolCall(callID, in: messageID), !call.status.isTerminal else { continue }
            store?.updateToolCall(callID, in: messageID) { call in
                Self.settle(&call, status: .cancelled, result: .error(Copy.cancelledBeforeRun), at: self.now())
            }
            record(makeEntry(toolName: call.name, title: call.presentation.title, decision: "cancelled",
                             outcome: "not_run", provenance: call.provenance, caution: call.caution, durationMs: nil,
                             input: call.input))
        }
        Self.logger.info("Cancelled the tool round")
    }

    func undo(callID: String, messageID: UUID, store: ToolCallStore) async -> String? {
        // Single flight: a repeat click while this call's undo runs is ignored (the first one reports the outcome).
        guard !undoInFlight.contains(callID) else { return nil }
        guard let call = store.toolCall(callID, in: messageID) else { return "Otto no longer has this action" }
        guard call.status == .succeeded, let token = call.undo else { return "there's nothing to undo" }
        guard now() < token.expires else { return "the time to undo it has passed" }
        guard let tool = knownTools[token.toolName] else { return "this action can't be undone" }
        undoInFlight.insert(callID)
        defer { undoInFlight.remove(callID) }
        // Hide [Undo] while it runs (the card shows it only with a token); a failed undo gives the token back.
        store.updateToolCall(callID, in: messageID) { $0.undo = nil }
        do {
            try await tool.undo(token)
        } catch let error as ToolError {
            store.updateToolCall(callID, in: messageID) { $0.undo = token }
            return Self.reasonText(error.userMessage)
        } catch {
            store.updateToolCall(callID, in: messageID) { $0.undo = token }
            Self.logger.error("Undo failed: \(error.localizedDescription, privacy: .private)")
            return "it didn't work"
        }
        store.updateToolCall(callID, in: messageID) { call in
            call.status = .undone
            call.presentation.doneTitle = token.doneTitle
            call.undo = token
        }
        contextNotes.append((messageID, "[Note: the user undid an action — \(token.noteForClaude).]"))
        if contextNotes.count > Self.maxQueuedContextNotes {
            contextNotes.removeFirst(contextNotes.count - Self.maxQueuedContextNotes)
        }
        Self.logger.info("Undid \(token.toolName, privacy: .public)")
        return nil
    }

    func stop(callID: String) {
        guard let run = runs[callID] else { return }
        run.finish(.stopped)
    }

    func consumeContextNotes() -> [String] {
        defer { contextNotes = [] }
        return contextNotes.map(\.text)
    }

    func consumeContextNotes(forMessages messageIDs: Set<UUID>) -> [String] {
        let taken = contextNotes.filter { messageIDs.contains($0.messageID) }
        contextNotes.removeAll { messageIDs.contains($0.messageID) }
        return taken.map(\.text)
    }

    // MARK: - Per-reply counters

    /// What a reply has spent of its per-reply allowances.
    struct TurnCounters: Equatable {
        var runs: [String: Int] = [:]
        var declines = 0

        init(runs: [String: Int] = [:], declines: Int = 0) {
            self.runs = runs
            self.declines = declines
        }

        /// The counters a reply's calls imply, when this process never ran it (a History restore): every call that
        /// got past its checks counts as a run (conservatively, a failed one too), and every call the user declined
        /// on its card counts as a decline.
        init(recountingFrom calls: [ToolCall]) {
            for call in calls {
                switch call.status {
                case .succeeded, .undone, .failed, .running, .waitingForSystem:
                    runs[call.name, default: 0] += 1
                case .denied:
                    let text = call.result?.parts.first.flatMap { part -> String? in
                        if case .text(let text) = part { return text }
                        return nil
                    } ?? ""
                    if text.hasPrefix(Copy.declinedPrefix) { declines += 1 }
                default:
                    break
                }
            }
        }
    }

    private func rememberCounters(for messageID: UUID) {
        turnCounters.removeAll { $0.messageID == messageID }
        turnCounters.append((messageID, TurnCounters(runs: limiter.turnRuns, declines: declines)))
        if turnCounters.count > Self.maxRememberedTurns {
            turnCounters.removeFirst(turnCounters.count - Self.maxRememberedTurns)
        }
    }

    // MARK: - The round

    private func executeRound(_ round: ToolRound, store: ToolCallStore, state: ActiveRound) async throws -> ToolRoundOutcome {
        // Earlier results of tools not offered this turn are still in the transcript, so they are classified too.
        let classifying = round.classifyingTools
        let untrusted = classifying.values.filter(\.producesUntrustedOutput)
            .reduce(into: [String: ProvenanceSource.Severity]()) { $0[$1.name] = Self.severity(of: $1) }
        let trust = TrustLedger.assess(transcript: round.transcript, untrustedTools: untrusted)
        let privateSources = classifying.compactMapValues(\.privateDataSource)
        let privates = EchoDetector.privateStrings(in: round.transcript, sources: privateSources)

        var seen = Set<String>()
        var plans: [CallPlan] = []
        for callID in round.callIDs where seen.insert(callID).inserted {
            guard let call = store.toolCall(callID, in: round.messageID) else { continue }
            if let plan = precheck(call, round: round, store: store, trust: trust, privates: privates) {
                plans.append(plan)
            }
        }
        try checkCancelled(state)

        // Phase A: pure reads that need nothing from the user run together.
        let phaseA = plans.filter(\.runsWithoutAsking)
        let phaseATasks = phaseA.map { plan in
            Task { @MainActor in
                try await self.runCall(plan, options: ApprovalOptions(), approvedVia: plan.automaticApproval,
                                       decision: plan.automaticDecision, round: round, state: state)
            }
        }
        var phaseAError: Error?
        for task in phaseATasks {
            do { try await task.value } catch { phaseAError = phaseAError ?? error }
        }
        if let phaseAError { throw phaseAError }
        try checkCancelled(state)

        // Phase B: everything else, one at a time in model order.
        let phaseB = plans.filter { !$0.runsWithoutAsking }
        let carded = phaseB.filter(\.needsCard).map(\.callID)
        var declinedAll = Set<String>()
        for plan in phaseB {
            try checkCancelled(state)
            if declinedAll.contains(plan.callID) {
                store.updateToolCall(plan.callID, in: round.messageID) { call in
                    Self.settle(&call, status: .denied, result: .error(Copy.declineAll), at: self.now())
                }
                record(logEntry(for: plan, decision: "declined", outcome: "not_run"))
                continue
            }
            let position = (carded.firstIndex(of: plan.callID) ?? 0) + 1
            let remaining = carded.drop { $0 != plan.callID }.dropFirst()
            let decided = try await decide(plan, round: round, store: store, trust: trust, position: position,
                                           total: carded.count, state: state)
            switch decided {
            case .run(let options, let via, let decision):
                try await runCall(plan, options: options, approvedVia: via, decision: decision, round: round,
                                  state: state)
            case .settled:
                break
            case .settledDecliningRest:
                declinedAll.formUnion(remaining)
            }
        }

        return webPause(trust: trust, privates: privates, state: state)
    }

    // MARK: - Pre-check (§5.4 step 2)

    private func precheck(_ call: ToolCall, round: ToolRound, store: ToolCallStore, trust: TrustAssessment,
                          privates: [(phrase: String, source: String)]) -> CallPlan? {
        let messageID = round.messageID
        func finish(_ status: ToolCallStatus, _ text: String, recovery: ToolRecovery? = nil, decision: String,
                    outcome: String, tool: (any OttoTool)? = nil, input: JSONValue? = nil,
                    provenance: String? = nil, caution: Bool = false) {
            store.updateToolCall(call.id, in: messageID) { updated in
                updated.recovery = recovery
                Self.settle(&updated, status: status, result: .error(text), at: self.now())
            }
            let title = store.toolCall(call.id, in: messageID)?.presentation.title ?? call.presentation.title
            record(makeEntry(toolName: call.name, title: title, decision: decision, outcome: outcome,
                             provenance: provenance, caution: caution, durationMs: nil, input: input))
        }

        // a. Unknown tool.
        guard let tool = round.tools[call.name] else {
            finish(.failed("Unknown action"), Copy.unknownTool(call.name), decision: "auto", outcome: "error:unknown_tool")
            return nil
        }
        // b. Turned off.
        guard isAvailable(tool, model: round.model) else {
            finish(.skipped("Turned off in Settings"), Copy.disabled, recovery: .openActionsSettings,
                   decision: "auto", outcome: "not_run", tool: tool)
            return nil
        }
        // c. Invalid JSON.
        guard let rawInput = call.input else {
            finish(.failed("Couldn't read the request"), Copy.invalidJSON(call.invalidInput ?? ""),
                   decision: "auto", outcome: "error:invalid_input", tool: tool)
            return nil
        }
        // Strict schemas make optional keys nullable: an unused one arrives as null and counts as absent.
        let input = ToolSchema.removingNullOptionals(rawInput, schema: tool.inputSchema)
        // d. Schema.
        if let problem = JSONSchemaValidator.validate(input, against: tool.inputSchema) {
            finish(.failed("Invalid request"), Copy.invalidInput(problem), decision: "auto",
                   outcome: "error:invalid_input", tool: tool)
            return nil
        }
        // e. The tool's own limits.
        if let error = tool.validate(input) {
            finish(.failed("Invalid request"), Copy.invalidInput(error.modelMessage), recovery: error.recovery,
                   decision: "auto", outcome: "error:invalid_input", tool: tool)
            return nil
        }
        // f. Describe the validated input.
        let presentation = tool.describe(input)
        let echo = EchoDetector.find(in: tool.egressStrings(in: input), privateStrings: privates)
        let caution = trust.caution || echo != nil
        let provenance = trust.primaryFreshSource.map { "after \($0.phrase)" }
        store.updateToolCall(call.id, in: messageID) { updated in
            updated.input = input
            updated.presentation = presentation
            updated.provenance = provenance
            updated.caution = caution
        }
        let plan = makePlan(call.id, tool: tool, input: input, presentation: presentation, echo: echo,
                            caution: caution, provenance: provenance, trust: trust)

        // g. Rate limits.
        if let error = limiter.check(tool) {
            finish(.skipped("Limit reached"), error.toolResultText, decision: "limit", outcome: "not_run",
                   tool: tool, input: input, provenance: provenance, caution: caution)
            return nil
        }
        // h. Decline fatigue: only for declines in earlier rounds of this reply.
        if plan.needsDecision, declinesBeforeRound >= Self.maxDeclinesBeforeFatigue {
            finish(.denied, Copy.fatigue, decision: "declined", outcome: "not_run", tool: tool, input: input,
                   provenance: provenance, caution: caution)
            return nil
        }
        // i. Hard block.
        if let reason = tool.blockReason(for: input) {
            let clean = Self.withoutTrailingPeriod(reason)
            finish(.blocked(clean), "blocked: \(clean).", decision: "blocked", outcome: "not_run", tool: tool,
                   input: input, provenance: provenance, caution: caution)
            return nil
        }
        // k. A permission the organization manages can't be asked for.
        if let restricted = tool.requiredPermissions(for: input).first(where: { permissions.status($0) == .restricted }) {
            finish(.skipped("Permission needed"), Copy.permission(restricted),
                   recovery: .openSystemSettings(restricted), decision: "auto", outcome: "not_run", tool: tool,
                   input: input, provenance: provenance, caution: caution)
            return nil
        }
        return plan
    }

    /// Steps j and k: caution, echo and what the call needs before it may run.
    private func makePlan(_ callID: String, tool: any OttoTool, input: JSONValue, presentation: ToolCallPresentation,
                          echo: EchoFinding?, caution: Bool, provenance: String?, trust: TrustAssessment) -> CallPlan {
        let missing = missingPermissions(tool, input: input)
        var consent: ConsentKey?
        var scope: ApprovalScope?
        var needsApproval = false
        var honored = false
        switch tool.approvalRequirement(for: input) {
        case .none:
            break
        case .consentOnce(let key):
            if !approvals.hasConsent(key) { consent = key }
        case .everyCall(let rememberScope):
            scope = rememberScope
            honored = mayHonor(rememberScope, tool: tool, input: input, trust: trust, echo: echo)
            needsApproval = !honored
        }
        return CallPlan(callID: callID, tool: tool, input: input, presentation: presentation, echo: echo,
                        caution: caution, provenance: provenance, cardProvenance: trust.provenanceLine,
                        cautionSource: trust.cautionHeadlineSource, missing: missing, consent: consent,
                        scope: scope, needsApproval: needsApproval, rememberedHonored: honored)
    }

    /// §5.4 k: a remembered "Always allow" runs without a card only with no echo, input that is the user's own words,
    /// and no fresh medium/high content. The safer mode also needs no web page or search anywhere in context; fewer
    /// prompts drops only the web conditions, so a fresh file, image, clipboard, browser tab or tool output still
    /// asks.
    private func mayHonor(_ scope: ApprovalScope?, tool: any OttoTool, input: JSONValue, trust: TrustAssessment,
                          echo: EchoFinding?) -> Bool {
        guard let scope, approvals.isRemembered(scope), echo == nil, !tool.inheritsOttoPermissions else { return false }
        switch safetyMode() {
        case .safer:
            guard !trust.caution, !trust.hasHighSource else { return false }
        case .fewerPrompts:
            guard !trust.hasFreshNonWebCaution else { return false }
        }
        let userText = Self.normalizedForComparison(trust.latestUserText)
        return tool.egressStrings(in: input)
            .map(Self.normalizedForComparison)
            .filter { !$0.isEmpty }
            .allSatisfy { userText.contains($0) }
    }

    private func missingPermissions(_ tool: any OttoTool, input: JSONValue) -> [Permission] {
        tool.requiredPermissions(for: input).filter { permission in
            let status = permissions.status(permission)
            return status != .granted && status != .unavailable
        }
    }

    // MARK: - Phase B decisions

    private enum Decided {
        case run(ApprovalOptions, ApprovalVia, decision: String)
        case settled
        case settledDecliningRest
    }

    private func decide(_ plan: CallPlan, round: ToolRound, store: ToolCallStore, trust: TrustAssessment,
                        position: Int, total: Int, state: ActiveRound) async throws -> Decided {
        let messageID = round.messageID
        var options = ApprovalOptions()
        var via = plan.automaticApproval
        var decision = plan.automaticDecision

        if !plan.missing.isEmpty {
            store.updateToolCall(plan.callID, in: messageID) { $0.status = .needsPermission }
            let answer = try await ask(plan, kind: .permission(plan.missing, consent: plan.consent), round: round,
                                       position: position, total: total, state: state)
            switch answer {
            case .run(let chosen):
                if let stillMissing = missingPermissions(plan.tool, input: plan.input).first {
                    skipForPermission(plan, stillMissing, round: round, store: store)
                    return .settled
                }
                if let key = plan.consent {
                    approvals.grantConsent(key)
                    via = .consent
                    decision = "consent"
                }
                options = chosen
            case .deny:
                skipForPermission(plan, plan.missing[0], round: round, store: store)
                return .settled
            case .denyAll:
                skipForPermission(plan, plan.missing[0], round: round, store: store)
                declines += 1
                return .settledDecliningRest
            case .expired:
                settleExpired(plan, round: round, store: store)
                return .settled
            case .cancelled:
                throw CancellationError()
            }
        }

        let consentCard = plan.consent.flatMap { approvals.hasConsent($0) ? nil : $0 }
        guard consentCard != nil || plan.needsApproval else { return .run(options, via, decision: decision) }

        store.updateToolCall(plan.callID, in: messageID) { $0.status = .awaitingApproval }
        let offeredScope = plan.caution ? nil : plan.scope
        let kind: PendingApproval.Kind = consentCard.map { .consent($0) } ?? .approval(rememberScope: offeredScope)
        let answer = try await ask(plan, kind: kind, round: round, position: position, total: total, state: state)
        switch answer {
        case .run(let chosen):
            if let key = consentCard {
                approvals.grantConsent(key)
                via = .consent
                decision = "consent"
            } else if chosen.alwaysAllow, let scope = offeredScope {
                approvals.remember(scope)
                via = .userApproved
                decision = "approved_always"
            } else {
                via = .userApproved
                decision = "approved"
            }
            options = ApprovalOptions(alwaysAllow: chosen.alwaysAllow && offeredScope != nil,
                                      calendarIdentifier: chosen.calendarIdentifier ?? options.calendarIdentifier)
            return .run(options, via, decision: decision)
        case .deny:
            settleDeclined(plan, round: round, store: store)
            declines += 1
            return .settled
        case .denyAll:
            settleDeclined(plan, round: round, store: store)
            declines += 1
            return .settledDecliningRest
        case .expired:
            settleExpired(plan, round: round, store: store)
            return .settled
        case .cancelled:
            throw CancellationError()
        }
    }

    // MARK: - Cards

    private func ask(_ plan: CallPlan, kind: PendingApproval.Kind, round: ToolRound, position: Int, total: Int,
                     state: ActiveRound) async throws -> ApprovalDecision {
        try checkCancelled(state)
        var body = await plan.tool.approvalBody(for: plan.input)
        try checkCancelled(state)
        if plan.tool.inheritsOttoPermissions, case .appleScript(var preview) = body {
            preview.inheritedAccess = permissions.grantedPermissions().map(Self.accessName)
            body = .appleScript(preview)
        }

        let labels: (confirm: String, decline: String)
        switch kind {
        case .approval: labels = plan.tool.approvalLabels(for: plan.input)
        case .consent: labels = ("Allow", "Not now")
        case .permission: labels = ("Continue…", "Not now")
        }
        let armingDelay = plan.caution
            ? max(Duration.seconds(1), plan.tool.minimumArmingDelay * 2)
            : max(Duration.milliseconds(350), plan.tool.minimumArmingDelay)
        let approval = PendingApproval(callID: plan.callID, messageID: round.messageID, toolName: plan.tool.name,
                                       kind: kind, presentation: plan.presentation, body: body,
                                       confirmLabel: labels.confirm, declineLabel: labels.decline,
                                       provenance: plan.cardProvenance, caution: cautionBanner(for: plan),
                                       armingDelay: armingDelay, presentedAt: now(), position: position,
                                       total: total)

        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
            let wait = ApprovalWait(approval: approval, plan: plan, continuation: continuation)
            approvalWait = wait
            wait.timer = Task { @MainActor [weak self, weak wait] in
                try? await Task.sleep(for: ToolLimits.approvalTimeout)
                guard !Task.isCancelled, let self, let wait, self.approvalWait === wait else { return }
                self.finishApproval(.expired)
            }
            pendingApproval = approval
            Self.logger.info("Asking about \(plan.tool.name, privacy: .public) (\(position, privacy: .public) of \(total, privacy: .public))")
            onAttentionNeeded?(approval)
        }
        if decision == .cancelled || state.cancelled { throw CancellationError() }
        return decision
    }

    private func finishApproval(_ decision: ApprovalDecision) {
        guard let wait = approvalWait else { return }
        approvalWait = nil
        pendingApproval = nil
        wait.timer?.cancel()
        wait.continuation.resume(returning: decision)
    }

    private func cautionBanner(for plan: CallPlan) -> CautionBanner? {
        if let echo = plan.echo {
            let sample = DisplayText.sanitized(echo.sample, maxLength: 60)
            return CautionBanner(headline: "This sends details from \(echo.sourcePhrase) (“\(sample)”) outside Otto.",
                                 body: Copy.cautionBody)
        }
        guard plan.caution else { return nil }
        return CautionBanner(headline: "Otto read \(plan.cautionSource ?? "outside content") just before asking.",
                             body: Copy.cautionBody)
    }

    // MARK: - Running

    private func runCall(_ plan: CallPlan, options: ApprovalOptions, approvedVia: ApprovalVia, decision: String,
                         round: ToolRound, state: ActiveRound) async throws {
        try checkCancelled(state)
        let messageID = round.messageID
        let store = state.store
        guard isAvailable(plan.tool, model: round.model) else {
            store?.updateToolCall(plan.callID, in: messageID) { call in
                call.recovery = .openActionsSettings
                Self.settle(&call, status: .skipped("Turned off in Settings"), result: .error(Copy.disabled), at: self.now())
            }
            record(logEntry(for: plan, decision: decision, outcome: "not_run"))
            return
        }

        let run = CallRun(plan: plan, decision: decision)
        runs[plan.callID] = run
        store?.updateToolCall(plan.callID, in: messageID) { call in
            call.status = .running
            call.startedAt = self.now()
            call.approvedVia = approvedVia
            call.progressNote = nil
        }
        let context = makeContext(for: plan, options: options, round: round, run: run)
        let tool = plan.tool
        let input = plan.input
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<RunOutcome, Never>) in
            run.continuation = continuation
            run.work = Task.detached(priority: .userInitiated) {
                let result: RunOutcome
                do {
                    result = .finished(try await tool.run(input, context: context))
                } catch is CancellationError {
                    result = .cancelled
                } catch {
                    result = .failed(error)
                }
                await run.finish(result)
            }
            let timeout = tool.timeout
            run.timer = Task { @MainActor [weak run] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                run?.finish(.timedOut)
            }
        }
        if runs[plan.callID] === run { runs[plan.callID] = nil }
        let durationMs = run.elapsedMilliseconds

        // cancelAll already settled and logged the call.
        if state.cancelled { throw CancellationError() }

        var status: ToolCallStatus
        var result: ToolOutput
        var recovery: ToolRecovery?
        var doneTitle: String?
        var undo: UndoToken?
        var outcomeText: String
        switch outcome {
        case .finished(let runResult):
            result = runResult.output.normalized()
            if result.isError {
                status = .failed("Didn't work")
                outcomeText = "error:failed"
            } else {
                status = .succeeded
                outcomeText = "ok"
                doneTitle = runResult.doneTitle
                undo = runResult.undo
                if let source = tool.privateDataSource { state.succeededPrivateSources.append(source) }
            }
        case .failed(let error as ToolError):
            result = ToolOutput.error(error.toolResultText).normalized()
            status = .failed(error.userMessage)
            recovery = error.recovery
            outcomeText = "error:\(error.code.rawValue)"
        case .failed(let error):
            Self.logger.error("\(tool.name, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            result = ToolOutput.error("failed: \(error.localizedDescription)").normalized()
            status = .failed("Didn't work")
            outcomeText = "error:failed"
        case .timedOut:
            result = .error(Copy.timeout(tool.timeout))
            status = .failed("Timed out")
            outcomeText = "error:timeout"
        case .stopped, .cancelled:
            result = .error(Copy.cancelledWhileRunning)
            status = .cancelled
            outcomeText = "error:cancelled"
        }
        store?.updateToolCall(plan.callID, in: messageID) { call in
            call.recovery = recovery
            call.undo = undo
            call.progressNote = nil
            if let doneTitle { call.presentation.doneTitle = doneTitle }
            Self.settle(&call, status: status, result: result, at: self.now())
        }
        record(logEntry(for: plan, decision: decision, outcome: outcomeText, durationMs: durationMs))
    }

    private func makeContext(for plan: CallPlan, options: ApprovalOptions, round: ToolRound, run: CallRun) -> ToolRunContext {
        let callID = plan.callID
        let messageID = round.messageID
        return ToolRunContext(
            callID: callID,
            model: round.model,
            options: options,
            reportProgress: { [weak self] note in
                Task { @MainActor in self?.noteProgress(note, callID: callID, messageID: messageID) }
            },
            reportSystemDialog: { [weak self] appName in
                Task { @MainActor in self?.noteSystemDialog(appName, callID: callID, messageID: messageID) }
            }
        )
    }

    /// Progress notes reach the row at most 4 times a second; the latest note always lands.
    private func noteProgress(_ note: String, callID: String, messageID: UUID) {
        guard let run = runs[callID] else { return }
        let clock = ContinuousClock()
        let interval = Duration.milliseconds(250)
        if let last = run.lastProgress, clock.now - last < interval {
            let wasPending = run.pendingProgress != nil
            run.pendingProgress = note
            guard !wasPending else { return }
            let wait = interval - (clock.now - last)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, let run = self.runs[callID], let pending = run.pendingProgress else { return }
                run.pendingProgress = nil
                self.noteProgress(pending, callID: callID, messageID: messageID)
            }
            return
        }
        run.lastProgress = clock.now
        let clean = DisplayText.sanitized(note, maxLength: 120)
        active?.store?.updateToolCall(callID, in: messageID) { call in
            guard !call.status.isTerminal else { return }
            call.progressNote = clean
        }
    }

    private func noteSystemDialog(_ appName: String?, callID: String, messageID: UUID) {
        guard runs[callID] != nil else { return }
        active?.store?.updateToolCall(callID, in: messageID) { call in
            switch call.status {
            case .running, .waitingForSystem:
                call.status = appName.map { .waitingForSystem(DisplayText.sanitized($0, maxLength: 60)) } ?? .running
            default:
                break
            }
        }
    }

    // MARK: - Settling

    private static func settle(_ call: inout ToolCall, status: ToolCallStatus, result: ToolOutput, at date: Date) {
        call.status = status
        call.result = result.normalized()
        call.finishedAt = date
    }

    private func settleDeclined(_ plan: CallPlan, round: ToolRound, store: ToolCallStore) {
        store.updateToolCall(plan.callID, in: round.messageID) { call in
            Self.settle(&call, status: .denied, result: .error(Copy.declined(plan.presentation.title)), at: self.now())
        }
        record(logEntry(for: plan, decision: "declined", outcome: "not_run"))
    }

    private func settleExpired(_ plan: CallPlan, round: ToolRound, store: ToolCallStore) {
        store.updateToolCall(plan.callID, in: round.messageID) { call in
            Self.settle(&call, status: .denied, result: .error(Copy.expired), at: self.now())
        }
        record(logEntry(for: plan, decision: "timed_out", outcome: "not_run"))
    }

    private func skipForPermission(_ plan: CallPlan, _ permission: Permission, round: ToolRound, store: ToolCallStore) {
        store.updateToolCall(plan.callID, in: round.messageID) { call in
            call.recovery = .openSystemSettings(permission)
            Self.settle(&call, status: .skipped("Permission needed"), result: .error(Copy.permission(permission)),
                        at: self.now())
        }
        record(logEntry(for: plan, decision: "declined", outcome: "not_run"))
    }

    // MARK: - Outcome

    private func webPause(trust: TrustAssessment, privates: [(phrase: String, source: String)],
                          state: ActiveRound) -> ToolRoundOutcome {
        guard trust.caution, safetyMode() == .safer,
              let privateSource = privates.first?.source ?? state.succeededPrivateSources.first else {
            return ToolRoundOutcome()
        }
        let reason = WebPauseReason(privateSource: privateSource,
                                    untrustedSource: trust.cautionHeadlineSource ?? "outside content")
        Self.logger.info("Web access paused for the rest of this reply")
        return ToolRoundOutcome(webPause: reason)
    }

    // MARK: - Helpers

    private func checkCancelled(_ state: ActiveRound) throws {
        if state.cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func isAvailable(_ tool: any OttoTool, model: ModelOption) -> Bool {
        guard let makeEnvironment else { return true }
        return tool.isAvailable(in: makeEnvironment(model))
    }

    /// Calendar and reminder output is the user's own store (low); other third-party output is medium.
    private static func severity(of tool: any OttoTool) -> ProvenanceSource.Severity {
        switch tool.group {
        case .calendar?, .reminders?: return .low
        case .media?: return .medium
        default: return .medium
        }
    }

    private static func accessName(_ permission: Permission) -> String {
        if case .automation(_, let appName) = permission { return appName }
        return permission.displayName
    }

    /// Case-folded, whitespace collapsed to single spaces, trimmed.
    private static func normalizedForComparison(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated private static func withoutTrailingPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// "Couldn't undo — ‹reason›." takes a lowercase phrase without a final period.
    private static func reasonText(_ message: String) -> String {
        let trimmed = withoutTrailingPeriod(message)
        guard let first = trimmed.first else { return "it didn't work" }
        return first.lowercased() + trimmed.dropFirst()
    }

    // MARK: - Activity log

    private func record(_ entry: ActionLogEntry) {
        guard let log else { return }
        let previous = logTail
        logTail = Task {
            await previous?.value
            await log.append(entry)
        }
    }

    private func flushLog() async {
        await logTail?.value
    }

    private func logEntry(for plan: CallPlan, decision: String, outcome: String, durationMs: Int? = nil) -> ActionLogEntry {
        makeEntry(toolName: plan.tool.name, title: plan.presentation.title, decision: decision, outcome: outcome,
                  provenance: plan.provenance, caution: plan.caution, durationMs: durationMs, input: plan.input)
    }

    private func makeEntry(toolName: String, title: String, decision: String, outcome: String, provenance: String?,
                           caution: Bool, durationMs: Int?, input: JSONValue?) -> ActionLogEntry {
        var scriptHash: String?
        var script: String?
        if toolName == "run_applescript", let source = input?["script"]?.stringValue {
            let record = ActionLogEntry.scriptRecord(source, keepFull: logFullScripts())
            scriptHash = record.sha256
            script = record.script
        }
        return ActionLogEntry(id: UUID(), date: now(), tool: toolName, decision: decision, outcome: outcome,
                              summary: title, provenance: provenance, caution: caution, durationMs: durationMs,
                              scriptSHA256: scriptHash, script: script,
                              target: Self.logTarget(toolName: toolName, input: input))
    }

    /// Shortcut name / URL host / media app. Never an input's free text.
    private static func logTarget(toolName: String, input: JSONValue?) -> String? {
        let raw: String?
        switch toolName {
        case "run_shortcut":
            raw = input?["name"]?.stringValue
        case "open_url":
            raw = input?["url"]?.stringValue.flatMap { URLComponents(string: $0)?.host }
        case "media_control":
            raw = input?["app"]?.stringValue
        default:
            raw = nil
        }
        guard let raw else { return nil }
        let clean = DisplayText.sanitized(raw, maxLength: 80)
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Model-facing copy (§5.6)

    private enum Copy {
        static let declineAll = "declined: The user declined the remaining actions in this step."
        static let fatigue = "declined: The user declined several actions in this reply. Ask them before trying again."
        static let expired = "timeout: The user didn't respond to the approval request."
        static let cancelledBeforeRun = "cancelled: The user stopped Otto before this action started."
        static let cancelledWhileRunning =
            "cancelled: The user stopped Otto while this action was running. It may have partly completed."
        static let disabled =
            "disabled: The user turned this action off in Otto's settings. They can turn it on in Settings → Actions."
        static let cautionBody = "Pages and files can hide instructions. Only continue if you asked for this."

        /// How every result of a call the user declined on its card starts.
        static let declinedPrefix = "declined: The user chose not to "

        static func declined(_ title: String) -> String {
            let phrase = ToolExecutor.withoutTrailingPeriod(title)
            let lowered = phrase.first.map { $0.lowercased() + phrase.dropFirst() } ?? "do this"
            return declinedPrefix + "\(lowered). Don't retry it or look for a workaround unless they ask."
        }

        static func permission(_ permission: Permission) -> String {
            "permission_denied: Otto doesn't have \(permission.displayName) access. The user can allow it in "
                + "System Settings → Privacy & Security → \(permission.settingsPaneName)."
        }

        static func invalidJSON(_ raw: String) -> String {
            let echo = JSONValue.object(["INVALID_JSON": .string(String(raw.prefix(ToolLimits.maxInvalidInputEcho)))])
            return "invalid_input: The tool input wasn't valid JSON. Send the complete input again. \(echo.encodedString())"
        }

        static func invalidInput(_ problem: String) -> String {
            "invalid_input: \(ToolExecutor.withoutTrailingPeriod(problem)). Fix the input and call the tool again."
        }

        static func unknownTool(_ name: String) -> String {
            "unknown_tool: There is no tool named “\(name)”. Use only the tools provided."
        }

        static func timeout(_ limit: Duration) -> String {
            let seconds = limit.timeInterval
            let amount = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
            let unit = seconds == 1 ? "second" : "seconds"
            return "timeout: The action didn't finish within \(amount) \(unit), so Otto stopped it. It may have partly completed."
        }
    }
}

// MARK: - Per-round state

extension ToolExecutor {
    /// Everything the executor decided about one call before asking or running it.
    fileprivate struct CallPlan {
        let callID: String
        let tool: any OttoTool
        let input: JSONValue
        let presentation: ToolCallPresentation
        let echo: EchoFinding?
        /// trust.caution || echo.
        let caution: Bool
        /// Row provenance: "after reading example.com".
        let provenance: String?
        /// Card provenance: "Requested after reading example.com" / "Earlier in this chat Otto read …".
        let cardProvenance: String?
        let cautionSource: String?
        let missing: [Permission]
        /// The one-time consent still needed.
        let consent: ConsentKey?
        let scope: ApprovalScope?
        /// An everyCall card is needed (no remembered scope may be honored).
        let needsApproval: Bool
        let rememberedHonored: Bool

        /// A consent or approval card (a decline counts toward fatigue).
        var needsDecision: Bool { consent != nil || needsApproval }
        /// Any dock card: permission, consent or approval.
        var needsCard: Bool { !missing.isEmpty || needsDecision }
        /// Phase A: a concurrency-safe call that needs nothing from the user.
        var runsWithoutAsking: Bool { tool.isConcurrencySafe && !needsCard }

        var automaticApproval: ApprovalVia {
            if rememberedHonored, let scope { return .rememberedScope(label: scope.label) }
            if case .consentOnce = tool.approvalRequirement(for: input) { return .consent }
            return .notRequired
        }

        var automaticDecision: String {
            if rememberedHonored { return "approved_always" }
            if case .consentOnce = tool.approvalRequirement(for: input) { return "consent" }
            return "auto"
        }
    }

    @MainActor fileprivate final class ActiveRound {
        let round: ToolRound
        weak var store: ToolCallStore?
        var cancelled = false
        var succeededPrivateSources: [String] = []

        init(round: ToolRound, store: ToolCallStore) {
            self.round = round
            self.store = store
        }
    }

    @MainActor fileprivate final class ApprovalWait {
        let approval: PendingApproval
        let plan: CallPlan
        let continuation: CheckedContinuation<ApprovalDecision, Never>
        var timer: Task<Void, Never>?

        init(approval: PendingApproval, plan: CallPlan, continuation: CheckedContinuation<ApprovalDecision, Never>) {
            self.approval = approval
            self.plan = plan
            self.continuation = continuation
        }
    }

    fileprivate enum RunOutcome {
        case finished(ToolRunResult)
        case failed(Error)
        case timedOut
        case stopped
        case cancelled
    }

    /// One running call: whichever of the tool, its timeout, Stop or cancellation finishes first wins.
    @MainActor fileprivate final class CallRun {
        let plan: CallPlan
        let decision: String
        let started = ContinuousClock.now
        var continuation: CheckedContinuation<RunOutcome, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        var lastProgress: ContinuousClock.Instant?
        var pendingProgress: String?

        init(plan: CallPlan, decision: String) {
            self.plan = plan
            self.decision = decision
        }

        var elapsedMilliseconds: Int {
            let elapsed = ContinuousClock.now - started
            return Int((elapsed.timeInterval * 1_000).rounded())
        }

        func finish(_ outcome: RunOutcome) {
            guard let continuation else { return }
            self.continuation = nil
            work?.cancel()
            timer?.cancel()
            continuation.resume(returning: outcome)
        }
    }
}
