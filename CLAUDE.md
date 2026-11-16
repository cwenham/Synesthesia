# Synesthesia

A Swift app (Mac first, then iPad and iPhone) that edits and visualises Meep2 pipelines, from a module's C# up to the hosts of a whole network. Meep2 is in `~/Projects/Meep2`.

The design is in [docs/Design/architecture-round-1.md](docs/Design/architecture-round-1.md), with the user's answers to its questions. Step reports follow it in `docs/Design/step-N.md`. What Synesthesia needs from Meep2 is in [docs/Design/meep2-prompts.md](docs/Design/meep2-prompts.md).

## Commands

- Build: `swift build`
- Test: `swift test` (Swift Testing). Tests against a real daemon run only when `MEEP_TEST_SOCKET` names its socket, with a steadily ticking pipeline named by `MEEP_TEST_PIPELINE` (default `busy`).
- App: `scripts/build-app.sh` (or `scripts/build-app.sh debug`), then `open .build/Synesthesia.app`.
- Another daemon: the app and `meep` both find the daemon at `$MEEP_HOME/daemon/meep.sock`, or `~/.meep/daemon/meep.sock`. A daemon for testing can run in a folder of its own with `MEEP_HOME=<folder> meep daemon <files>`; keep that path short, since a Unix socket's path can be at most 104 bytes.

## Rules

- **Commits:** commit only when the user asks.
- **Layers** (design, section 9): `Transport`, `MeepClient`, `FlowKit`, `ContinuumKit` and `Simulation` import neither SwiftUI, AppKit nor UIKit. `SynesthesiaUI` is SwiftUI shared by the Mac and iPad. Only `SynesthesiaMac` is the Mac's own.
- **Never re-implement Meep** (design, rule 2): text questions go to `meep lsp`, and what runs to the daemon. If Synesthesia needs something Meep2 doesn't give, add it to `meep2-prompts.md` for a Meep2 session rather than working it out here.
- **Hosts look alike:** everything above `MeepClient` talks to a host through `HostLink`, whether it's the local daemon, a remote one or a `SimulatedHost`.
- **Threads:** the model (`Continuum`, `MeepHost`, `MeepPipeline`, `MeepModule`) is `@Observable` on the main actor; connections are actors and hand over what they hear.
- **Tests never need a daemon** except `LiveDaemonTests`. Use `SimulatedHost`, or the daemon's captured replies in `Tests/MeepClientTests/Fixtures`.
- **UI:** follow the user's notes in `~/.claude/ux-notes.md`: text aligned left, changes of scale eased, labels completed on hover.
