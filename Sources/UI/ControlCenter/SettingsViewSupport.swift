import SwiftUI

enum MemoryToolbarLayoutMode: Equatable {
    case singleRow
    case stacked

    static func resolve(
        availableWidth: CGFloat,
        filterBarWidth: CGFloat,
        clearButtonWidth: CGFloat,
        spacing: CGFloat
    ) -> Self {
        guard availableWidth > 0, filterBarWidth > 0, clearButtonWidth > 0 else {
            return .singleRow
        }

        let requiredWidth = filterBarWidth + clearButtonWidth + spacing
        return requiredWidth <= availableWidth ? .singleRow : .stacked
    }
}

enum MemoryToolbarMeasureID: Hashable {
    case container
    case filterBar
    case clearButton
}

struct MemoryToolbarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [MemoryToolbarMeasureID: CGFloat] = [:]

    static func reduce(
        value: inout [MemoryToolbarMeasureID: CGFloat],
        nextValue: () -> [MemoryToolbarMeasureID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func reportMemoryToolbarWidth(_ id: MemoryToolbarMeasureID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MemoryToolbarWidthPreferenceKey.self,
                    value: [id: proxy.size.width]
                )
            }
        )
    }
}

enum ConnectionFailureAdvisor {
    static func suggestion(for result: ConnectionTestResult) -> String {
        if let status = result.httpStatus {
            switch status {
            case 401, 403:
                return "请核对 API Key 是否正确、是否过期，并确认模型权限。"
            case 404:
                return "请核对 API 地址和模型名，确认接口兼容 OpenAI 路径。"
            case 429:
                return "请检查额度或限频策略，稍后再试。"
            case 500...599:
                return "服务端临时异常，稍后重试并查看服务状态页。"
            default:
                break
            }
        }

        if result.message.contains("密钥") || result.hint.contains("密钥") {
            return "先保存有效 API Key，再重新测试。"
        }

        if result.message.contains("接口地址") || result.hint.contains("接口地址") {
            return "请确认 Base URL 以 http/https 开头，且指向可用网关。"
        }

        if result.message.contains("模型") || result.hint.contains("模型") {
            return "请确认模型名与服务端可用模型一致。"
        }

        if result.message.contains("网络") || result.hint.contains("网络") {
            return "请检查网络、代理或防火墙，再重试。"
        }

        return "建议依次检查地址、模型名、密钥、额度和网络。"
    }
}
