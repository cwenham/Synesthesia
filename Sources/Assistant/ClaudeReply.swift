import Foundation
import MeepClient

/// One reply from the Messages API as it streams in: its content blocks, built from the stream's events by index, and
/// how it ended.
public struct ClaudeReply: Sendable {
    public var id: String?
    /// The model that's writing it: the requested one, or a fallback after a refusal.
    public var model: String?
    public private(set) var blocks: [Block] = []
    public var stopReason: String?
    /// Set only when `stopReason` is `refusal`: its category and explanation, either of which can be null.
    public var stopDetails: JSONValue?
    public var usage: JSONValue = [:]
    /// Thinking blocks the API dropped or let through after a change to the history, under the binding beta.
    public var inputTransformations: [JSONValue] = []
    /// Whether `message_stop` has come.
    public private(set) var isFinished = false

    public init() {}

    /// A content block, as it's streamed and as it's sent back.
    public struct Block: Sendable, Equatable {
        public let index: Int
        public var kind: Kind
        public var isComplete = false

        public enum Kind: Sendable, Equatable {
            case text(String)
            /// Summarised thinking, or a progress note between tool calls; its signature arrives just before it ends.
            case thinking(String, signature: String)
            /// A tool call: its input arrives as pieces of JSON, parsed when the block ends.
            case toolUse(id: String, name: String, json: String, input: JSONValue?)
            /// A switch to a fallback model after a refusal: where it was in the content matters, so it's kept.
            case fallback(JSONValue)
            /// Anything else, such as redacted thinking: kept as it came and sent back as it came.
            case other(JSONValue)
        }

        /// As the next request sends it back.
        var echo: JSONValue {
            switch kind {
            case .text(let text): ["type": "text", "text": .string(text)]
            case .thinking(let text, let signature): ["type": "thinking", "thinking": .string(text), "signature": .string(signature)]
            // Input that wasn't JSON goes back as an empty object; Claude is told what it sent in the result.
            case .toolUse(let id, let name, _, let input): ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input ?? [:]]
            case .fallback(let raw), .other(let raw): raw
            }
        }

        var type: String {
            switch kind {
            case .text: "text"
            case .thinking: "thinking"
            case .toolUse: "tool_use"
            case .fallback: "fallback"
            case .other(let raw): raw["type"]?.string ?? "unknown"
            }
        }
    }

    /// What one event changed, for the sidebar to show as it streams.
    public enum Change: Sendable, Equatable {
        case started(Int)
        case grew(Int)
        case finished(Int)
        case message
        case none
    }

    /// Applies one event's JSON. Unknown events and deltas are ignored, as the API's versioning asks.
    public mutating func apply(_ event: JSONValue) throws -> Change {
        switch event["type"]?.string {
        case "message_start":
            let message = event["message"] ?? [:]
            id = message["id"]?.string
            model = message["model"]?.string
            usage = message["usage"] ?? [:]
            if let found = message["input_transformations"]?.array { inputTransformations = found }
            return .message
        case "content_block_start":
            guard let index = event["index"]?.number.map(Int.init), let start = event["content_block"] else { return .none }
            let kind: Block.Kind = switch start["type"]?.string {
            case "text": .text(start["text"]?.string ?? "")
            case "thinking": .thinking(start["thinking"]?.string ?? "", signature: start["signature"]?.string ?? "")
            case "tool_use": .toolUse(id: start["id"]?.string ?? "", name: start["name"]?.string ?? "", json: "", input: nil)
            case "fallback": .fallback(start)
            default: .other(start)
            }
            blocks.removeAll { $0.index == index }
            blocks.append(Block(index: index, kind: kind))
            return .started(index)
        case "content_block_delta":
            guard let index = event["index"]?.number.map(Int.init), let at = blocks.firstIndex(where: { $0.index == index }),
                  let delta = event["delta"] else { return .none }
            switch (blocks[at].kind, delta["type"]?.string) {
            case (.text(let text), "text_delta"):
                blocks[at].kind = .text(text + (delta["text"]?.string ?? ""))
            case (.thinking(let text, let signature), "thinking_delta"):
                blocks[at].kind = .thinking(text + (delta["thinking"]?.string ?? ""), signature: signature)
            case (.thinking(let text, _), "signature_delta"):
                blocks[at].kind = .thinking(text, signature: delta["signature"]?.string ?? "")
            case (.toolUse(let id, let name, let json, _), "input_json_delta"):
                blocks[at].kind = .toolUse(id: id, name: name, json: json + (delta["partial_json"]?.string ?? ""), input: nil)
            default:
                return .none
            }
            return .grew(index)
        case "content_block_stop":
            guard let index = event["index"]?.number.map(Int.init), let at = blocks.firstIndex(where: { $0.index == index }) else { return .none }
            if case .toolUse(let id, let name, let json, _) = blocks[at].kind {
                // Parsed strictly: input that streamed in without the API checking it may be cut short or not JSON.
                let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
                let input = text.isEmpty ? JSONValue.object([:]) : try? JSONValue.parse(Data(text.utf8))
                blocks[at].kind = .toolUse(id: id, name: name, json: json, input: input)
            }
            blocks[at].isComplete = true
            return .finished(index)
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let details = event["delta"]?["stop_details"], details != .null { stopDetails = details }
            if case .object(let counts)? = event["usage"], case .object(var all) = usage {
                // Counts here are cumulative: the latest wins.
                for (key, value) in counts { all[key] = value }
                usage = .object(all)
            }
            if let found = event["input_transformations"]?.array { inputTransformations = found }
            return .message
        case "message_stop":
            isFinished = true
            return .message
        case "error":
            throw ClaudeAPIError.from(event: event, requestID: nil)
        default:
            return .none
        }
    }

    public func block(_ index: Int) -> Block? {
        blocks.first { $0.index == index }
    }

    /// Where the last switch to a fallback model is, if there was one.
    private var lastFallback: Int? {
        blocks.lastIndex { if case .fallback = $0.kind { true } else { false } }
    }

    /// The content to send back as the assistant's turn. After a switch to a fallback model, what the declining model
    /// wrote before the last switch goes back as text only, with the switch where it was; everything after it goes
    /// back whole (the API's rules for continuing after a fallback). Empty text is left out, as the API refuses it.
    public var echo: [JSONValue] {
        let boundary = lastFallback
        return blocks.enumerated().compactMap { position, block in
            if case .text(let text) = block.kind, text.isEmpty { return nil }
            if let boundary, position < boundary {
                switch block.kind {
                case .text, .fallback: return block.echo
                default: return nil
                }
            }
            return block.echo
        }
    }

    /// The tool calls to answer: those after the last switch to a fallback model, if there was one.
    public var toolCalls: [Block] {
        let start = lastFallback.map { $0 + 1 } ?? 0
        return blocks[start...].filter { if case .toolUse = $0.kind { true } else { false } }
    }

    /// The text written so far, for a reply that was stopped: complete or not, without thinking or tool calls.
    public var textSoFar: [JSONValue] {
        blocks.compactMap { block in
            guard case .text(let text) = block.kind, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["type": "text", "text": .string(text)]
        }
    }
}
