# Step 3: the MCP server

Written 16 November 2026. The third step of the order of work in [architecture-round-1.md](architecture-round-1.md), section 11: the MCP server, early, with the tools for looking and showing, so Claude Code sessions can check what the app shows while the rest is built. It needed nothing from Meep2. Nothing is committed.

## What's built

- **`Transport`:** a Unix socket server and a stream over a connected socket (`UnixSocketServer`, `SocketStream`), and where the app serves MCP (`MCPSocket`).
  - **The socket:** `~/Library/Application Support/Synesthesia/mcp.sock`, or `$SYNESTHESIA_MCP_SOCKET`. Only its owner can use it.
  - **A file left behind** by a crash is replaced, but a socket another copy of the app is serving is left alone.
- **`Assistant`** (new, with no UI):
  - **The tool registry:** `Tool` and `ToolRegistry`, written once, to be offered by the Claude sidebar too (step 9).
  - **The MCP protocol** for one connection (`MCPSession`).
  - **The tools** (`ContinuumTools`).
  - **What the tools need from the app,** as a protocol (`Viewer`): the Continuum, the selection, the canvas.
- **`synesthesia-mcp`** (new, in the app bundle beside the app): joins an MCP client's standard input and output to the app's socket. It's a plain pipe; the app speaks the protocol. If the app isn't running, it starts it in the background and waits up to 20 seconds for the socket.
- **The app:**
  - **From launch:** it serves MCP and follows its hosts from launch, rather than once its window has opened.
  - **One window:** it has a single window (`Window`, not `WindowGroup`), whose selection now lives in a `Workspace` that tools can change.
  - **Closing the window doesn't quit the app,** so the server carries on. Clicking the Dock icon opens it again, and so does the `show` tool.
  - **Setup command:** Synesthesia › Copy Claude Code Setup Command copies the command that adds the server to Claude Code everywhere.
- **`.mcp.json`:** offers the server to Claude Code sessions in this repository. Claude Code asks you to approve it the first time you start `claude` here.

### The tools

| Tool | What it does |
|---|---|
| `list_continuum` | Hosts, whether each can be reached, their pipelines with state and messages a second, and what's selected. |
| `describe_pipeline` | A pipeline's modules and links, with each module's verb, role, parameters and line, every count that isn't zero, and rates now. |
| `read_pipeline_text` | The Meeplang file, with line numbers, and which module is on which line. This Mac's pipelines only, for now. |
| `watch_counts` | Measures a pipeline's or one module's counts over 1 to 60 seconds: how much each count rose, and the rate over that time. While it watches, the counts come five times a second. |
| `describe_view` | What the canvas shows, as structure. Gives the pipeline, the zoom, and each tile's place on screen, label and selection. Says whether each wire's particles are single messages or rate streaks, and any queues and spills. |
| `capture_view` | The canvas as a PNG. |
| `show` | Points the app at an address. A host or pipeline is selected; a module's pipeline is opened and the canvas eases to the module and selects it. It opens the window if it's closed, without taking your focus. |

- **Addresses:** tools take addresses such as `meep://local/orders/m3`.
  - **Modules** can be named by key, name, label or number.
  - **The host** can be left out when only one host has a pipeline of that name: `orders/Prices`.
- **Mistakes:** a mistake in an address gets an answer that lists what's there.
- **Results:** each result is JSON text, which Claude reads as easily as structured output and people can read in a transcript.

## Tests

- **94 tests in 20 suites, all passing,** twice in a row; step 2 had 76.
- **The new tests:**
  - **The protocol** over an in-memory stream: the handshake, choosing a version, errors, a cancelled call, and calls running side by side.
  - **Each tool** against a simulated host.
  - **The socket server.**
  - **The `synesthesia-mcp` program** end to end, as a client starts it.
- **In the app,** through the bundled `synesthesia-mcp`, against the test daemon:
  - **`list_continuum` and `watch_counts`.** Over three seconds, Keep received 15 messages, passed on 12 and held back 3.
  - **`show`, `describe_view` and `capture_view`.**
  - **`show` with the window closed.** It reopened the window without taking focus, opened the pipeline, and selected the module.

## Decisions made while building

- **The protocol is written here, not with the MCP Swift SDK** that section 8 suggested.
  - **It's small:** tools need only `initialize`, `ping`, `tools/list`, `tools/call` and cancelling, as JSON-RPC one message to a line. That's about 150 lines, with no dependency to fetch or keep in step with Swift 6.
  - **It follows step 1:** the WebSocket client was done the same way.
  - **Versions:** it speaks protocol versions 2024-11-05 to 2025-11-25. It answers a client asking for a newer one with 2025-11-25.
- **The bridge is a plain pipe.** All the protocol lives in the app, so the bridge needs no updating when tools change.
- **`show` is the one tool that changes anything,** and only what the app shows, so it isn't confirmed. Tools that tap, inject or edit will be confirmed in the app (section 8, safety).
- **Counts over a period are measured, not looked up.** Synesthesia keeps no history yet, so `watch_counts` watches. History comes with FlowKit's later work.
- **Text is read from the file** for this Mac's pipelines. Step 4 moves it to `meep lsp`, which will also give text for other hosts' pipelines.
- **A host that can't be reached keeps saying why while it's tried again.** Before, its status flickered to "Connecting…" every three seconds, which also made a step 1 test fail now and then.

## Not checked

- **Through Claude Code itself.** `claude mcp list` finds the project's server and says it's waiting for your approval. But Claude Code's own sign-in had expired in this environment, so I couldn't run a request through it. Everything Claude Code would send was tested with my own client, through the same bundled program.
- **Opening the app normally.** I started it in the background, where the window doesn't open until something asks for it. A launch from Finder or the Dock should open the window as before; I didn't check, because it would have taken your screen.

## Not done yet

- **Describing verbs:** this needs the verb catalogue from `meep lsp` (prompt 3), in step 4.
- **Taps and injection:** step 6.
- **Proposed edits:** step 5.
- **The Claude sidebar:** step 9. It will use the same registry.

## Next

**Step 4, Meeplang beside the canvas,** which needs prompt 3 in Meep2 first: `meep lsp` with `meep/graph`, semantic tokens and the verb catalogue.
