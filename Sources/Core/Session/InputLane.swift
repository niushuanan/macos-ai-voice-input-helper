import Foundation

enum InputLane: String {
    case directDictation
    case selectionRewrite

    var title: String {
        switch self {
        case .directDictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        }
    }

    var summary: String {
        switch self {
        case .directDictation:
            return "说话后直接把新文本写入当前输入位置。"
        case .selectionRewrite:
            return "说出指令后，直接改写已选中的文本。"
        }
    }
}
