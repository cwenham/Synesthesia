import Foundation

/// A tool Claude can use, written once and offered both over MCP and, later, in the app's own Claude sidebar
/// (design, section 8).
public struct Tool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// The JSON Schema of its arguments.
    public var inputSchema: JSONValue
    /// Whether it only looks. Tools that change anything are confirmed in the app (design, section 8: safety).
    public var readOnly: Bool
    public var run: @MainActor @Sendable (JSONValue) async throws -> ToolResult

    public init(
        name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = true,
        run: @escaping @MainActor @Sendable (JSONValue) async throws -> ToolResult
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.run = run
    }

    /// Its definition as MCP's `tools/list` gives it.
    public var definition: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "openWorldHint": false],
        ]
    }
}

/// What a tool gives back: text, images, or both, and whether it failed.
public struct ToolResult: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// An image, as PNG bytes.
        case png(Data)
    }

    public var content: [Content]
    public var isError: Bool

    public init(_ content: [Content], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// A result whose text is `value` as JSON.
    public static func json(_ value: JSONValue) -> ToolResult {
        ToolResult([.text(value.text(pretty: true))])
    }

    public static func failure(_ message: String) -> ToolResult {
        ToolResult([.text(message)], isError: true)
    }

    /// As MCP's `tools/call` returns it.
    public var mcp: JSONValue {
        let blocks: [JSONValue] = content.map { block in
            switch block {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .png(let data): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
            }
        }
        return ["content": .array(blocks), "isError": .bool(isError)]
    }
}

/// A tool's failure that Claude should read, such as an address that names nothing.
public struct ToolError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The tools on offer, by name.
public struct ToolRegistry: Sendable {
    public private(set) var tools: [Tool]

    public init(_ tools: [Tool]) {
        self.tools = tools
    }

    public func tool(_ name: String) -> Tool? {
        tools.first { $0.name == name }
    }

    /// Runs a tool, turning a thrown error into a failed result Claude can read.
    @MainActor
    public func call(_ name: String, arguments: JSONValue) async -> ToolResult? {
        guard let tool = tool(name) else { return nil }
        do {
            return try await tool.run(arguments)
        } catch is CancellationError {
            return .failure("Cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
