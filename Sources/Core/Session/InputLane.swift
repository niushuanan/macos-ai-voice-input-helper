import Foundation

enum InputLane: String {
    case directDictation
    case selectionRewrite
    case brainstormDiscussion

    var title: String {
        switch self {
        case .directDictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        case .brainstormDiscussion:
            return "头脑风暴（Beta）"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "说话后直接把新文本写入当前输入位置。"
        case .selectionRewrite:
            return "说出指令后，直接改写已选中的文本。"
        case .brainstormDiscussion:
            return "记录多人讨论并输出可直接给 AI 的上下文包。"
        }
    }
}
