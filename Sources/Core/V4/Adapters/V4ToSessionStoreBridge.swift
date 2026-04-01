import Foundation

@MainActor
final class V4ToSessionStoreBridge {
    func applyRunStart(
        request: V4RunRequest,
        to sessionStore: SessionStore
    ) {
        // TODO(Window 05): 把 `V4RuntimeEvent.status/message/progressHint` 映到
        // `SessionStore.phase/statusMessage/hudProgressHint/errorMessage`。
        // TODO(Window 06): 把 native fast lane 的 `V4RunRequest.lane/selectionText/appName`
        // 映到 `SessionStore.activeLane/latestFocusContext/latestOutputResult` 的桥接输入。
        _ = request
        _ = sessionStore
    }

    func applyRuntimeEvent(
        _ event: V4RuntimeEvent,
        to sessionStore: SessionStore
    ) {
        // TODO(Window 05): 接 tool 权限、tool 执行、verification 事件到
        // `phase/statusMessage/hudProgressHint/errorMessage`。
        // TODO(Window 06): 接 native fast 写回阶段的事件到
        // `latestOutputResult/activeLane`。
        _ = event
        _ = sessionStore
    }

    func applyRunOutcome(
        _ outcome: V4RunOutcome,
        to sessionStore: SessionStore
    ) {
        // TODO(Window 05): 用 `finalStatusMessage/displayText/evidenceSummary`
        // 更新 `statusMessage` 与调试摘要展示。
        // TODO(Window 06): 用 `finalOutputText/lane` 驱动 native fast 写回后的
        // `latestOutputResult/activeLane` 同步。
        _ = outcome
        _ = sessionStore
    }
}
