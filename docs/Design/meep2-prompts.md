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
- **4,** in Meep2 0278da4, with 001842b, which pairs unchanged modules wherever they now are (Q195). Synesthesia's step 5 uses it. Both are on Meep2's `main`.
- **5,** in Meep2 0c83a49, on `main`. Synesthesia's step 7 uses it.
- **7,** in Meep2 a5de139, on `main`, with the answers to Q212–221 (report: `docs/Design/Chat/flows.md` there). Synesthesia's step 8 uses it. Sampled traces for tracers (Q219) wait for a prompt of their own, after step 8.

**Not needed yet:** 6. Step 7 didn't need `meep run` to join a daemon, so it waits until it's wanted.

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

Refreshed 17 November 2026 for Synesthesia's step 5, against Meep2 at 810c2fc (branch `lsp-graph`, not yet merged into `main`).

> Synesthesia, the Swift app in `~/Projects/Synesthesia` (design in `docs/Design/architecture-round-1.md` there, its latest step in `docs/Design/step-4.md`), shows a pipeline's Meeplang beside a live canvas of it. It uses `meep lsp` as reported in `docs/Design/Chat/lsp-graph.md`: `meep/graph` with `meep/graphChanged`, `meep/setBase` so the editor's module keys are the daemon's, semantic tokens and `meep/verbs`. Its next step makes the canvas edit the pipeline. Each gesture becomes Meep2's own edits, made by `SourceEditor`, so comments and layout survive. Dropping a verb onto a wire is `insert`, dropping one beside a tile is `add`, deleting is `remove` or `remove-branch`, the inspector does `set`, `unset`, `set-modifier` and `remove-modifier`, and renaming is `rename`. Synesthesia never edits Meeplang by its own rules (except for merges and moves, below), so it needs `meep lsp` to make the edits. Work on a new branch from `lsp-graph`, since this builds on its language server. Add:
>
> - **`meep/applyEdits`:** it takes an open document, the version the client has, and a list of edits, the same kinds `POST /pipelines/{name}/edits` takes. It runs them through `SourceEditor` on the server's copy of the text, and returns the smallest text edits (LSP `TextEdit`s against that version) that make the change.
>   - **What it doesn't do:** it doesn't write to disk, and it doesn't change the server's copy. The client applies the text edits as one undo step and sends `didChange` as usual, so the text's own undo stays the only history.
>   - **Stale versions:** refuse a version that isn't the server's latest.
>   - **All or nothing:** apply a list as a unit or not at all. If one edit fails, say which, and why, in the error.
>   - **Modules by key:** let edits name modules by the document's keys from `meep/graph` (`m3`), as well as by name or number. Keys are what the canvas has, and they're the only names that are always unique.
>   - **New modules' keys:** for each module an edit adds or inserts, say which key it will have, and make sure the graph after the client's `didChange` gives it that key. Then the canvas can select a new tile, and keep it selected, without guessing.
> - **Previews:** the same request with `preview: true` also returns the graph the text would have after the edits, keyed as above, again without changing anything. Synesthesia shows edits Claude proposes as ghost tiles and a diff until the person accepts them (design, section 8), and needs the graph to draw the ghosts.
> - **Whether the daemon watches a file:** say in `PipelineSummary` (and `PipelineDetail`) whether the daemon is watching a pipeline's file (`HostedPipeline.Watching`). Then a client that saves the file knows whether the change will run without asking for a reload. Synesthesia now waits two seconds after saving, and says the daemon isn't watching if no reload comes.
>
> Synesthesia will write the text for merges and moves itself (its design's Q2), then `meep lsp` checks it like any other change, so Meep2 doesn't need join or move edits for it.
>
> Test `meep/applyEdits` with each kind of edit, with:
> - modules named by key;
> - a template and an `#include` (where an edit to a module made by a template should be refused or go to the template; say which);
> - a stale version;
> - a list where a later edit fails;
> - comments and blank lines kept.
>
> Test a preview's graph against the graph after applying the same edits. If design questions come up, ask them in the numbered style of the design rounds, continuing from 193. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 5. One subscription, digests, host identity

Refreshed 17 November 2026 for Synesthesia's step 7, against Meep2's `main` at 001842b.

> Synesthesia, the Swift app in `~/Projects/Synesthesia` (design in `docs/Design/architecture-round-1.md` there, sections 2 to 4 and 10; its latest step in `docs/Design/step-6.md`), draws Meep pipelines live. Its next step shows many hosts at once, in one continuous zoom from a module up to a host's districts and the mesh of hosts, and reaches daemons on other machines by forwarding their Unix socket over SSH. It should ask each daemon only for what's on screen, at a rate that suits its size there, within a byte budget for each connection.
>
> Today it uses one `/ws` per daemon. It lists the pipelines every two seconds, and opens a stats stream for each live pipeline (`GET /pipelines/{name}/stats?every=…`): once a second, or five times a second while the pipeline is on the canvas. It fetches a graph when a `graph` event says it changed. That's a whole `PipelineDetail` per pipeline per tick, however little changed, and nothing smaller for a pipeline drawn as a dot. Add:
>
> - **One subscription for each connection,** over `/ws`, alongside the streams that are there now, which Synesthesia's earlier steps use and should keep working:
>   - **What it covers:** the pipelines' list and states; totals for a host and for each pipeline; each module's counts; and each link's counts.
>   - **Its own rate for each,** from a few times a second down to once in several seconds. Nothing is sent for what isn't asked for.
>   - **Changed in place:** pipelines and modules can be added, dropped or retuned without reconnecting, as the camera moves.
>   - **Only what changed:** after the first update, each update carries only the counts that changed since the last one sent, with a sequence number, so a client can tell it missed one.
>   - **Graph notices,** as the stats stream has them now.
>   - **JSON or CBOR,** chosen by the client. `System.Formats.Cbor` is part of .NET, so it adds no dependency.
>   - **Measured:** its cost on the daemon and on the wire, with many pipelines and modules at high rates, say 50 pipelines of 20 modules at 10 updates a second, against what the stats streams cost for the same.
> - **Digests,** in the subscription for whatever asks for them:
>   - **Handling time:** each module's, as a cumulative histogram in OpenTelemetry's exponential form, so clients can merge modules' histograms into pipeline and host totals at any zoom.
>   - **Bytes:** in and out, for the network inflections (Listen, Fetch, Send).
>   - **The host:** its CPU, memory and garbage collection, from .NET's runtime metrics.
> - **Host identity and time:**
>   - **A lasting ID** for each daemon, made once and kept in `~/.meep/daemon`.
>   - **Where it is:** the host's names, and the addresses its Listens are bound to.
>   - **Its clock** on every update, so a client can estimate the offset between hosts.
> - **The same identity in OpenTelemetry:** the daemon's ID as a resource attribute (`service.instance.id`), and the pipeline and module on every span and metric. Then a collector, or Synesthesia receiving OTLP pushes from hosts it can't reach (its design's Q5), can place everything.
>
> Synesthesia will reach other machines' daemons by forwarding their socket with `ssh -L`, so the daemon sees a connection from its own user through sshd. Say if anything in the peer-credential check or tokens would get in the way of that.
>
> If design questions come up, ask them in the numbered style of the design rounds, continuing from 202. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 6. `meep run` joining a daemon

> Pipelines started with `meep run` have no daemon, so tools that ask the daemon, such as Synesthesia (the Swift app in `~/Projects/Synesthesia`), can't see them. Add an option to `meep run`, off by default, that makes the run known to the local daemon when one is running, so it's listed with the daemon's own pipelines and can be watched, tapped and injected into like them. It shouldn't stop the run if the daemon goes away, or stop the daemon if the run ends. Think about what control means for a pipeline the daemon didn't start (stopping and reloading it, for one), and whether the run needs a token. If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 7. Flow evidence and the boundary

Refreshed 20 November 2026 for Synesthesia's step 8, against Meep2's `main` at 0c83a49.

> Synesthesia is the Swift app in `~/Projects/Synesthesia`. Its design is in `docs/Design/architecture-round-1.md` there (sections 3 and 4), and its latest step is in `docs/Design/step-7.md`. It now shows many daemons in one zoom, from a pipeline out to the mesh of hosts, using the subscription, digests and host identity from 0c83a49 (your report is `docs/Design/Chat/subscriptions.md`).
>
> Its next step draws two things:
>
> - **Flows** between pipelines, on one host or across hosts.
> - **The boundary:** the endpoints outside Meep that Listens, Fetches and Sends talk to. They sit round the edge of the mesh, each with its rate and failures.
>
> Flows come in two kinds:
>
> - **Declared:** a Fetch's or Send's address matches a Listen's on a known host. This is a guess, drawn dashed, and it works before anything runs.
> - **Observed:** messages that really crossed, drawn solid. These need evidence from Meep, which is what this prompt asks for.
>
> Add:
>
> - **Origins on what Meep sends to Meep:** Fetch and Send add W3C `traceparent`, and `baggage` with `meep.origin=<daemon ID>/<pipeline>/<module key>`. The daemon ID is the lasting one from 0c83a49, and the keys are the graph's, so a client can place an origin without matching names.
>   - **Only to Meep hosts,** so that origins don't leak to outside APIs. Work out how a daemon knows the other end runs Meep: a reply header from Listen with its daemon's ID, which Fetch and Send remember for that address; configuration; or both. Say what happens on the first request, before the other end is known.
>   - **Listen continues the trace** from `traceparent`, so that spans join up across hosts in a collector.
> - **Arrivals by origin:** each Listen counts the messages and bytes it receives, by origin.
>   - **Where:** in the subscription, as a new kind with its own rate, as `bytes` has.
>   - **Unmarked arrivals** count as from outside, grouped by the client's host: its name where it has one, otherwise its address.
>   - **A limit:** keep the number of origins a Listen tracks bounded, and say what happens past the bound.
> - **Destinations by endpoint, for the boundary:** Fetch and Send count messages, bytes and failures by where they actually connected (the remote host and port, grouped by host name).
>   - **Where:** in the subscription.
>   - **Meep at the other end:** where the other end is a Meep host, include its daemon ID, so that an observed flow names both ends by ID.
>   - **Bytes** stay counted for the module whose connection they cross (Q207).
> - **Declared destinations:** where a Fetch's or Send's address is fixed when the pipeline starts, give it with the module, as `listening` gives a Listen's. Then Synesthesia can match declared flows without evaluating Meeplang itself. Say what you give for an address worked out for each message.
> - **TCP, WebSocket and the other transports:** TCP has no headers, so say what's possible there, such as a first-frame handshake between Meep ends, or nothing. Say how WebSocket carries the origin.
> - **Measured:** the cost of the headers, and of the counters by origin and by endpoint, on a busy Fetch to Listen pair, against `main`.
>
> Synesthesia also wants to draw real messages following their path (sampled traces, design section 4, "Tracers"). Say whether the traces from `traceparent` could give a client, through the daemon, a sample of messages' hops through modules and across hosts, and what that would cost. Build it only if it's small.
>
> If design questions come up, ask them in the numbered style of the design rounds, continuing from 212. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.

## 8. The iPad: LSP over the daemon, mutual TLS

> Synesthesia, the Swift app in `~/Projects/Synesthesia`, will have an iPad version, which can't start processes such as `meep lsp` or `ssh`. Everything it needs has to come over the network from a daemon:
>
> - **The language server over the daemon's WebSocket,** so a client can open documents and make the same requests as with `meep lsp` (including the `meep/*` additions), for files on that host.
> - **Mutual TLS** on a TCP listener for the daemon, with client certificates mapped to the same capabilities as tokens (observe, inject, control), and a way to enrol a new device.
>
> If design questions come up, ask them in the numbered style of the design rounds. Write a report in `docs/Design/Chat/`. Don't commit; I'll review first.
