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
            return "魔术先生"
        case .brainstormDiscussion:
            return "一口气全念对"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "说话后直接把新文本写入当前输入位置。"
        case .selectionRewrite:
            return "按住主键说指令，执行文字处理、日程、本地文档或邮件助手。"
        case .brainstormDiscussion:
            return "记录多人讨论并输出可直接给 AI 的上下文包。"
        }
    }
}
