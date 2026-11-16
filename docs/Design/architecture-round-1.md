# Synesthesia architecture, round 1

Written 15 November 2026, after reading Meep2 as it stands at "Add a developer guide to writing verbs and inflections" (14 November): the design rounds, steps 7 to 9, the daemon's API, debug taps, telemetry and `meep lsp`. Questions are numbered from 1 and have answer lines, as in Meep2's design docs.

- Section 1: the approach, as seven rules.
- Section 2: the zoom ladder.
- Section 3: the Continuum.
- Section 4: showing what runs: data, budgets and particles.
- Section 5: editing both ways.
- Section 6: taps and injection.
- Section 7: layout and drawing.
- Section 8: Claude: the MCP server and the sidebar.
- Section 9: how the app is built.
- Section 10: what Meep2 needs to add.
- Section 11: order of work.
- Section 12: questions.

## 1. The approach

1. **The Meeplang text is the truth.** The graph is a live view of the parsed text, never a second copy. An edit made on the canvas becomes one of Meep2's own edits (`set`, `insert`, `remove` and so on), made by `SourceEditor`, so comments and layout survive and both views stay in step. Positions are kept beside the file, not in it.
2. **Synesthesia never re-implements Meep.** Parsing, choosing inflections, type checks and matching modules stay in C#. Synesthesia asks `meep lsp` about text and the daemon about what runs. With one parser, the canvas, VS Code and `meep run` always agree.
3. **Local and remote are the same thing.** This Mac is a host like any other, reached by a different transport. Every pipeline, module and boundary has one kind of address: `meep://local/ticker/Fetch`.
4. **Detail follows the camera.** Synesthesia only asks for detail about what's on screen, at a rate that suits its size there, within a budget for each host. Zoomed out, a host sends a few totals. Zoomed into one pipeline, its visible modules send counts several times a second. This is how it stays within the network, CPU and battery a real deployment has.
5. **Particles are honest.** Ambient particles are drawn from counts, not messages, and look it. Real messages (tapped, injected, or from a sampled trace) are drawn differently and can be clicked open. The view never suggests that one dot is one message unless it is.
6. **A core with no platform in it.** The model, telemetry, layout and scene are Swift packages that import neither AppKit nor UIKit. Each platform supplies a few protocols: the view that hosts the canvas, the text view, starting processes, tunnels. The iPad and iPhone versions then need new shells, not a rewrite.
7. **Each side advances the other.** Something awkward to do on the canvas is a finding about Meeplang, and the other way round. Section 10 has the first: the canvas needs two edits that Meeplang's editor doesn't have yet.

## 2. The zoom ladder

Six levels, from most detail to least:

| Level | You see | You can | Data from | Refresh |
|---|---|---|---|---|
| 1 Code | the C# of the inflections behind a verb, with each one's handling time in the gutter | read it and open it in Rider or VS Code; later, edit and rebuild | `meep lsp` for where the source is, the daemon for timings | when it changes |
| 2 Meeplang | the pipeline's file, with each module's rate, errors and a sparkline in the gutter | edit it, with diagnostics, completion and hover from `meep lsp` | `meep lsp`, the daemon | once a second |
| 3 Pipeline | modules as boxes, links as wires, particles along them, queues piling up at inputs | change structure and parameters, tap, inject | the daemon | up to 10 times a second, for what's visible |
| 4 Host | one daemon's pipelines as districts, with the host's CPU and memory headroom | start, stop, reload, compare | the daemon | once a second |
| 5 Mesh | hosts, and the flows between their pipelines | add hosts, follow a flow from one host to the next | each daemon | every 2 seconds |
| 6 Boundary | the edge of the Continuum: the APIs, clients and brokers outside it, and what crosses to each | see what talks to the outside, how much, and how often it fails | each daemon | every 5 seconds |

**Proposal: one continuous zoom for levels 3 to 6, like a map.** Zooming out, a pipeline's boxes shrink into a district on its host, hosts become points on the mesh, and so on. Each level is drawn from the same model, rolled up further. The level follows the scale, with some hysteresis so it doesn't flicker at a threshold. Every change of scale eases out rather than jumping, as in Edit The Future.

**Levels 1 and 2 are text, so they open beside the canvas rather than replacing it.** Zooming into a box past level 3 slides the Meeplang in as a split, scrolled to that module's line, with the canvas still live beside it. Selection, hover and highlights are shared, so pointing at a line lights up its box and the other way round. Zooming into a verb in the text, or ⌘-clicking it, opens the C# of the inflection it resolves to. A breadcrumb shows where you are: Continuum › local › ticker › Fetch › `Fetch.HTTP`. (Q1)

Everything has a focus, so moving between levels keeps your place. Zoom out from a module and its pipeline stays centred; zoom back in and you return to the module.

## 3. The Continuum

### The model

```
Continuum
├─ Workspaces    folders or Git repositories of .meep files you edit
├─ Hosts         one for each Meep daemon: "local", and any you add
│  └─ Pipelines  as the daemon lists them: running, restarting, finished, failed
│     └─ Modules, links, and ports (main and @errors)
├─ Flows         links between pipelines, on one host or across hosts
└─ Boundary      everything not built on Meep: APIs, browsers, brokers, files
```

- **A host is a daemon,** reached through a transport: the Unix socket in `~/.meep/daemon` on this Mac, an SSH tunnel to the same socket elsewhere (as step 7 planned), and mutual TLS once Meep2 has it. The API is the same either way, so the rest of the app can't tell local from remote. Pipelines started with `meep run` have no daemon, so they aren't in the Continuum. (Q11)
- **A pipeline in a workspace that runs nowhere is a draft.** It's drawn greyed out, on the host it would run on, which is this Mac unless you choose another. Running it starts it there, with `--watch` when the file is on that host, so editing it is live coding.
- **One file can run on several hosts.** The model keeps the file (the source) apart from what runs (its instances), so an edit can show which instances it will reach.
- **Addresses** are `meep://<host>/<pipeline>/<module>`, where the module is its name, its number as the running pipeline gives it (Q129), or a verb only one module has. The MCP server, the sidebar, links and the breadcrumb all use them.

### Flows between pipelines

Pipelines reach each other through network verbs: a Fetch or Send in one reaches a Listen in another. Synesthesia can find these in two ways, and shows both:

- **Declared:** a Fetch's or Send's address matches a Listen on a known host. This works before anything runs, but it's a guess, which a load balancer or a renamed host can break. Drawn dashed.
- **Observed:** messages that actually crossed. If Fetch and Send add W3C `baggage` saying where they came from (`meep.origin=<host>/<pipeline>/<module>`), each Listen can count arrivals by origin. That gives every flow and its rate for the price of a counter. `traceparent` on the same requests joins up the traces as well. Drawn solid. Meep2 sends neither yet (section 10). Origins shouldn't leak to APIs outside the Continuum, so they'd only go to hosts known to be Meep.

**The boundary** is every address a Listen, Fetch or Send uses that isn't a known Meep host. At level 6 the Continuum is drawn as a region, with the outside world as endpoints around its edge, grouped by domain, each with its rate and failures. They're the "outside connections" at the edge of a Cities: Skylines map.

## 4. Showing what runs

### Where the data comes from

- **The daemon's live stream** is Synesthesia's main source. It already sends each module's counts (received, handled, emitted, dropped, filtered, failed, restarts, expired, refused, queued) as often as the client asks, over the WebSocket that carries the whole API.
- **Debug taps** give real messages, at level 3 only, while a probe is open (section 6).
- **OpenTelemetry** stays what step 7 made it: the way into operations tools such as Aspire or Grafana. Synesthesia doesn't need a collector to work. It could also accept OTLP pushes from hosts it can't reach. (Q5)

### Digests

- **Counts are cumulative,** so Synesthesia takes differences to get rates, and a missed update loses nothing.
- **Handling time** comes as a histogram for each module, in OpenTelemetry's exponential form. These merge cleanly, so a pipeline's, a host's and the mesh's are made by adding modules' histograms together at any zoom, without asking the host again.
- **Load:** a module handles one message at a time, so its rate times its mean handling time is how busy it is, from 0 to 1. A module near 1 is the bottleneck, and its queue will grow, so it's drawn hot. Added up for a host and set against its CPU, this is the "clock cycles" view: how much headroom each host has left.
- **Bandwidth:** bytes in and out for the network inflections (Listen, Fetch, Send) give each flow and boundary endpoint a real bandwidth, and links between hosts a measured round-trip time.
- **History:** Synesthesia keeps what it receives in rings at a few resolutions (each second for ten minutes, each ten seconds for two hours), so you can scrub back to see what happened before you looked. Edits, reloads and restarts sit on that timeline as markers, with faint guides to where they took effect.

### Staying within budget

- **A subscription planner** works out what each host should send, and how often, once each camera move settles: visible modules at a rate suited to their size on screen, a small pipeline or host as one total, and nothing for what's off screen. Each host connection has a byte budget, lower over SSH and adjustable, and the planner lowers rates to stay under it.
- **Drawing runs slightly in the past,** about two updates behind, as network games do, so values glide between updates instead of stepping once a second. Each host's clock offset is estimated from request and reply times on its socket, so hosts with skewed clocks still line up.
- **Drawing has a budget too:** a limit on particles on screen, and labels placed by importance, leaving out any that would collide, as on Edit The Future's events strip.

### What the particles say

| Count | Drawn as |
|---|---|
| received, emitted | particles along the wires |
| queued | particles piling up at a module's input |
| filtered | particles that end inside the module, as they should at a Where |
| dropped | particles spilling off the box |
| expired | particles that grey and dissolve |
| failed, refused | a red flash on the module; errors travel @errors wires in red |
| load | the module's fill, from cool to hot |

- **Below a few messages a second, one particle is one message,** made as the count rises. Above that, density grows with the log of the rate, so ten times the traffic looks busier without saturating, and the exact rate is on hover. The particles change style at the switch, so you can tell which you're looking at. (Q6)
- **Particles are worked out on the GPU** from each wire's rate and a running phase, so a wire carrying a million messages a second costs the same to draw as one carrying one.
- **Tracers:** messages from a tap, an injection or a sampled trace are drawn as distinct particles that follow their real path, and open the message when clicked.

## 5. Editing both ways

### Text to graph

- The Meeplang editor sends each change to `meep lsp`, as VS Code does, and gets diagnostics back. A new request, `meep/graph`, returns the pipeline as a graph: modules with their verb, inflections, parameters, modifiers and names; links with input numbers and ports; the message types on each link; and where each part is in the text, including the template or include it came from.
- **Module keys stay stable as you type.** The server keeps the previous graph and matches modules with `ModuleMatcher` (by name, then structure, then position), the same matching a running pipeline uses when it changes. So a box keeps its place, and its live counts, while you edit its line.
- **Text that doesn't parse** leaves the last good graph on screen with the broken part marked, rather than the canvas falling apart.

### Graph to text

- Every gesture becomes one or more of Meep2's edits, sent as `meep/applyEdits`. The server makes them with `SourceEditor` and returns the changes to the text, the editor applies them, and the usual round trip follows. One gesture is one undo step, and undo is the text's undo, so there's only one history.
  - Drop a verb onto a wire: `insert`. Drop it beside a box: `add`. Delete: `remove` or `remove-branch`. Change a parameter in the inspector: `set`. Rename: `rename`.
- **Two gestures have no edit yet:** wiring a module that already has an input to a second one (a merge, which in text means turning chains into `+` chains or adding a Tap), and moving a branch under another module. Until Meep2 has edits for them, the canvas refuses those gestures and says why. (Q2)

### Where the text lives

- **A file in a workspace:** Synesthesia edits the file. If a daemon runs it with `--watch`, it reloads in about 10 ms (step 8's measurement) and keeps matched modules' state, so changes appear in the running pipeline as you make them.
- **A file on another host:** Synesthesia reads it with `GET /pipelines/{name}/source` and edits it with `POST /pipelines/{name}/edits`, which commits to `pending`, signed with your key. When the daemon warns that a reload would undo edits (Q120), Synesthesia shows the warning where you're working.

### Positions

Layout is automatic, but you can pin a box. Pins are kept in `.synesthesia/` beside the `.meep` files, keyed by the same module identity, so they travel with the repository and survive edits. (Q7)

## 6. Taps and injection

At level 3, debugging works like a patch bay.

- **A probe** goes on any wire or output. It opens a debug tap through the daemon and shows the messages in a panel docked to it: newest first, each as a tree, with its fam as a row of ancestors. Clicking an ancestor highlights the module that emitted it.
- **The filter is a Meeplang condition,** with completion from `meep lsp`, so it's the same language as `Where`. A sample rate sets the share shown.
- **What wasn't shown is counted:** "312 not shown: the view fell behind". The runtime's tap already counts what it drops.
- **Injecting has two ways in:** drag a captured message from a probe onto any module to send it again, or write one, as text or JSON, in a composer. Before it's sent, the path it will take is highlighted, and modules with effects outside the pipeline are named: "This will reach Send and Save." Injecting needs the daemon's inject capability, and the button says so when the connection lacks it.
- **Probes can be saved** with the workspace, so a debugging setup can be opened again.

## 7. Layout and drawing

### Layout

- **Layout runs in Swift, in the app.** In October I suggested C# and MSAGL. I now think that's wrong, for three reasons: layout needs the sizes of labels as drawn and what's collapsed at this zoom, which only the app knows; it has to answer within a frame while you drag; and the iPad can't run .NET. (Q3)
- **Level 3 uses a layered layout,** flowing left to right in message order. ELK's layered algorithm is the best available, and its JavaScript build, elkjs, should run in JavaScriptCore on both macOS and iOS, behind a Swift protocol, without writing a Sugiyama layout from scratch. I haven't tried it in JavaScriptCore yet; step 2 would prove it, or fall back to a Swift port. Earlier positions and pins go in as hints, so an edit moves as little as possible, and what moves eases into place.
- **Levels 4 to 6 use simpler Swift layouts:** districts packed by size for a host, a damped force layout for the mesh, and the boundary's endpoints around the edge.

### Drawing

- **SwiftUI for everything except the canvas and the text:** windows, inspectors, the sidebar, probe panels. Swift Charts for sparklines.
- **The canvas is Metal,** in an MTKView, because it has to draw a whole Continuum and tens of thousands of particles at 120 Hz, and Metal is the same on macOS and iPadOS. It draws shapes, wires and particles in instanced batches, and text from a glyph atlas made with Core Text, stored as distance fields so labels stay sharp at every zoom. (Q4)
- **The canvas draws a stage, not the model.** The stage is independent of the renderer: boxes, wires, labels, particle systems, levels of detail, hit-testing, and an accessibility tree for VoiceOver. The city-builder view from October would be a second renderer of the same stage, in RealityKit, without touching layout or data.
- **The text views are TextKit 2** (NSTextView now, UITextView on the iPad) behind one protocol, coloured from semantic tokens that `meep lsp` would provide, so colouring uses Meep's own parser like everything else.

### UX lessons carried over

From your notes: text aligned left throughout; changes of scale eased, never jumped; ⌘-click and ⇧-click select as in Finder, and ⌃-click stays the right-click; labels placed by importance, with hidden ones shown on hover; everything you added (pins, probes, notes) editable where it's drawn, with delete close by; side panes resizable from their edge; truncated labels completed on hover; number fields sized to their numbers.

## 8. Claude

### One set of tools, two ways in

The tools are written once, in Swift, and offered two ways:

- **An MCP server,** so Claude Code and Claude Desktop can work with the Continuum. The app serves it on a local socket, and a small `synesthesia-mcp` program in the app bundle bridges standard input and output for clients that start servers that way. The official MCP Swift SDK covers the protocol.
- **The sidebar,** which talks to the Claude API directly over HTTPS, using `claude-opus-5-5` and an API key kept in the Keychain. There's no official Anthropic SDK for Swift, so it's a small client of the Messages API with its own tool loop. Doing it in the app means it works on the iPad too, where nothing else can be started. (Q8)

### The tools

- **Looking:** list the Continuum; a pipeline's graph, text and counts over a period; describe what's on screen as structure (cheaper and more exact than a screenshot), with an image when that helps; describe verbs.
- **Showing:** move the camera to an address and select it, so Claude can point at what it means.
- **Debugging:** sample a tap, limited to so many messages or seconds; inject.
- **Changing:** propose edits.

### Safety

- The tools follow the daemon's capabilities: observe, inject and control. Anything beyond observe is confirmed in the app, unless you allow it for the session.
- **Proposed edits appear as a preview,** ghost boxes on the canvas and a diff in the text, until you accept them.
- Tap results are message contents, which can be sensitive, and the sidebar sends what tools return to the API. The first tap in a conversation says so.

Each question in the sidebar comes with your focus and selection as addresses, so "why is this queue growing?" needs no explaining.

## 9. How the app is built

### Platform

- Built with Xcode 26.3 and Swift 6.2, which this Mac has, in the Swift 6 language mode with strict concurrency, for macOS 15. Anything new in macOS 26 would need availability checks and couldn't be tried on this Mac, so the design uses none of it.
- **A Developer ID app outside the sandbox,** since it starts `meep lsp` and `ssh` and opens the socket in `~/.meep`. The Mac App Store would rule out all three. The iPad is sandboxed anyway, which is one more reason everything it needs has to come over the network. (Q10)

### Packages

```
Synesthesia/
├─ Synesthesia.xcodeproj   app targets only
├─ Apps/
│  ├─ macOS/               AppKit seams: windows, menus, hosting MTKView and NSTextView,
│  │                       starting meep lsp and ssh, the MCP bridge
│  └─ iOS/                 later
└─ Packages/
   ├─ ContinuumKit         the model and addresses; no UI
   ├─ MeepClient           the daemon's API: contracts, the shared WebSocket, JSON and CBOR
   ├─ Transport            Network.framework: Unix sockets, TCP with TLS; tunnels behind a protocol
   ├─ LanguageClient       an LSP client with the meep/* additions
   ├─ FlowKit              rates, digests, history, roll-ups, the playout clock, the subscription planner
   ├─ LayoutKit            the layout protocol; ELK in JavaScriptCore; packing, force and edge layouts; pins
   ├─ Stage                the renderer-independent scene, levels of detail, hit-testing, accessibility
   ├─ MetalStage           the Metal renderer, shared by macOS and iPadOS
   ├─ CodeEditing          the TextKit 2 editor's core: semantic colouring, gutter, inlay hints
   ├─ Assistant            the tool registry, MCP server, and Claude API client and loop
   ├─ SynesthesiaUI        shared SwiftUI: inspectors, probes, composer, sidebar, palette
   └─ Simulation           pretend hosts for tests and load
```

- **Platform seams** are protocols the app targets implement: `CanvasSurface` (hosts the Metal view and turns clicks, scrolls, pinches and Pencil into one kind of event), `CodeTextSurface`, `ProcessLauncher` (Mac only), `TunnelProvider` (ssh on the Mac, mutual TLS later everywhere), `SecretStore` and `WorkspaceAccess` (bookmarks to folders).
- **Threads:** an actor for each host connection; FlowKit works off the main thread; the renderer takes a snapshot of the stage each frame; UI state is `@Observable` on the main actor.
- **Simulation matters more than it looks.** It makes hosts that send believable counts for thousands of modules, with whatever latency, loss and clock skew you choose, so levels 4 to 6 and the budgets can be built and measured without fifty real machines.
- **Storage:** hosts and window state in Application Support; pins and probes in the workspace's `.synesthesia/`; secrets in the Keychain. Nothing is relational, so there's no need for SwiftData.

## 10. What Meep2 needs to add

In the order Synesthesia would need them:

1. **The graph over the API:** `GET /pipelines/{name}/graph`, with links (from, to, input number, main or @errors), resolved inflections, the message types on each link, and source spans. The runtime has the links (`Node.Links`), but the API's `PipelineDetail` lists modules without them.
2. **Counts for each input,** so wires where streams merge show their own rates, and @errors wires theirs.
3. **Digests in the stream:** each module's handling-time histogram in OpenTelemetry's exponential form; bytes in and out for network inflections; the host's CPU, memory and garbage collection from .NET's runtime metrics.
4. **One subscription for each connection:** many pipelines and modules, each at its own rate, changeable without reconnecting, sending only what changed, as JSON or CBOR. CBOR is the binary option you wanted, and `System.Formats.Cbor` is part of .NET, so it adds no dependency.
5. **Host identity and time:** a lasting ID for each daemon, the host's names and its Listen addresses, and the daemon's clock on every update.
6. **Flow evidence:** `traceparent` and `baggage` on Fetch and Send, to Meep hosts only, and Listen counting arrivals by origin.
7. **In `meep lsp`:** `meep/graph` with stable module keys, `meep/applyEdits`, semantic tokens, and a catalogue of verbs, inflections and message types saying where each C# class is written (from PDBs and SourceLink).
8. **Two new edits:** join (give a module another input) and move (put a branch under another module).
9. **For the iPad:** the language server over the daemon's WebSocket, and mutual TLS.

(Q9)

## 11. Order of work

Each step ends with something that runs, with tests.

1. **Skeleton:** the project and packages; connect to a local daemon over its socket; list pipelines with live counts in a plain SwiftUI table; Simulation's first pretend host. Meep2: the graph (1).
2. **The pipeline canvas, watching only:** layout, the Metal stage, wires, and particles, queues and errors from live counts. Meep2: counts for each input (2).
3. **The MCP server, early,** with the looking and showing tools. It lets Claude Code sessions check what the app shows while the rest is built, without screenshots.
4. **Meeplang beside the canvas:** `meep lsp` with `meep/graph`, shared selection, counts in the gutter, live coding with `--watch`. Meep2: the LSP additions (7).
5. **Editing on the canvas:** gestures as edits, undo, previews. Meep2: `meep/applyEdits`, then join and move (7, 8).
6. **Probes and injection.**
7. **Host and mesh:** several daemons, SSH tunnels, roll-ups, budgets, the continuous zoom. Meep2: subscriptions, host identity, digests (3 to 5).
8. **The boundary, and flows between hosts.** Meep2: flow evidence (6).
9. **The Claude sidebar.**
10. **The code level:** C# source from the verb catalogue, opening in your editor; editing and rebuilding later.
11. **The iPad.** Meep2: (9).

## 12. Questions

★ marks the ones that shape the design most.

1. ★ Navigation (section 2): one continuous zoom for levels 3 to 6, like a map, with Meeplang and C# opening as a split beside the canvas when you zoom into a box. Or separate levels that you switch between?

   **Answer:** Continuous zoom.

2. ★ The text is the truth (section 5): the canvas only ever asks `SourceEditor` for edits, and refuses gestures that have no edit yet (merge and move) until Meep2 has them. Or should the canvas write text itself for those, such as adding a Tap?

   **Answer:** Canvas can write text.

3. ★ Layout in Swift (section 7), reversing October's suggestion of C# and MSAGL, starting with ELK's layered layout in JavaScriptCore?

   **Answer:** Layout in Swift. I'd like to avoid using JavaScriptCore and ELK.

4. Metal for the canvas from the start, or a quicker SwiftUI Canvas prototype first, replaced later? I'd go straight to Metal: the stage keeps it contained, and particles at scale need it.

   **Answer:** Metal from the start.

5. ★ Data (section 4): the daemon's stream as Synesthesia's source, with OpenTelemetry for operations tools. Should Synesthesia also accept OTLP pushes, for hosts it can't reach directly?

   **Answer:** Yes.

6. Particles (section 4): one for each message below a few a second, a log-scaled stream above that, and tracers for real messages. Is that what you pictured?

   **Answer:** Yes.

7. Should pins and saved probes live in `.synesthesia/` in the workspace, committed with the `.meep` files, or privately in the app?

   **Answer:** In .synesthesia.

8. Should the sidebar talk to the Claude API directly with your API key, which also works on the iPad, alongside the MCP server for Claude Code and Claude Desktop? Or MCP only?

   **Answer:** First option.

9. ★ Meep2's additions (section 10): made in Meep2 sessions as each Synesthesia step needs them, or as one Meep2 step up front?

   **Answer:** In Meep2 sessions as needed.

10. A Developer ID app outside the sandbox, rather than the Mac App Store, for now?

    **Answer:** Yes.

11. Pipelines started with `meep run` and no daemon don't appear in the Continuum. Is that fine, or should `meep run` make itself known to a local daemon when one is running?

    **Answer:** No, only if the user choses to with a command line option.


## Notes on themes and aesthetics

Rounded corners with tile depth--like Mahjong or Scrabble tiles--and hatched shadows for blocks and module shapes. Bright wireframe colours on an off-black (very dark gray) background.

Module shapes:

   * Inverted triangles for filtering verbs like "Where".
   * Circles for true sources (fountainheads).
   * Left/Right pointing triangles for "Send" and similar verbs.
   * Rectangles a default for other verb types.