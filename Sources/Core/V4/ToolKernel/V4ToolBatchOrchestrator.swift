import Foundation

struct V4ToolBatchOrchestrator: V4ToolBatchOrchestrating {
    private let kernel: V4ToolKernel
    private let registry: V4ToolRegistry

    init(
        kernel: V4ToolKernel,
        registry: V4ToolRegistry
    ) {
        self.kernel = kernel
        self.registry = registry
    }

    func execute(
        toolUses: [V4ToolUse],
        contexts: [V4ToolExecutionContext]
    ) async -> [V4ToolResult] {
        precondition(toolUses.count == contexts.count, "toolUses and contexts count mismatch")
        let indexed = Array(zip(toolUses.indices, zip(toolUses, contexts)))
        let batches = partition(indexed)
        var results = Array<V4ToolResult?>(repeating: nil, count: toolUses.count)

        for batch in batches {
            if batch.isConcurrencySafe {
                await withTaskGroup(of: (Int, V4ToolResult).self) { group in
                    for item in batch.items {
                        group.addTask {
                            let (index, pair) = item
                            let (toolUse, context) = pair
                            let result = await kernel.execute(toolUse: toolUse, context: context)
                            return (index, result)
                        }
                    }

                    for await (index, result) in group {
                        results[index] = result
                    }
                }
            } else {
                for item in batch.items {
                    let (index, pair) = item
                    let (toolUse, context) = pair
                    results[index] = await kernel.execute(toolUse: toolUse, context: context)
                }
            }
        }

        return results.compactMap { $0 }
    }

    private func partition(
        _ items: [(Int, (V4ToolUse, V4ToolExecutionContext))]
    ) -> [Batch] {
        var batches = [Batch]()

        for item in items {
            let toolName = item.1.0.toolName
            let isConcurrencySafe = registry.spec(for: toolName)?.isConcurrencySafe ?? false
            if
                isConcurrencySafe,
                let lastIndex = batches.indices.last,
                batches[lastIndex].isConcurrencySafe
            {
                batches[lastIndex].items.append(item)
            } else {
                batches.append(Batch(isConcurrencySafe: isConcurrencySafe, items: [item]))
            }
        }

        return batches
    }
}

private struct Batch {
    let isConcurrencySafe: Bool
    var items: [(Int, (V4ToolUse, V4ToolExecutionContext))]
}
