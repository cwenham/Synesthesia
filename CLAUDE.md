# Synesthesia

A Swift app (Mac first, then iPad and iPhone) that edits and visualises Meep2 pipelines, from a module's C# up to the hosts of a whole network. Meep2 is in `~/Projects/Meep2`.

The design is in [docs/Design/architecture-round-1.md](docs/Design/architecture-round-1.md), with the user's answers to its questions. Step reports follow it in `docs/Design/step-N.md`. What Synesthesia needs from Meep2 is in [docs/Design/meep2-prompts.md](docs/Design/meep2-prompts.md).

## Commands

- Build: `swift build`
- Test: `swift test` (Swift Testing). Tests against a real daemon run only when `MEEP_TEST_SOCKET` names its socket, with a steadily ticking pipeline named by `MEEP_TEST_PIPELINE` (default `busy`). Tests against a real `meep lsp` run only when `MEEP_EXECUTABLE` names a `meep` built from Meep2 at 2ef2d35 or later.
- Pictures: `SYNESTHESIA_SNAPSHOTS=<folder> swift test --filter 'MetalStageTests|SynesthesiaUITests'` saves what the renderer and the hover cards drew there as PNGs, to look at without the app.
- App: `scripts/build-app.sh` (or `scripts/build-app.sh debug`), then `open .build/Synesthesia.app`. It starts `meep lsp` from `$MEEP_EXECUTABLE`, or the `meep` on the `PATH` or the login shell's `PATH`.
- MCP: the app serves its tools on `~/Library/Application Support/Synesthesia/mcp.sock` (or `$SYNESTHESIA_MCP_SOCKET`) from launch. `.build/Synesthesia.app/Contents/MacOS/synesthesia-mcp` bridges a client's stdin and stdout to it, and starts the app if it isn't running. `.mcp.json` offers it to Claude Code here; to try the tools without Claude Code, send JSON-RPC lines to that program.
- Another daemon: the app and `meep` both find the daemon at `$MEEP_HOME/daemon/meep.sock`, or `~/.meep/daemon/meep.sock`. A daemon for testing can run in a folder of its own with `MEEP_HOME=<folder> meep daemon <files>`; keep that path short, since a Unix socket's path can be at most 104 bytes.

## Rules

- **Commits:** commit only when the user asks.
- **Layers** (design, section 9): `Transport`, `MeepClient`, `LanguageClient`, `FlowKit`, `ContinuumKit`, `CodeEditing`, `Simulation`, `LayoutKit`, `Stage`, `MetalStage` and `Assistant` import neither SwiftUI, AppKit nor UIKit. `SynesthesiaUI` is SwiftUI shared by the Mac and iPad; platform views reach it through the environment (`CanvasSurfaceProvider`). Only `SynesthesiaMac` is the Mac's own.
- **The canvas draws a stage, not the model:** `PipelineStage` turns a pipeline into a `StageSnapshot` each frame, and `StageRenderer` draws that. Keep Metal out of `Stage`, and the model out of `MetalStage`.
- **The text is the truth:** while a pipeline's Meeplang is open, the stage draws the language server's graph of it (`PipelineStage.show(text:renamed:)`), and takes counts from the running pipeline by key. `MeeplangDocument` keeps the keys the daemon's with `meep/setBase`; the platform's text view only shows the text and reports edits.
- **Tools are written once,** in `Assistant`, for both MCP and the later Claude sidebar. They reach the app through `Viewer`; a tool that changes more than the view must be confirmed in the app (design, section 8).
- **Never re-implement Meep** (design, rule 2): text questions go to `meep lsp`, and what runs to the daemon. If Synesthesia needs something Meep2 doesn't give, add it to `meep2-prompts.md` for a Meep2 session rather than working it out here.
- **Hosts look alike:** everything above `MeepClient` talks to a host through `HostLink`, whether it's the local daemon, a remote one or a `SimulatedHost`.
- **Threads:** the model (`Continuum`, `MeepHost`, `MeepPipeline`, `MeepModule`) is `@Observable` on the main actor; connections are actors and hand over what they hear.
- **Tests never need a daemon** except `LiveDaemonTests`. Use `SimulatedHost`, or the daemon's captured replies in `Tests/MeepClientTests/Fixtures`.
- **UI:** follow the user's notes in `~/.claude/ux-notes.md`: text aligned left, changes of scale eased, labels completed on hover.
