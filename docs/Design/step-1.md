# Step 1: the skeleton

Written 16 November 2026. The first step of the order of work in [architecture-round-1.md](architecture-round-1.md), section 11: the project and its packages, a connection to the local Meep daemon over its socket, its pipelines with live counts in plain SwiftUI tables, and the first pretend host. Built against Meep2 at 6d496dd, with its graph endpoint. Nothing is committed.

## What's built

- **`Transport`:** a `ByteStream` protocol, a Unix socket stream on Network.framework, and a WebSocket client written here. Network.framework's own WebSocket can't be pointed at a path on a Unix socket, and the daemon serves its API at `/ws` on one.
- **`MeepClient`:** the daemon's contracts in Swift, including the graph, roles and ports; a `DaemonConnection` that carries every request and stream over one WebSocket, matched by id; and `HostLink`, the protocol everything above uses for a host. It reads .NET's dates (up to seven fractional digits) itself.
- **`FlowKit`:** rates from cumulative counts, smoothed over two seconds, counting from zero again after a restart.
- **`ContinuumKit`:** `MeepAddress` (`meep://local/busy/m2`), the model (`Continuum`, `MeepHost`, `MeepPipeline`, `MeepModule`), and `HostSession`, which keeps a host up to date: it lists pipelines every 2 seconds, follows each live one's counts every second, fetches the graph when its version changes, and reconnects every 3 seconds when the host goes. Modules keep their objects across reloads by their graph keys.
- **`Simulation`:** `SimulatedHost`, with three pipelines whose counts rise and wobble like traffic, from 2 to 2,400 messages a second.
- **`SynesthesiaUI`:** hosts and pipelines in a sidebar; a host's details and pipelines; a pipeline's modules with their role's shape (circle, triangles, rectangle), rates and counts; a breadcrumb.
- **`SynesthesiaMac`:** the app. It follows This Mac's daemon, and a simulated host that **View › Show Simulated Host** turns off.

When a host can't be reached, it says why ("Nothing is listening on …"), its pipelines stay as last seen but greyed, without rates, and it reconnects by itself when the daemon comes back.

**Tests:** 33, all passing. Among them, WebSocket framing and the handshake against RFC 6455's example; the daemon's own replies, captured as fixtures; a session following a simulated host; and, with `MEEP_TEST_SOCKET` set, requests and streams against a real daemon. The app was also run against a test daemon: the tables, a daemon stopping, and it starting again.

## Decisions made while building

- **SwiftPM and a build script, not an Xcode project.** Section 9 planned `Synesthesia.xcodeproj` with packages beside it. Your other Mac apps (Edit The Future, KeybowNotes) build with `swift build` and `scripts/build-app.sh`, which works from the command line and in tests without an Xcode project to keep in step, so Synesthesia does the same. The iPad will need an Xcode project; it can be added then, using the same package.
- **One package with a target for each part,** rather than a package each. The boundaries are the same, with one `Package.swift` to keep.
- **The bundle identifier is `com.synesthesia.mac`,** in the style of `com.editthefuture.mac`. Change it before signing with a Developer ID if you'd like another.
- **Rates use the time updates arrive,** since the daemon doesn't send its clock yet (prompt 5 in `meep2-prompts.md`).

## Found in Meep2

- **A filter's `emitted` count leaves out the messages it passes on.** In the test pipeline, a Where received 2,123 messages and `emitted` said 424, which were its errors. The WriteLine after it received the other 1,699. So a module's counts can't give the rate along each wire out of a filter. Prompt 2 (a count for each link) is what the canvas needs. Its prompt should mention this case.
- **`Tap X @errors` doesn't count as handling X's errors.** A pipeline whose only error handler was `Tap Thirds @errors` with a WriteLine under it was stopped by the error policy ("errors nothing handled"). An `@errors` module indented under Thirds was enough. That may be intended, since a Tap only relays, but the watchdog example uses the Tap form.
- **Test processes left running.** Two `meep run` processes from Meep2's tests have been running since Monday: one `--detached-to` a temporary folder's `ticker.log`, the other `--watch` on a temporary `ticker.meep`. One has used about 2½ hours of CPU.

## Next

Step 2, the pipeline canvas, watching only. It needs:
- a layered layout written in Swift, since you'd rather not use JavaScriptCore and ELK (Q3);
- the Metal stage;
- prompt 2's counts for each link.
