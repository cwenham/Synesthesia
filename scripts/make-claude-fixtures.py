#!/usr/bin/env python3
# Writes the Claude sidebar's SSE fixtures to Tests/AssistantTests/Fixtures: streams shaped as the Messages API
# documents its events (streaming, tool use, thinking, refusals and fallbacks), for the tests' fake transport to replay.
# Usage: scripts/make-claude-fixtures.py [folder]
import json, sys, os
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "Tests", "AssistantTests", "Fixtures")

def ev(name, data):
    return f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False, separators=(',', ':'))}\n\n"

def start(id, model="claude-opus-5-5", inp=1200, read=0, write=0):
    return ev("message_start", {"type": "message_start", "message": {
        "id": id, "type": "message", "role": "assistant", "model": model, "content": [],
        "stop_reason": None, "stop_sequence": None, "stop_details": None,
        "usage": {"input_tokens": inp, "cache_creation_input_tokens": write, "cache_read_input_tokens": read, "output_tokens": 1},
        "input_transformations": []}})

def ping():
    return ev("ping", {"type": "ping"})

def text(i, pieces):
    s = ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
    for p in pieces:
        s += ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": p}})
    return s + ev("content_block_stop", {"type": "content_block_stop", "index": i})

def thinking(i, pieces, sig):
    s = ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "thinking", "thinking": "", "signature": ""}})
    for p in pieces:
        s += ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "thinking_delta", "thinking": p}})
    s += ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "signature_delta", "signature": sig}})
    return s + ev("content_block_stop", {"type": "content_block_stop", "index": i})

def tool(i, id, name, pieces, stop=True):
    s = ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "tool_use", "id": id, "name": name, "input": {}}})
    for p in pieces:
        s += ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": p}})
    if stop:
        s += ev("content_block_stop", {"type": "content_block_stop", "index": i})
    return s

def fallback(i, frm, to, category):
    block = {"type": "fallback", "from": {"model": frm}, "to": {"model": to}, "trigger": {"type": "refusal", "category": category}}
    return ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": block}) + \
        ev("content_block_stop", {"type": "content_block_stop", "index": i})

def end(reason, out=120, details=None, iterations=None):
    delta = {"stop_reason": reason, "stop_sequence": None}
    if details is not None:
        delta["stop_details"] = details
    usage = {"output_tokens": out}
    if iterations:
        usage["iterations"] = iterations
    return ev("message_delta", {"type": "message_delta", "delta": delta, "usage": usage}) + ev("message_stop", {"type": "message_stop"})

files = {}

files["answer.sse"] = start("msg_answer", read=1100) + ": a comment the parser ignores\n\n" + \
    thinking(0, ["The person asks what's busiest. ", "Orders is busiest — about 40 a second."], "sig-answer-0") + ping() + \
    text(1, ["The busiest pipeline is ", "**orders**, at about 40 messages a second", " — see meep://sim/orders/m2."]) + end("end_turn", 64)

files["loop-1.sse"] = start("msg_loop1", write=1500) + \
    thinking(0, ["I'll list the Continuum first."], "sig-loop1-0") + \
    text(1, ["Let me look."]) + \
    tool(2, "toolu_list", "list_continuum", ["", "{}"]) + end("tool_use", 40)

files["loop-2.sse"] = start("msg_loop2", read=1500, write=400) + \
    thinking(0, ["Orders is there; I'll describe it."], "sig-loop2-0") + \
    tool(1, "toolu_describe", "describe_pipeline", ["{\"addr", "ess\": \"meep://si", "m/orders\"", "}"]) + end("tool_use", 30)

files["loop-3.sse"] = start("msg_loop3", read=1900, write=900) + \
    text(0, ["Orders has its modules running; meep://sim/orders/m2 passes the most."]) + end("end_turn", 50)

files["invalid-json.sse"] = start("msg_badjson") + \
    tool(0, "toolu_bad", "echo", ["{\"text\": \"unterminated", "}"]) + end("tool_use", 12)

files["invalid-input.sse"] = start("msg_badinput") + \
    tool(0, "toolu_count", "count", ["{\"n\": 50}"]) + \
    tool(1, "toolu_words", "echo", ["{\"words\": \"x\"}"]) + end("tool_use", 20)

files["refusal.sse"] = start("msg_refusal") + \
    text(0, ["Sure, here"]) + \
    end("refusal", 3, details={"type": "refusal", "category": "cyber", "explanation": "This request was declined because it could enable cyber harm."})

files["max-tokens.sse"] = start("msg_long") + \
    text(0, ["Here's a long answer…"]) + \
    tool(1, "toolu_cut", "echo", ["{\"text\": \"abc"], stop=False) + end("max_tokens", 64000)

files["overloaded.sse"] = start("msg_over") + text(0, ["Half a"]) + \
    ev("error", {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})

files["fallback.sse"] = start("msg_fb", model="claude-opus-4-8") + \
    fallback(0, "claude-opus-5-5", "claude-opus-4-8", "cyber") + \
    text(1, ["Here's what the tap shows."]) + \
    end("end_turn", 30, iterations=[{"type": "message", "model": "claude-opus-5-5", "input_tokens": 1200, "output_tokens": 0},
                                    {"type": "fallback_message", "model": "claude-opus-4-8", "input_tokens": 1200, "output_tokens": 30}])

files["fallback-midstream.sse"] = start("msg_fbmid") + \
    thinking(0, ["Thinking before the switch."], "sig-before") + \
    text(1, ["Before the switch. "]) + \
    tool(2, "toolu_before", "echo", ["{\"text\": \"before\"}"]) + \
    fallback(3, "claude-opus-5-5", "claude-opus-4-8", None) + \
    text(4, ["After the switch."]) + \
    tool(5, "toolu_after", "echo", ["{\"text\": \"after\"}"]) + end("tool_use", 40)

files["change-call.sse"] = start("msg_change") + \
    tool(0, "toolu_change", "change", ["{\"address\": \"meep://sim/orders\", \"summary\": \"Drop empty orders\"}"]) + end("tool_use", 20)

files["peek-call.sse"] = start("msg_peek") + \
    tool(0, "toolu_peek", "peek", ["{\"address\": \"meep://sim/orders/m2\"}"]) + end("tool_use", 20)

files["slow-call.sse"] = start("msg_slow") + \
    tool(0, "toolu_slow", "slow", ["{}"]) + end("tool_use", 10)

files["partial.sse"] = start("msg_partial") + \
    thinking(0, ["Working it out."], "sig-partial") + \
    ev("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}) + \
    ev("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "The first half of an answer"}})

files["capture.sse"] = start("msg_capture") + \
    tool(0, "toolu_capture", "picture", ["{}"]) + end("tool_use", 10)

for name, body in files.items():
    with open(os.path.join(out, name), "w") as f:
        f.write(body)
print(len(files), "fixtures")
