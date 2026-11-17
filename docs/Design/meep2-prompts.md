# Prompts for Meep2 sessions

What Synesthesia needs from Meep2, as prompts for Claude Code sessions in `~/Projects/Meep2`. Each prompt stands alone, since a session there won't have this conversation. Your answer to Q9 was to make these as each Synesthesia step needs them, so they're in that order, and each says which step needs it.

Written 15 November 2026, against Meep2 at "Add a developer guide to writing verbs and inflections" (505aa54). The first two are ready to use. The later ones will need refreshing when their step comes, since Synesthesia's needs will be sharper by then.

## How your answers changed the list

Compared with section 10 of [architecture-round-1.md](architecture-round-1.md):

- **Q2 (the canvas can write text):** Meep2 no longer needs join and move edits. Synesthesia writes the text for merges and moves itself, then `meep lsp` checks it like any other change. That needs exact source spans, which prompt 1 asks for.
- **Q11 (`meep run` joins a daemon only when asked):** a new ask, prompt 6.
- **Your theme notes (shapes by kind of verb):** a new ask. The graph says what role each verb plays, so the canvas can choose its shape without a list of verb names. It's in prompt 1.
- **Q5 (accept OTLP pushes):** OpenTelemetry from Meep2 has to say which host, pipeline and module it came from, so Synesthesia can place it. It's in prompt 5.

## Order

| # | Prompt | Synesthesia step that needs it |
|---|---|---|
| 1 | The graph over the API, with verb roles | 1, skeleton |
| 2 | Counts for each link | 2, the canvas |
| 3 | `meep lsp`: graph, semantic tokens, verb catalogue | 4, Meeplang beside the canvas |
| 4 | `meep lsp`: applying edits | 5, editing on the canvas |
| 5 | One subscription, digests, host identity | 7, host and mesh |
| 6 | `meep run` joining a daemon | 7, host and mesh |
| 7 | Flow evidence and the boundary | 8, the boundary |
| 8 | The iPad: LSP over the daemon, mutual TLS | 11, the iPad |

**Done:**

- **1,** in Meep2 6d496dd.
- **2,** in Meep2 ee030d7, which also counts each link's errors and each module's `passed`.
- **3,** in Meep2 2ef2d35, with 810c2fc, which pairs unchanged modules first when matching (Q186). Synesthesia's step 4 uses it.

Prompts 1 and 2 touch the same files (`Contracts.cs`, the daemon, the runtime's stats), so run them one after the other, not side by side.

---

## 1. The graph over the API, with verb roles

> Synesthesia is a Swift macOS app, in `~/Projects/Synesthesia`, that edits and visualises Meep2 pipelines. Its design is in `~/Projects/Synesthesia/docs/Design/architecture-round-1.md`; section 10 lists what it needs from Meep2. This session adds the first: the pipeline graph over the daemon's API.
>
> At the moment, `GET /pipelines/{name}` lists modules (`ModuleDetail`) without the links between them, though the runtime has them (`Node.Links`). Add `GET /pipelines/{name}/graph`, available over `/ws` like the rest of the API, returning:
>
> - **Modules:** number, name, verb, the inflection or inflections it can resolve to, its parameters as written, its modifiers, and its role (below).
> - **Links:** from, to, the input number at the receiving end, and the port (main or @errors).
> - **Message types** on each link, from what the loader already knows for its type checks.
> - **Source spans** for each module: file, start and end line and column, and the template or `#include` it came from. Synesthesia will write Meeplang itself for some canvas gestures, so the spans have to be exact.
> - **A version** that changes whenever the graph does.
>
> Two needs to design for, not just expose:
>
> - **Identity across reloads.** When a watched pipeline reloads, `ModuleMatcher` keeps matched modules' state, but their numbers can change. Synesthesia needs to keep a box's place and history across a reload, so the graph should carry a key that survives one, or say how old numbers map to new.
> - **Change notices.** Clients need to hear that a pipeline's graph changed (a reload, an edit, a restart) without polling. Use whichever existing stream fits best.
>
> **Verb roles.** Synesthesia draws each module's shape from what its verb does: a circle for a true source that makes messages itself (Interval, Read), an inverted triangle for a filter (Where), triangles pointing right and left for verbs that send messages out of the pipeline (Send) and receive them in from outside (Listen), and a rectangle for everything else. It shouldn't need a list of verb names to do that, since plugins add verbs. Give each verb a role, in the graph and wherever verbs are described: worked out from what Meep2 already knows (sources, `[EmitsInput]`, passthrough) where that's enough, and declared with an attribute where it isn't, so a plugin can declare its own. Propose the set of roles; the shapes above are the use, not the names.
>
> Put the contract in `Contracts.cs` alongside the others, keep the JSON style the API already has, document the endpoint where the others are documented, and update `docs/verbs.md` and `docs/writing-verbs.md` for roles. Test it with the examples, including a template, an `#include`, a `+` chain and an @errors branch. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/` as `websocket.md` and `classify.md` did. Don't commit; I'll review first.

## 2. Counts for each link

> Synesthesia, the Swift app in `~/Projects/Synesthesia` that visualises Meep2 pipelines, draws particles along each wire from the daemon's counts. The graph endpoint gives it the links (see the report from that session in `docs/Design/Chat/`), but counts are only kept for each module, so where streams merge, or a module fans out, or errors go down an @errors branch, every wire into or out of a module looks the same.
>
> One case shows why module counts aren't enough: a Where's `emitted` count leaves out the messages it passes on. In a test, a Where received 2,123 messages and `emitted` said 424, which were its errors, while the module after it received the other 1,699. So the wire after a filter can't be drawn from module counts.
>
> Add a count of messages carried for each link, keyed the same way as the graph's links, to the stats the daemon sends (`GET /pipelines/{name}/stats` and its stream). Counts should be cumulative like the others, so a client can take differences and a missed update loses nothing.
>
> This is on the hot path, so measure it with `benchmarks/` before and after, and keep the cost to a counter increment per delivery. Say in the report what it cost. Test merges, fan-out and @errors. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 3. `meep lsp`: graph, semantic tokens, verb catalogue

Refreshed 16 November 2026 for Synesthesia's step 4, against Meep2 at ee030d7.

> Synesthesia, the Swift app in `~/Projects/Synesthesia` (design in `docs/Design/architecture-round-1.md` there), draws a running pipeline live on a canvas from the daemon's graph (`GET /pipelines/{name}/graph`, from the session reported in `docs/Design/Chat/graph.md`) and its counts. Its next step shows the pipeline's Meeplang beside the canvas and keeps the two in step as you type: pointing at a line lights up its tile and the other way round, each module's rate shows in the gutter, and saving reloads the pipeline through `meep start --watch`. Synesthesia never parses Meeplang itself: it starts `meep lsp` as a child process over standard input and output, and asks it, as the VS Code extension does. Today `meep lsp` has diagnostics, completion and hover. Add three things:
>
> - **`meep/graph`:** for an open document, the same `PipelineGraph` the daemon returns, from the same contract in `Contracts.cs`, with the document's version.
>   - Module keys must stay stable while someone types, so match each new graph against the document's previous one with `ModuleMatcher`, as a reload does.
>   - When the text doesn't parse, return the last good graph with the broken range marked, rather than nothing.
>   - Let a client opt in to a notification when a document's graph changes, so the canvas follows typing without asking after every keystroke.
> - **Keys that agree with the daemon's.** Synesthesia draws tiles from the editor's graph but counts from the daemon's, so when a file that's running is open, a module must have the same key in both, and keep it as the text is edited and saved and the daemon reloads. Work out how. For example, `meep/graph` could take the running pipeline's graph as the base to match against, or keys could come from something both sides compute alike. Say in the report what a client has to do.
> - **Semantic tokens** (`textDocument/semanticTokens/full`, and `/delta` if it's cheap), so editors colour Meeplang from Meep's own parser. Update the VS Code extension in `editors/vscode` to use them.
> - **A verb catalogue,** `meep/verbs`: each verb and inflection, with:
>   - its role, as the graph gives it;
>   - its parameters, with types, defaults and descriptions;
>   - the message types it takes and emits;
>   - the file and line of its C# class, from PDBs and SourceLink.
>
>   Include verbs from loaded plugins. If the source locations turn out to be a large piece of work, they can wait. Synesthesia needs them only at its code level, much later; say in the report if you leave them.
>
> Test each with the examples, including a template, an `#include` and a file with a syntax error part way through. If design questions come up, ask them in the numbered style of the design rounds, continuing from 183. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 4. `meep lsp`: applying edits

> Synesthesia, the Swift app in `~/Projects/Synesthesia`, edits pipelines on a canvas. Each gesture becomes one of Meep2's own edits (the `EditItem` kinds that `POST /pipelines/{name}/edits` takes), so comments and layout survive. Add `meep/applyEdits` to `meep lsp`: it takes a document, the version the client has, and a list of edits; runs them through `SourceEditor` on the server's copy of the text; and returns the smallest text edits that make the change, without writing to disk. Refuse a stale version. One request should be one undo step for the client, so apply a list of edits as a unit or not at all.
>
> Synesthesia will write the text for merges and moves itself, so Meep2 doesn't need join or move edits for it.
>
> One small thing for the daemon as well: say in `PipelineSummary` whether it's watching a pipeline's file (`HostedPipeline.Watching`), so a client that saves the file knows whether the change will run without asking for a reload. Synesthesia now waits two seconds after saving, and says the daemon isn't watching if no reload comes.
>
> If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 5. One subscription, digests, host identity

> Synesthesia, the Swift app in `~/Projects/Synesthesia` (design in `docs/Design/architecture-round-1.md` there, sections 4 and 10), shows many hosts' pipelines at once, zooming from one module to the whole network. It asks each daemon only for what's on screen, at a rate that suits its size there, within a byte budget. The daemon needs to support that:
>
> - **One subscription for each connection** over `/ws`: many pipelines and modules, each at its own rate and with its own fields, changeable without reconnecting, sending only what changed. JSON or CBOR, chosen by the client; `System.Formats.Cbor` is part of .NET, so it adds no dependency.
> - **Digests:** each module's handling time as a cumulative histogram in OpenTelemetry's exponential form, so clients can merge modules' histograms into pipeline and host totals; bytes in and out for the network inflections (Listen, Fetch, Send); and the host's CPU, memory and garbage collection from .NET's runtime metrics.
> - **Host identity and time:** a lasting ID for each daemon, made once and kept in `~/.meep/daemon`; the host's names and the addresses its Listens are bound to; and the daemon's clock on every update, so clients can estimate the offset.
> - **The same identity in OpenTelemetry:** the daemon's ID as a resource attribute (`service.instance.id`), and the pipeline and module on every span and metric, so a collector, or Synesthesia receiving OTLP pushes from hosts it can't reach, can place everything.
>
> Measure the subscription's cost with many modules at high rates. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 6. `meep run` joining a daemon

> Pipelines started with `meep run` have no daemon, so tools that ask the daemon, such as Synesthesia (the Swift app in `~/Projects/Synesthesia`), can't see them. Add an option to `meep run`, off by default, that makes the run known to the local daemon when one is running, so it's listed with the daemon's own pipelines and can be watched, tapped and injected into like them. It shouldn't stop the run if the daemon goes away, or stop the daemon if the run ends. Think about what control means for a pipeline the daemon didn't start (stopping and reloading it, for one), and whether the run needs a token. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 7. Flow evidence and the boundary

> Synesthesia, the Swift app in `~/Projects/Synesthesia` (design in `docs/Design/architecture-round-1.md` there, section 3), draws flows between pipelines on different hosts, and the edge where Meep meets everything else. To draw flows that really happened, rather than guesses from matching addresses:
>
> - **Fetch and Send** add W3C `traceparent` and `baggage` (`meep.origin=<host>/<pipeline>/<module>`) to requests, but only to hosts known to run Meep, so origins don't leak to outside APIs. Work out how a daemon knows a host runs Meep: a reply header from Listen that Fetch remembers, configuration, or both.
> - **Listen** counts arrivals by origin, with anything unmarked counted as from outside, and continues the trace from `traceparent`.
> - **For the boundary:** Listen, Fetch and Send count messages, bytes and failures by remote endpoint (grouped by host name), so clients can see what talks to the outside, how much and how often it fails.
>
> TCP has no headers, so say what's possible there. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 8. The iPad: LSP over the daemon, mutual TLS

> Synesthesia, the Swift app in `~/Projects/Synesthesia`, will have an iPad version, which can't start processes such as `meep lsp` or `ssh`. Everything it needs has to come over the network from a daemon:
>
> - **The language server over the daemon's WebSocket,** so a client can open documents and make the same requests as with `meep lsp` (including the `meep/*` additions), for files on that host.
> - **Mutual TLS** on a TCP listener for the daemon, with client certificates mapped to the same capabilities as tokens (observe, inject, control), and a way to enrol a new device.
>
> If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.
