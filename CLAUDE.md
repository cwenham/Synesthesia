# Synesthesia

A Swift app (Mac first, then iPad and iPhone) that edits and visualises Meep2 pipelines, from a module's C# up to the hosts of a whole network. Meep2 is in `~/Projects/Meep2`.

The design is in [docs/Design/architecture-round-1.md](docs/Design/architecture-round-1.md), with the user's answers to its questions. Step reports follow it in `docs/Design/step-N.md`. What Synesthesia needs from Meep2 is in [docs/Design/meep2-prompts.md](docs/Design/meep2-prompts.md).

## Commands

- Build: `swift build`
- Test: `swift test` (Swift Testing). Tests against a real daemon run only when `MEEP_TEST_SOCKET` names its socket (Meep2 0c83a49 or later), with a steadily ticking pipeline named by `MEEP_TEST_PIPELINE` (default `busy`). Tests of flows between two daemons run only when `MEEP_TEST_FLOW_SOCKET` also names a second daemon's socket (Meep2 a5de139 or later), with a Fetch on the first reaching a Listen on the second. Tests against a real `meep lsp` run only when `MEEP_EXECUTABLE` names a `meep` built from Meep2 at 0278da4 or later. The SSH tunnel's test runs only when `MEEP_TEST_SSH` names a destination, with `MEEP_TEST_SSH_PORT`, `MEEP_TEST_SSH_OPTIONS` (such as `-i <key>`) and `MEEP_TEST_SSH_MEEP` (how to run meep there). Tests against the real Claude API cost money and run only when `ANTHROPIC_API_KEY` is set, which is the person's to do; with `CLAUDE_RECORD_FIXTURES` naming a folder they also save the API's streams there, to refresh the sidebar's fixtures in `Tests/AssistantTests/Fixtures`.
- Pictures: `SYNESTHESIA_SNAPSHOTS=<folder> swift test --filter 'MetalStageTests|SynesthesiaUITests'` saves what the renderer and the hover cards drew there as PNGs, to look at without the app.
- App: `scripts/build-app.sh` (or `scripts/build-app.sh debug`), then `open .build/Synesthesia.app`. It starts `meep lsp` from `$MEEP_EXECUTABLE`, or the `meep` on the `PATH` or the login shell's `PATH`.
- Window pictures: with `SYNESTHESIA_CAPTURES=<folder>`, each `capture_view` also saves the whole window there as the app draws it, without screen recording.
- Hosts: those added with Add Host…, and budgets, are kept in `~/Library/Application Support/Synesthesia/hosts.json`, or `$SYNESTHESIA_HOSTS`.
- MCP: the app serves its tools on `~/Library/Application Support/Synesthesia/mcp.sock` (or `$SYNESTHESIA_MCP_SOCKET`) from launch. `.build/Synesthesia.app/Contents/MacOS/synesthesia-mcp` bridges a client's stdin and stdout to it, and starts the app if it isn't running. `.mcp.json` offers it to Claude Code here; to try the tools without Claude Code, send JSON-RPC lines to that program.
- Another daemon: the app and `meep` both find the daemon at `$MEEP_HOME/daemon/meep.sock`, or `~/.meep/daemon/meep.sock`. A daemon for testing can run in a folder of its own with `MEEP_HOME=<folder> meep daemon <files>`; keep that path short, since a Unix socket's path can be at most 104 bytes.

## Rules

- **Commits:** commit only when the user asks.
- **Layers** (design, section 9): `Transport`, `MeepClient`, `LanguageClient`, `FlowKit`, `ContinuumKit`, `CodeEditing`, `Simulation`, `LayoutKit`, `Stage`, `MetalStage` and `Assistant` import neither SwiftUI, AppKit nor UIKit. `SynesthesiaUI` is SwiftUI shared by the Mac and iPad; platform views reach it through the environment (`CanvasSurfaceProvider`). Only `SynesthesiaMac` is the Mac's own.
- **The canvas draws a stage, not the model:** `PipelineStage` turns a pipeline into a `StageSnapshot` each frame, and `StageRenderer` draws that. Keep Metal out of `Stage`, and the model out of `MetalStage`.
- **The text is the truth:** while a pipeline's Meeplang is open, the stage draws the language server's graph of it (`PipelineStage.show(text:renamed:)`), and takes counts from the running pipeline by key. `MeeplangDocument` keeps the keys the daemon's with `meep/setBase`; the platform's text view only shows the text and reports edits.
- **Debugging is the person's to confirm:** probes (`Probe`) only observe; sending a message in always goes through the composer's Send, including messages Claude offers with `inject_message`.
- **Edits go through the document:** a gesture on the canvas is Meep2's own edit through `MeeplangDocument.apply` (`meep/applyEdits`), or text the canvas writes itself only where Meep2 has no edit (moves, in `BranchMove`, per Q2). Each is one step in the document's `undoManager`, which the text view shares. Proposals (`propose_edits`) change nothing until the person accepts them in the app.
- **Tools are written once,** in `Assistant`, for both MCP and the Claude sidebar (`ClaudeChat`, which sends each tool's `apiDefinition`). They reach the app through `Viewer`; a tool that changes more than the view must be confirmed in the app (design, section 8), and its `asks` says what the sidebar asks first.
- **The sidebar's transcript only grows:** `ClaudeChat.messages` is appended to, never edited (only an unanswered message at its end is joined or withdrawn), so the prompt cache and Claude's thinking stay valid (the API checks the prefix); the system prompt and tools never change within a conversation. The Claude API key is the person's: it's kept in their Keychain and entered by them in Settings; never read, print or log it.
- **Never re-implement Meep** (design, rule 2): text questions go to `meep lsp`, and what runs to the daemon. If Synesthesia needs something Meep2 doesn't give, add it to `meep2-prompts.md` for a Meep2 session rather than working it out here.
- **Hosts look alike:** everything above `MeepClient` talks to a host through `HostLink`, whether it's the local daemon, a remote one or a `SimulatedHost`. A remote one is reached through a `Tunnel` (Transport), and `SimulatedHost` keeps up with every `HostLink` feature, subscriptions included, so tests don't need a daemon.
- **Detail follows the camera** (design, section 4): the canvas is one `ContinuumStage`, which says what each pipeline is shown as (`MeepPipeline.shownAs`); `HostSession` asks each host, through one subscription, for that and no more, within the host's byte budget.
- **Threads:** the model (`Continuum`, `MeepHost`, `MeepPipeline`, `MeepModule`) is `@Observable` on the main actor; connections are actors and hand over what they hear.
- **Tests never need a daemon** except `LiveDaemonTests`. Use `SimulatedHost`, or the daemon's captured replies in `Tests/MeepClientTests/Fixtures`.
- **UI:** follow the user's notes in `~/.claude/ux-notes.md`: text aligned left, changes of scale eased, labels completed on hover.
