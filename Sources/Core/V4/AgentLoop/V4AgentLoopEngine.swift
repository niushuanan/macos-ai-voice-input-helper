import Foundation

struct V4AgentLoopEngine: V4AgentLoopRunning {
    typealias StepExecutor = @Sendable (
        _ step: V4StepRecord,
        _ request: V4RunRequest,
        _ accumulatedStepRecords: [V4StepRecord],
        _ turnIndex: Int
    ) async throws -> V4ToolResult

    let planner: any V4Planner
    let postStepDecider: any V4PostStepDecider
    let verifier: any V4Verifier
    let maxTurns: Int
    let maxRetryPerStep: Int
    let stepExecutor: StepExecutor

    init(
        planner: any V4Planner = V4PlannerRuleBased(),
        postStepDecider: any V4PostStepDecider = V4PostStepDeciderDefault(),
        verifier: any V4Verifier = V4VerifierDefault(),
        maxTurns: Int = 4,
        maxRetryPerStep: Int = 2,
        stepExecutor: @escaping StepExecutor = { step, request, accumulatedStepRecords, turnIndex in
            try await V4AgentLoopEngine.defaultStepExecutor(
                step: step,
                request: request,
                accumulatedStepRecords: accumulatedStepRecords,
                turnIndex: turnIndex
            )
        }
    ) {
        self.planner = planner
        self.postStepDecider = postStepDecider
        self.verifier = verifier
        self.maxTurns = max(1, maxTurns)
        self.maxRetryPerStep = max(0, maxRetryPerStep)
        self.stepExecutor = stepExecutor
    }

    func run(
        request: V4RunRequest,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) async throws -> V4RunOutcome {
        emit(
            name: .requestAccepted,
            status: .queued,
            request: request,
            message: "V4 Agent Loop 已启动。",
            stepRecords: request.stepRecords,
            evidenceSummary: request.evidenceSummary,
            onEvent: onEvent
        )

        var accumulatedStepRecords = request.stepRecords
        var currentEvidenceSummary = request.evidenceSummary
        var finalOutputText = accumulatedStepRecords.compactMap(\.outputSummary).last
        var currentTurn = 0

        while currentTurn < maxTurns {
            currentTurn += 1
            let turnRequest = requestedState(
                from: request,
                stepRecords: accumulatedStepRecords,
                evidenceSummary: currentEvidenceSummary
            )
            emit(
                name: .stateChanged,
                status: .planning,
                request: turnRequest,
                message: "第\(currentTurn)轮规划中。",
                stepRecords: accumulatedStepRecords,
                evidenceSummary: currentEvidenceSummary,
                turnIndex: currentTurn,
                maxTurns: maxTurns,
                progressHint: SessionHUDProgressHint.workflowPreview,
                onEvent: onEvent
            )

            let plan = try await planner.plan(for: turnRequest)
            if let terminalDecision = plan.terminalDecision {
                return finishRun(
                    request: turnRequest,
                    decision: terminalDecision,
                    finalOutputText: finalOutputText,
                    stepRecords: accumulatedStepRecords,
                    evidenceSummary: currentEvidenceSummary,
                    onEvent: onEvent
                )
            }

            let plannedSteps = plan.steps
            guard !plannedSteps.isEmpty else {
                return finishRun(
                    request: turnRequest,
                    decision: V4LoopDecision(
                        action: .fail,
                        message: "planner 没有产出可执行 step。",
                        failureCode: .invalidRequest
                    ),
                    finalOutputText: finalOutputText,
                    stepRecords: accumulatedStepRecords,
                    evidenceSummary: currentEvidenceSummary,
                    onEvent: onEvent
                )
            }

            emit(
                name: .planReady,
                status: .planning,
                request: turnRequest,
                message: plannedSteps.map(\.title).joined(separator: " -> "),
                stepRecords: accumulatedStepRecords,
                evidenceSummary: currentEvidenceSummary,
                turnIndex: currentTurn,
                maxTurns: maxTurns,
                totalSteps: plannedSteps.count,
                progressHint: SessionHUDProgressHint.workflowPreview,
                onEvent: onEvent
            )

            var shouldMoveToNextTurn = false
            for (stepIndex, plannedStep) in plannedSteps.enumerated() {
                let totalSteps = plannedSteps.count
                var retryCount = 0

                while true {
                    let attempt = retryCount + 1
                    let startedStep = V4StepRecord(
                        id: plannedStep.id,
                        traceID: plannedStep.traceID,
                        lane: plannedStep.lane,
                        goalSummary: plannedStep.goalSummary,
                        title: plannedStep.title,
                        status: .executing,
                        toolName: plannedStep.toolName,
                        inputSummary: plannedStep.inputSummary,
                        evidenceSummary: plannedStep.evidenceSummary,
                        startedAt: Date(),
                        attemptCount: attempt
                    )
                    emit(
                        name: .stateChanged,
                        status: .executing,
                        request: turnRequest,
                        message: "正在执行：\(startedStep.title)。",
                        stepID: startedStep.id,
                        stepRecords: accumulatedStepRecords,
                        evidenceSummary: currentEvidenceSummary,
                        turnIndex: currentTurn,
                        maxTurns: maxTurns,
                        stepIndex: stepIndex + 1,
                        totalSteps: totalSteps,
                        progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                        onEvent: onEvent
                    )
                    emit(
                        name: .stepStarted,
                        status: .executing,
                        request: turnRequest,
                        message: "第\(stepIndex + 1)/\(totalSteps)步：\(startedStep.title)",
                        stepID: startedStep.id,
                        stepRecords: accumulatedStepRecords,
                        evidenceSummary: currentEvidenceSummary,
                        turnIndex: currentTurn,
                        maxTurns: maxTurns,
                        stepIndex: stepIndex + 1,
                        totalSteps: totalSteps,
                        progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                        onEvent: onEvent
                    )

                    let latestToolResult = await executeStep(
                        startedStep,
                        request: turnRequest,
                        accumulatedStepRecords: accumulatedStepRecords,
                        turnIndex: currentTurn
                    )

                    if let error = latestToolResult.error, error.isRetryable, retryCount < maxRetryPerStep {
                        retryCount += 1
                        emit(
                            name: .stateChanged,
                            status: .retrying,
                            request: turnRequest,
                            message: "步骤失败，准备第\(retryCount)次重试：\(error.userMessage)",
                            stepID: startedStep.id,
                            stepRecords: accumulatedStepRecords,
                            evidenceSummary: currentEvidenceSummary,
                            turnIndex: currentTurn,
                            maxTurns: maxTurns,
                            stepIndex: stepIndex + 1,
                            totalSteps: totalSteps,
                            progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                            onEvent: onEvent
                        )
                        emit(
                            name: .stepRetryScheduled,
                            status: .retrying,
                            request: turnRequest,
                            message: "步骤重试 \(retryCount)/\(maxRetryPerStep)：\(startedStep.title)",
                            stepID: startedStep.id,
                            stepRecords: accumulatedStepRecords,
                            evidenceSummary: currentEvidenceSummary,
                            turnIndex: currentTurn,
                            maxTurns: maxTurns,
                            stepIndex: stepIndex + 1,
                            totalSteps: totalSteps,
                            progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                            onEvent: onEvent
                        )
                        continue
                    }

                    let finishedStatus: V4RunStatus = latestToolResult.error == nil ? .completed : .failed
                    let finishedStep = V4StepRecord(
                        id: startedStep.id,
                        traceID: startedStep.traceID,
                        lane: startedStep.lane,
                        goalSummary: startedStep.goalSummary,
                        title: startedStep.title,
                        status: finishedStatus,
                        toolName: startedStep.toolName,
                        inputSummary: startedStep.inputSummary,
                        outputSummary: latestToolResult.error?.userMessage ?? latestToolResult.outputText,
                        evidenceSummary: latestToolResult.evidenceSummary,
                        startedAt: startedStep.startedAt,
                        finishedAt: latestToolResult.finishedAt,
                        failureCode: latestToolResult.error?.failureCode,
                        attemptCount: attempt
                    )
                    accumulatedStepRecords.append(finishedStep)
                    currentEvidenceSummary = currentEvidence(
                        current: currentEvidenceSummary,
                        latest: latestToolResult.evidenceSummary
                    )
                    if let outputText = latestToolResult.outputText?.trimmingCharacters(in: .whitespacesAndNewlines), !outputText.isEmpty {
                        finalOutputText = outputText
                    }

                    emit(
                        name: .stepFinished,
                        status: finishedStatus,
                        request: turnRequest,
                        message: latestToolResult.error?.userMessage ?? "步骤执行完成。",
                        stepID: finishedStep.id,
                        stepRecords: accumulatedStepRecords,
                        evidenceSummary: currentEvidenceSummary,
                        turnIndex: currentTurn,
                        maxTurns: maxTurns,
                        stepIndex: stepIndex + 1,
                        totalSteps: totalSteps,
                        progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                        onEvent: onEvent
                    )

                    emit(
                        name: .stateChanged,
                        status: .verifying,
                        request: turnRequest,
                        message: "正在核验：\(finishedStep.title)。",
                        stepID: finishedStep.id,
                        stepRecords: accumulatedStepRecords,
                        evidenceSummary: currentEvidenceSummary,
                        turnIndex: currentTurn,
                        maxTurns: maxTurns,
                        stepIndex: stepIndex + 1,
                        totalSteps: totalSteps,
                        progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                        onEvent: onEvent
                    )

                    let verification = await verifier.verify(
                        for: requestedState(
                            from: request,
                            stepRecords: accumulatedStepRecords,
                            evidenceSummary: currentEvidenceSummary
                        ),
                        stepRecords: accumulatedStepRecords,
                        latestToolResult: latestToolResult
                    )
                    currentEvidenceSummary = currentEvidence(
                        current: currentEvidenceSummary,
                        latest: verification.evidenceSummary
                    )
                    emit(
                        name: .verificationFinished,
                        status: verificationStatusToRunStatus(verification.status),
                        request: turnRequest,
                        message: verification.message,
                        stepID: finishedStep.id,
                        stepRecords: accumulatedStepRecords,
                        evidenceSummary: currentEvidenceSummary,
                        turnIndex: currentTurn,
                        maxTurns: maxTurns,
                        stepIndex: stepIndex + 1,
                        totalSteps: totalSteps,
                        progressHint: SessionHUDProgressHint.workflowStep(index: stepIndex + 1, totalSteps: totalSteps),
                        onEvent: onEvent
                    )

                    let decision = await postStepDecider.decide(
                        after: finishedStep,
                        accumulatedStepRecords: accumulatedStepRecords,
                        latestToolResult: latestToolResult,
                        latestVerification: verification,
                        for: requestedState(
                            from: request,
                            stepRecords: accumulatedStepRecords,
                            evidenceSummary: currentEvidenceSummary
                        )
                    )

                    switch decision.action {
                    case .continue:
                        if stepIndex == totalSteps - 1 {
                            shouldMoveToNextTurn = true
                        }

                    case .finish, .askUser, .fail:
                        return finishRun(
                            request: requestedState(
                                from: request,
                                stepRecords: accumulatedStepRecords,
                                evidenceSummary: currentEvidenceSummary
                            ),
                            decision: decision,
                            finalOutputText: finalOutputText,
                            stepRecords: accumulatedStepRecords,
                            evidenceSummary: currentEvidenceSummary,
                            onEvent: onEvent
                        )
                    }

                    break
                }
            }

            if shouldMoveToNextTurn {
                continue
            }
        }

        return finishRun(
            request: requestedState(
                from: request,
                stepRecords: accumulatedStepRecords,
                evidenceSummary: currentEvidenceSummary
            ),
            decision: V4LoopDecision(
                action: .fail,
                message: "超过最大回合限制（\(maxTurns)）后仍未完成。",
                failureCode: .maxTurnsExceeded
            ),
            finalOutputText: finalOutputText,
            stepRecords: accumulatedStepRecords,
            evidenceSummary: currentEvidenceSummary,
            onEvent: onEvent
        )
    }

    private func executeStep(
        _ step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords: [V4StepRecord],
        turnIndex: Int
    ) async -> V4ToolResult {
        do {
            return try await stepExecutor(step, request, accumulatedStepRecords, turnIndex)
        } catch {
            return V4ToolResult(
                runID: request.runID,
                stepID: step.id,
                traceID: request.traceID,
                lane: request.lane,
                goalSummary: request.goalSummary,
                toolName: step.toolName ?? "unknown",
                outputText: nil,
                outputJSON: nil,
                evidenceSummary: "",
                startedAt: step.startedAt,
                finishedAt: Date(),
                error: V4ToolError(
                    failureCode: .toolExecutionFailed,
                    userMessage: "步骤执行失败：\(error.localizedDescription)",
                    debugMessage: String(describing: error),
                    isRetryable: false
                )
            )
        }
    }

    private func finishRun(
        request: V4RunRequest,
        decision: V4LoopDecision,
        finalOutputText: String?,
        stepRecords: [V4StepRecord],
        evidenceSummary: String,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) -> V4RunOutcome {
        let status = decisionToRunStatus(decision.action)
        let outcome = V4RunOutcome(
            sessionID: request.sessionID,
            runID: request.runID,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            status: status,
            finalStatusMessage: decision.message,
            finalOutputText: finalOutputText,
            displayText: displayText(from: stepRecords),
            stepRecords: stepRecords,
            evidenceSummary: evidenceSummary,
            failureCode: decision.failureCode,
            finishedAt: Date()
        )

        let eventName: V4RuntimeEventName
        switch decision.action {
        case .continue:
            eventName = .runCompleted
        case .finish:
            eventName = .runCompleted
        case .askUser:
            eventName = .runNeedsUserInput
        case .fail:
            eventName = .runFailed
        }

        emit(
            name: eventName,
            status: status,
            request: request,
            message: decision.message,
            stepRecords: stepRecords,
            evidenceSummary: evidenceSummary,
            onEvent: onEvent
        )
        return outcome
    }

    private func emit(
        name: V4RuntimeEventName,
        status: V4RunStatus,
        request: V4RunRequest,
        message: String,
        stepID: V4StepID? = nil,
        stepRecords: [V4StepRecord],
        evidenceSummary: String,
        turnIndex: Int? = nil,
        maxTurns: Int? = nil,
        stepIndex: Int? = nil,
        totalSteps: Int? = nil,
        progressHint: Double? = nil,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) {
        guard let onEvent else {
            return
        }
        onEvent(
            V4RuntimeEvent(
                name: name,
                status: status,
                sessionID: request.sessionID,
                runID: request.runID,
                traceID: request.traceID,
                lane: request.lane,
                goalSummary: request.goalSummary,
                message: message,
                stepID: stepID,
                turnIndex: turnIndex,
                maxTurns: maxTurns,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                stepRecords: stepRecords,
                evidenceSummary: evidenceSummary,
                progressHint: progressHint,
                createdAt: Date()
            )
        )
    }

    private func requestedState(
        from request: V4RunRequest,
        stepRecords: [V4StepRecord],
        evidenceSummary: String
    ) -> V4RunRequest {
        V4RunRequest(
            sessionID: request.sessionID,
            runID: request.runID,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            inputText: request.inputText,
            appName: request.appName,
            bundleID: request.bundleID,
            selectionText: request.selectionText,
            enabledFeatureIDs: request.enabledFeatureIDs,
            stepRecords: stepRecords,
            evidenceSummary: evidenceSummary,
            requestedAt: request.requestedAt
        )
    }

    private func currentEvidence(current: String, latest: String) -> String {
        let normalizedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLatest = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (normalizedCurrent.isEmpty, normalizedLatest.isEmpty) {
        case (true, true):
            return ""
        case (false, true):
            return normalizedCurrent
        case (true, false):
            return normalizedLatest
        case (false, false):
            if normalizedCurrent.contains(normalizedLatest) {
                return normalizedCurrent
            }
            if normalizedLatest.contains(normalizedCurrent) {
                return normalizedLatest
            }
            return normalizedCurrent + "\n" + normalizedLatest
        }
    }

    private func verificationStatusToRunStatus(_ status: V4VerificationStatus) -> V4RunStatus {
        switch status {
        case .passed:
            return .verifying
        case .failed:
            return .failed
        case .needsUserInput:
            return .waitingForUser
        }
    }

    private func decisionToRunStatus(_ action: V4LoopDecisionAction) -> V4RunStatus {
        switch action {
        case .continue:
            return .completed
        case .finish:
            return .completed
        case .askUser:
            return .waitingForUser
        case .fail:
            return .failed
        }
    }

    private func displayText(from stepRecords: [V4StepRecord]) -> String {
        let titles = stepRecords.map(\.title)
        guard !titles.isEmpty else {
            return "V4 Agent Loop"
        }
        return "V4: " + titles.joined(separator: " -> ")
    }

    @Sendable
    static func defaultStepExecutor(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords _: [V4StepRecord],
        turnIndex _: Int
    ) async throws -> V4ToolResult {
        let startedAt = Date()
        let toolName = step.toolName ?? "text.transform"
        let trimmedSelection = request.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = (trimmedSelection?.isEmpty == false) ? trimmedSelection : nil
        let textOutput = normalizedSelection ?? step.inputSummary

        let outputText: String?
        let evidenceSummary: String
        switch toolName {
        case "text.transform":
            outputText = textOutput
            evidenceSummary = "text.transform completed"
        case "apple.calendar.create":
            outputText = nil
            evidenceSummary = "apple.calendar.create completed"
        case "apple.notes.create":
            outputText = nil
            evidenceSummary = "apple.notes.create completed"
        case "apple.mail.compose":
            outputText = nil
            evidenceSummary = "apple.mail.compose completed"
        case "apple.music.control":
            outputText = nil
            evidenceSummary = "apple.music.control completed"
        case "feishu.cli":
            outputText = nil
            evidenceSummary = "feishu.cli completed"
        default:
            return V4ToolResult(
                runID: request.runID,
                stepID: step.id,
                traceID: request.traceID,
                lane: request.lane,
                goalSummary: request.goalSummary,
                toolName: toolName,
                outputText: nil,
                outputJSON: nil,
                evidenceSummary: "",
                startedAt: startedAt,
                finishedAt: Date(),
                error: V4ToolError(
                    failureCode: .toolValidationFailed,
                    userMessage: "未知 step tool：\(toolName)",
                    debugMessage: "unsupported tool name",
                    isRetryable: false
                )
            )
        }

        return V4ToolResult(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: toolName,
            outputText: outputText,
            outputJSON: nil,
            evidenceSummary: evidenceSummary,
            startedAt: startedAt,
            finishedAt: Date(),
            error: nil
        )
    }
}
