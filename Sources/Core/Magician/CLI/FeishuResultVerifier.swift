import Foundation

struct FeishuCLIEnvelope: Equatable {
    let ok: Bool?
    let errorMessage: String?
    let eventID: String?
    let messageID: String?
    let documentID: String?
    let fileToken: String?
    let baseID: String?
    let taskID: String?
    let tasklistID: String?

    var bestEvidence: String? {
        eventID
            ?? messageID
            ?? documentID
            ?? fileToken
            ?? baseID
            ?? taskID
            ?? tasklistID
    }
}

enum FeishuResultVerificationResult: Equatable {
    case verified(MagicianAgentObservation)
    case failed(userMessage: String, debugMessage: String)
}

struct FeishuResultVerifier {
    private let errorMapper = FeishuCLIErrorMapper()

    func verifySuccess(
        operation: FeishuCanonicalOperation,
        plan: FeishuCLICommandPlan,
        output: String
    ) -> FeishuResultVerificationResult {
        let requiresStructuredVerification = requiresStructuredVerification(
            operation: operation,
            plan: plan
        )
        let envelope = parsedCLIEnvelope(from: output)

        if let envelope, envelope.ok == false {
            return .failed(
                userMessage: errorMapper.userFacingCLIErrorMessage(
                    envelope.errorMessage ?? "飞书返回失败",
                    operation: operation
                ),
                debugMessage: output
            )
        }

        if !requiresStructuredVerification {
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .assumed,
                    targetSummary: plan.summary,
                    evidenceSummary: output.isEmpty ? plan.summary : summarized(output)
                )
            )
        }

        switch operation {
        case .calendarEvent:
            guard let envelope else {
                return .failed(
                    userMessage: "飞书没有返回结构化日程结果，无法确认是否创建成功，请重试。",
                    debugMessage: output
                )
            }
            guard let eventID = envelope.eventID, !eventID.isEmpty else {
                return .failed(
                    userMessage: "飞书没有返回有效的日程 ID，创建结果不可靠，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "event_id=\(eventID)"
                )
            )

        case .imUserMessage:
            guard let evidence = envelope?.messageID ?? envelope?.bestEvidence ?? extractedEvidenceID(from: output) else {
                return .failed(
                    userMessage: "飞书没有返回可核验的消息结果，无法确认消息是否已发出，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "message_id=\(evidence)"
                )
            )

        case .bitableApp:
            guard let evidence = envelope?.baseID ?? envelope?.bestEvidence ?? extractedEvidenceID(from: output) else {
                return .failed(
                    userMessage: "飞书没有返回多维表格标识，无法确认是否创建成功，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "base_id=\(evidence)"
                )
            )

        case .createDoc, .updateDoc, .fetchDoc:
            guard let evidence = envelope?.documentID ?? envelope?.bestEvidence ?? extractedEvidenceID(from: output) else {
                return .failed(
                    userMessage: "飞书没有返回文档标识，无法确认文档操作是否成功，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "doc_id=\(evidence)"
                )
            )

        case .driveFile:
            guard let evidence = envelope?.fileToken ?? envelope?.bestEvidence ?? extractedEvidenceID(from: output) else {
                return .failed(
                    userMessage: "飞书没有返回文件标识，无法确认云盘操作是否成功，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "file_token=\(evidence)"
                )
            )

        case .taskTask, .taskSubtask, .taskTasklist:
            guard let evidence = envelope?.taskID ?? envelope?.tasklistID ?? envelope?.bestEvidence ?? extractedEvidenceID(from: output) else {
                return .failed(
                    userMessage: "飞书没有返回任务标识，无法确认任务操作是否成功，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: plan.summary,
                    evidenceSummary: "task_id=\(evidence)"
                )
            )

        default:
            if let evidence = envelope?.bestEvidence ?? extractedEvidenceID(from: output) {
                return .verified(
                    MagicianAgentObservation(
                        verificationStatus: .verified,
                        targetSummary: plan.summary,
                        evidenceSummary: evidence
                    )
                )
            }
            if requiresStructuredVerification {
                return .failed(
                    userMessage: "飞书没有返回可核验证据，无法确认写入是否成功，请重试。",
                    debugMessage: output
                )
            }
            return .verified(
                MagicianAgentObservation(
                    verificationStatus: .assumed,
                    targetSummary: plan.summary,
                    evidenceSummary: output.isEmpty ? plan.summary : summarized(output)
                )
            )
        }
    }

    func parsedCLIEnvelope(from text: String) -> FeishuCLIEnvelope? {
        let candidates = jsonEnvelopeCandidates(from: text)
        for candidate in candidates {
            guard
                let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any]
            else {
                continue
            }

            let ok = dictionary["ok"] as? Bool
            let errorMessage = (dictionary["error"] as? [String: Any])?["message"] as? String
            let dataPayload = dictionary["data"] as? [String: Any]
            let eventID = stringValue(forKeys: ["event_id"], in: dataPayload)
            let messageID = stringValue(forKeys: ["message_id", "msg_id"], in: dataPayload)
            let documentID = stringValue(forKeys: ["document_id", "doc_id", "obj_token", "token"], in: dataPayload)
            let fileToken = stringValue(forKeys: ["file_token", "token"], in: dataPayload)
            let baseID = stringValue(forKeys: ["app_token", "base_id", "token"], in: dataPayload)
            let taskID = stringValue(forKeys: ["task_id", "guid"], in: dataPayload)
            let tasklistID = stringValue(forKeys: ["tasklist_id", "guid"], in: dataPayload)
            if ok == nil,
               (errorMessage ?? "").isEmpty,
               [eventID, messageID, documentID, fileToken, baseID, taskID, tasklistID].allSatisfy({ ($0 ?? "").isEmpty })
            {
                continue
            }

            return FeishuCLIEnvelope(
                ok: ok,
                errorMessage: errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                eventID: eventID,
                messageID: messageID,
                documentID: documentID,
                fileToken: fileToken,
                baseID: baseID,
                taskID: taskID,
                tasklistID: tasklistID
            )
        }
        return nil
    }

    private func summarized(_ text: String) -> String {
        summarizedHistoryText(text, limit: 64)
    }

    private func requiresStructuredVerification(
        operation: FeishuCanonicalOperation,
        plan: FeishuCLICommandPlan
    ) -> Bool {
        if operation == .calendarEvent {
            return plan.arguments.starts(with: ["calendar", "+create"])
        }
        if operation == .bitableApp {
            return plan.arguments.starts(with: ["base", "+base-create"])
        }
        if operation == .docMedia {
            return plan.arguments.starts(with: ["docs", "+media-insert"])
        }
        if operation == .driveFile {
            return plan.arguments.starts(with: ["drive", "+upload"])
        }
        if operation == .sheet {
            return plan.arguments.starts(with: ["sheets", "+write"])
        }
        if operation == .taskTask {
            return !plan.arguments.starts(with: ["task", "+get-my-tasks"])
        }
        return FeishuOperationCatalog.descriptor(for: operation).requiresStructuredVerification
    }

    private func extractedEvidenceID(from text: String) -> String? {
        let patterns = [
            #"(?i)\b(event_id|message_id|msg_id|document_id|doc_id|app_token|base_id|file_token|task_id|tasklist_id)\b["=: ]+([A-Za-z0-9_\-]+)"#,
            #"\b(oc_[A-Za-z0-9]+|ou_[A-Za-z0-9]+|om_[A-Za-z0-9]+|omt_[A-Za-z0-9]+)\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(location: 0, length: (text as NSString).length)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else {
                continue
            }
            let captureIndex = match.numberOfRanges > 2 ? 2 : 1
            guard let matchedRange = Range(match.range(at: captureIndex), in: text) else {
                continue
            }
            let value = String(text[matchedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func jsonEnvelopeCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        var candidates: [String] = [trimmed]
        if let extracted = extractJSONObject(from: trimmed), extracted != trimmed {
            candidates.append(extracted)
        }
        let lines = trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        candidates.append(contentsOf: lines)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func extractJSONObject(from text: String) -> String? {
        guard
            let first = text.firstIndex(of: "{"),
            let last = text.lastIndex(of: "}"),
            first <= last
        else {
            return nil
        }
        return String(text[first...last])
    }

    private func stringValue(forKeys keys: [String], in payload: [String: Any]?) -> String? {
        guard let payload else {
            return nil
        }
        for key in keys {
            if let string = payload[key] as? String {
                let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }
}
