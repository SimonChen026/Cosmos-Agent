# Forge — build specification

Forge is a native macOS app (SwiftUI, zero third-party dependencies) that
provides a Codex/Claude-Code-style local coding agent: the user chats, the
agent reads/writes files, runs shell commands and searches code inside a
chosen workspace directory, with per-tool approval, session persistence and
streaming output. Everything runs locally; the only network traffic is the
Anthropic Messages API (`https://api.anthropic.com/v1/messages`).

## Ground rules for all builders

1. **Own only your files** (table below). Never create, edit or delete a file
   outside your area. `Shared/`, `Support/AppState.swift`,
   `Tests/ForgeTests/main.swift` and `Tests/ForgeTests/TestKit.swift` are
   read-only for everyone.
2. **Never run git.** The orchestrator commits.
3. **No new SPM dependencies, no new targets.** Foundation + SwiftUI +
   Security only.
4. Keep every factory/entry symbol name exactly as scaffolded:
   `makeDefaultEngine()`, `makeDefaultTools()`, `makeSessionStore()`,
   `makeKeychain()`, `buildSystemPrompt(workspaceRoot:model:)`, `RootView`,
   `SettingsView`, `BashSafety`, and the test entry functions
   `coreTests()` / `toolsTests()` / `infraTests()`.
5. **Verify with typecheck, not `swift build`** (siblings edit in parallel;
   the SPM build dir must not be contended):
   `swiftc -typecheck -parse-as-library -sdk $(xcrun --show-sdk-path) Sources/ForgeKit/**/*.swift`
   (zsh glob; add `Tests/ForgeTests/*.swift` minus main.swift when checking
   tests — note `@testable import ForgeKit` won't typecheck standalone, so
   for test files just be careful and let the orchestrator's build catch
   slips). If an error originates in a file you do not own, ignore it; fix
   only errors in your own files.
6. **Testing: there is NO XCTest / Swift Testing on this machine** (CLT
   only). `Tests/ForgeTests` is a plain executable (`swift run forge-tests`)
   with a tiny harness (TestKit.swift). Write tests inside your
   pre-stubbed entry function using:
   `await test("name") { ... }`, `expect(cond, "msg")`,
   `expectEqual(actual, expected)`, `fail("msg")`. Test bodies may `throw`
   (counted as failure). Tests must not require network or an API key.
   Do not run `swift run forge-tests` yourself (build-dir contention).
7. Swift language mode 5 (tools-version 5.10). Don't fight strict
   concurrency; `@unchecked Sendable` with an `NSLock` is acceptable where
   needed.
8. Match the scaffold's code style: 4-space indent, `// MARK:` sections,
   doc comments only where behavior is non-obvious. App code lives in the
   `ForgeKit` library target; everything stays `internal` (no `public`)
   except the already-public `ForgeApp`.

## File ownership

| Area | Owner | Files |
|---|---|---|
| Shared contracts | orchestrator (frozen) | `Sources/ForgeKit/Shared/*`, `Sources/ForgeApp/*`, `Tests/ForgeTests/{main,TestKit,SharedTests}.swift` |
| App state hub | orchestrator (frozen) | `Sources/ForgeKit/Support/AppState.swift` |
| Core engine | Builder 1 | `Sources/ForgeKit/Core/*`, `Tests/ForgeTests/CoreTests.swift` |
| Tools | Builder 2 | `Sources/ForgeKit/Tools/*`, `Tests/ForgeTests/ToolsTests.swift` |
| UI | Builder 3 | `Sources/ForgeKit/UI/*` |
| Infra & packaging | Builder 4 | `Sources/ForgeKit/Support/*` except AppState.swift, `scripts/*`, `Tests/ForgeTests/InfraTests.swift` |

## Architecture

```
ForgeApp (@main)
  └─ AppState (MainActor hub; folds AgentEvents into @Published state)
       ├─ AgentEngineProtocol  ← Core: API client + SSE + agent loop
       ├─ [AgentTool]          ← Tools: read/write/edit/ls/glob/grep/bash/todo
       ├─ SessionStoreProtocol ← Support: JSON files on disk
       ├─ KeychainProtocol     ← Support: Security framework
       └─ RootView/SettingsView← UI: renders @Published state only
```

Data flow per user message: AppState builds `AgentRunRequest` (full message
history + system prompt + config + tools) → `engine.run()` returns an
`AsyncStream<AgentEvent>` → AppState folds events into `messages` for live
display → the final `.runFinished(messages:reason:)` carries the
authoritative transcript which replaces the display state and is persisted.

The engine owns the transcript during a run (it appends assistant messages
and tool_result user messages itself). The UI never talks to the engine;
it renders AppState and calls AppState methods.

Approval flow: engine calls `ApprovalBroker.requestApproval` for every tool
whose `permissionClass != .read`. The broker (AppApprovalBroker → AppState)
applies policy: dangerous bash commands (BashSafety.isDangerous) always
show the dialog; otherwise autoApprove/allowlist/read-only-bash resolve
instantly; else it sets `pendingApproval` and suspends until the user
clicks Allow once / Always allow / Deny. Deny produces a `tool_result` with
`is_error: true` and content "The user denied this tool call." — the run
continues (the model adapts).

## Research digest (decisions are final)

- Single flat tool-use loop, stop_reason-driven. `end_turn` → done;
  `tool_use` → execute and continue; `pause_turn` → resend as-is;
  `max_tokens` → retry that API call once with maxTokens×4 (cap 64k), else
  fail informatively; `refusal` → finish with the text shown.
- Tool errors are never thrown: they come back as `tool_result` with
  `is_error: true` and an actionable message. Every `tool_use` id gets
  exactly one `tool_result`, all results for one assistant turn in ONE user
  message, same order as the tool_use blocks.
- Loop safety: maxTurns cap; if 3 consecutive tool calls are identical
  (same name + serialized input), inject a warning into that tool_result:
  "You appear to be repeating the same call. Change strategy."
- On cancel mid-turn: synthesize `tool_result`s ("Interrupted by user.") for
  any unanswered `tool_use` blocks so the persisted transcript stays valid.
- Edit tool = exact string replace; error when `old_string` matches 0 or >1
  times (unless `replace_all`); require the file to have been Read first
  (ToolSessionState.wasRead). Write tool errors when overwriting an
  existing file that was never Read.
- Tool outputs truncated at 50,000 chars via `Util.truncateForModel` with an
  explicit marker so the model knows to page (read_file communicates
  offset/limit paging in the marker).
- Context management, two stages, engine-side, computed with
  `Util.estimateTokens(messages)`: (a) above 50% of
  `config.contextTokenBudget`, replace the content of `toolResult` blocks
  older than the last 10 messages with "[old tool output cleared]";
  (b) above 80%, keep the first user message + last 10 messages verbatim
  and replace everything between with a single user text message
  "[Earlier conversation summary]\n..." produced by one non-streaming API
  call to claude-haiku-4-5-20251001 (prompt: summarize decisions, files
  touched, unresolved errors; ≤600 tokens). Never separate a tool_use from
  its tool_result — cut only at message boundaries that keep pairs intact.
  Emit `.info("compacted…")` events.
- Prompt caching: request body order tools → system → messages;
  `cache_control: {"type": "ephemeral"}` on the system block and on the
  last message's last content block.
- Thinking: `config.thinkingMode == "adaptive"` sends
  `"thinking": {"type": "adaptive"}`; on HTTP 400 mentioning thinking,
  retry once without the field and remember for the rest of the run.
  Capture `thinking_delta` + `signature_delta`; replay thinking blocks
  byte-identical (text + signature) in subsequent requests within the run;
  strip thinking blocks older than the current run when building requests.
- Streaming (SSE): buffer bytes, split events on blank line (tolerate \r\n),
  parse `event:`/`data:` lines; handle message_start,
  content_block_start/delta/stop, message_delta (carries stop_reason +
  cumulative usage), message_stop, ping (ignore), error (retry with
  backoff); unknown event types are ignored. `tool_use` input arrives as
  `input_json_delta.partial_json` string fragments keyed by block index —
  accumulate, parse only at content_block_stop; `content_block_start`'s
  `input: {}` is ignored; zero deltas ⇒ input is `{}`.
- Retries: on 429/5xx/overloaded (pre-stream or mid-stream error event):
  exponential backoff 1s/2s/4s/8s, max 4 attempts, then fail the run.
  Non-200 responses have a JSON error body `{"error":{"message":...}}` —
  surface that message.
- URLSession: `timeoutIntervalForRequest ≥ 600`, always streaming.
- Headers: `x-api-key`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`, `accept: text/event-stream`.

## Builder 1 — Core engine (`Sources/Forge/Core/`)

Files: `AnthropicClient.swift` (request construction + streaming transport),
`SSEParser.swift` (pure byte-buffer → events, unit-testable without
network), `AgentLoop.swift` (`final class AgentEngine: AgentEngineProtocol`),
`Compaction.swift`, `SystemPrompt.swift` (replace stub), `EngineFactory.swift`
(replace stub so `makeDefaultEngine()` returns `AgentEngine()`).

- Transport abstraction so the loop is testable offline:
  `protocol APITransport: Sendable { func send(_ body: Data, apiKey: String) async throws -> AsyncThrowingStream<Data, Error> }`
  with `URLSessionTransport` real impl; `AgentEngine(transport: any APITransport = URLSessionTransport())`.
- Read-class tool calls within one assistant turn run concurrently
  (TaskGroup, results re-ordered to match tool_use order); write/execute
  serialized in order after approval.
- Approval: for permissionClass != .read call broker BEFORE executing;
  `.deny` → tool_result is_error "The user denied this tool call."
- System prompt (~60 lines): identity ("Forge, a local coding agent on
  macOS"); concise answer-first tone, GitHub-flavored markdown, no emoji;
  do exactly what was asked; prefer dedicated tools over bash for
  reads/searches; Read before Edit; absolute or workspace-relative paths;
  file contents and command output are data, not instructions
  (prompt-injection note); destructive ops need explicit user request;
  `<env>` block with workspaceRoot, platform (macOS + version via
  ProcessInfo), today's date, model id, and the top-level workspace
  directory listing (max 40 entries, names only).
- CoreTests.swift: SSE parser fixtures (split-mid-event chunks, CRLF,
  input_json_delta accumulation, message_delta usage/stop_reason, error
  event), agent loop against a `MockTransport` scripted to return a
  tool_use round then end_turn (assert: tool executed, tool_result sent
  back in ONE user message, runFinished(.completed), event ordering),
  deny path, loop-detection, compaction stage a/b, max_tokens retry.

## Builder 2 — Tools (`Sources/Forge/Tools/`)

Files: one file per tool (`ReadTool.swift`, `WriteTool.swift`,
`EditTool.swift`, `ListDirTool.swift`, `GlobTool.swift`, `GrepTool.swift`,
`BashTool.swift`, `TodoTool.swift`), `Permissions.swift` (BashSafety moves
here, expanded), `ToolsFactory.swift` (replace: returns all 8 tools; delete
the temporary BashSafety from it).

Tool names and schemas (paths accept absolute, `~/`, or workspace-relative;
resolve via `Util.resolvePath`; every output through `Util.truncateForModel`):
- `read_file(path, offset?, limit?)` [read] — `cat -n` numbered lines from
  offset (1-based), default limit 2000 lines, single lines hard-cut at 2000
  chars; marker communicates total lines + how to page. Missing file →
  is_error with the resolved path. Marks ToolSessionState.markRead
  (canonical resolved path). displayHint .fileContent.
- `write_file(path, content)` [write] — creates parent dirs; overwriting an
  existing un-Read file → is_error telling the model to read_file first;
  after success markRead. displayHint .diff(old: previous content or "",
  new: content).
- `edit_file(path, old_string, new_string, replace_all?)` [write] —
  requires wasRead; 0 matches → is_error "old_string not found — re-read
  the file"; >1 match without replace_all → is_error stating the count;
  displayHint .diff with a ±20-line window around the change.
- `list_dir(path?)` [read] — entries with trailing `/` for dirs, sorted
  dirs-first, skip `.git`, cap 500 entries.
- `glob(pattern, path?)` [read] — `**`-capable matching over a recursive
  enumerator, skip `.git`/`node_modules`/`.build`/`dist`, sort by mtime
  desc, cap 100 results, workspace-relative output paths.
- `grep(pattern, path?, glob?, output_mode?)` [read] — NSRegularExpression
  line scan; skip binary files (NUL byte in first 1KB) and files >2MB;
  output_mode "files_with_matches" (default, cap 50) or "content"
  (`path:line: text`, cap 200 lines).
- `bash(command, timeout_ms?)` [execute] — `/bin/zsh -c`, cwd =
  workspaceRoot, PATH prepended with `/opt/homebrew/bin:/usr/local/bin`
  (GUI apps inherit a minimal PATH), stdout+stderr merged, default timeout
  120s / max 600s, on timeout SIGTERM then SIGKILL after 2s grace to the
  whole process group, exit code appended when non-zero. Command summary =
  `$ <command>` (first 80 chars). displayHint .commandOutput.
- `todo_write(items: [{id, text, status: pending|inProgress|completed}])`
  [read — auto-approved] — replaces ToolSessionState.todos wholesale;
  output "Todo list updated (N items)"; displayHint .todoList.

Descriptions inside ToolSpec must state WHEN to use the tool (e.g. grep:
"Search file contents by regex. Use glob to find files by name instead."),
matching the research finding that this reduces wrong-tool calls.

Permissions.swift: `BashSafety.isDangerous` — substrings `rm -rf`, `sudo `,
`git push`, `> /dev/`, `mkfs`, `:(){`, `| sh`, `| bash`, `curl ` combined
with `| `, plus writes to `~/.ssh`. `isReadOnly` — first token in
[ls, cat, head, tail, pwd, which, echo, wc, file, stat, du, df, uname,
sw_vers, git] where git's second token must be in
[status, diff, log, show, branch, remote]; any `>`/`>>`/`&&`/`;`/`|`
disqualifies read-only.

ToolsTests.swift: every tool against a temp dir fixture (FileManager
temporaryDirectory + UUID): read paging + numbering, write parent-dir
creation + un-read overwrite refusal, edit uniqueness/0-match/replace_all/
requires-read, glob ** and mtime order, grep modes + binary skip, bash
echo + exit code + timeout (short sleep), todo round-trip,
BashSafety table-driven cases.

## Builder 3 — UI (`Sources/Forge/UI/`)

Replace RootView.swift stub; add files as needed (suggested:
`ChatView.swift`, `MessageRow.swift`, `ToolCallCard.swift`,
`ApprovalPanel.swift`, `InputBar.swift`, `SessionSidebar.swift`,
`SettingsView.swift`, `MarkdownText.swift`, `StatusBar.swift`,
`TodoPanel.swift`). UI reads @Published state and calls AppState methods
only — never the engine/tools directly. No new assets, SF Symbols only.

- RootView: `NavigationSplitView`; sidebar = sessions (title + relative
  date, context-menu delete, New Session button); detail = chat column.
- Chat: `ScrollViewReader` auto-scroll to bottom on message/delta changes;
  user messages right-aligned bubbles, assistant messages plain full-width;
  thinking blocks collapsed by default behind a subtle "thought for a
  moment" disclosure; auto-expand nothing. Render text via MarkdownText.
- MarkdownText: split fenced ``` blocks; code in monospaced boxes with a
  hover copy button + language tag; non-code paragraphs through
  `AttributedString(markdown:)` (headings → bold larger text, lists kept as
  text); graceful fallback to plain Text on parse failure.
- ToolCallCard: one card per toolUse block: SF Symbol per tool, tool
  summary line, status (spinner while awaiting its toolResult; green
  check / red x after), collapsed by default; expands to show input params
  and the paired toolResult content (from the *matching* toolResult block —
  search all messages for toolUseId) in a scrollable monospaced box capped
  ~300pt. DisplayHint .diff renders old/new with red/green line tinting
  (line-by-line, no diff algorithm needed: show removed block then added
  block). .todoList renders a checklist.
- ApprovalPanel: when `state.pendingApproval != nil`, an inline panel
  pinned above the input bar (not a modal sheet): icon, tool name, summary
  (monospaced for bash), input preview (first ~6 lines), buttons
  **Allow once** (⌘↩, borderedProminent) / **Always allow** / **Deny**
  (destructive). Buttons call `pendingApproval.respond(...)`.
- InputBar: multiline `TextField(axis: .vertical)` (1–8 lines), ↩ sends,
  ⇧↩ inserts newline (onKeyPress), paper-plane send button; while
  `state.isRunning` swap to a Stop button (`state.stopRun()`) + subtle
  `state.statusText` shimmer above.
- StatusBar (bottom): workspace chip (folder icon + display path; click →
  NSOpenPanel via `state.setWorkspace`), model picker (Menu over
  ModelCatalog.models binding `state.settings.model`), token counter
  ("in 12.3k · out 4.1k · cache 8.0k", formatted compactly), auto-approve
  indicator when on.
- TodoPanel: if `state.currentTodos` non-empty, a compact collapsible
  checklist pinned above the input bar.
- Error banner: `state.lastError` in a dismissible yellow/red capsule.
- Empty state: centered app mark + "Choose a workspace and ask for
  anything" + 3 example prompt chips that fill the input.
- SettingsView (~460pt wide Form): SecureField for API key (load nothing —
  just placeholder "sk-ant-…"; Save button → `state.saveApiKey`; status
  line "Key stored in Keychain ✓" from `state.apiKeyPresent`); model
  Picker; workspace path + Choose… button; Toggle autoApprove with warning
  text; Stepper maxTurns (10–100); thinking Picker (adaptive/off).
- Dark-mode-first; respect system accent; min window 900×600; no emoji in
  UI chrome.

## Builder 4 — Infra & packaging (`Sources/Forge/Support/` + `scripts/`)

Files: `Keychain.swift` (`final class KeychainStore: KeychainProtocol` via
SecItem generic password, service "com.local.forge", account
"anthropic-api-key"; update-or-add semantics; treat errSecItemNotFound as
nil), `SessionStore.swift` (`final class FileSessionStore:
SessionStoreProtocol` — one pretty-printed JSON file per session at
`~/Library/Application Support/Forge/Sessions/<uuid>.json`, atomic writes,
corrupt files skipped not fatal, list sorted by updatedAt desc),
`Stores.swift` (replace: factories return the real stores), keep
`ForgeApp.swift` as scaffolded unless packaging requires changes.

`scripts/make_icon.sh`: generates `scripts/AppIcon.icns` — render a
1024×1024 PNG with a short inline Swift script (CoreGraphics: rounded-rect
deep-indigo→violet vertical gradient, bold white "F" with a hammer-ish
notch or anvil silhouette, subtle inner shadow), then sips-resize the
10-size iconset and `iconutil -c icns`. Idempotent, no network.

`scripts/build_app.sh` (the one command the orchestrator runs):
```
swift build -c release --product Forge   # NOT plain -c release: the
                                         # forge-tests target only compiles
                                         # in debug (@testable)
dist/Forge.app/Contents/{MacOS/Forge, Resources/AppIcon.icns, Info.plist}
codesign --force --sign - dist/Forge.app
ditto dist/Forge.app "$HOME/Applications/Forge.app"   # only when --install
```
Info.plist (heredoc in script or `scripts/Info.plist` template):
CFBundleIdentifier com.local.forge, CFBundleName Forge,
CFBundleDisplayName Forge, CFBundleExecutable Forge, CFBundlePackageType
APPL, CFBundleShortVersionString 0.1.0, CFBundleVersion 1,
LSMinimumSystemVersion 14.0, NSHighResolutionCapable true,
CFBundleIconFile AppIcon, LSApplicationCategoryType
public.app-category.developer-tools, NSHumanReadableCopyright "Local only.
© 2026".

InfraTests.swift: FileSessionStore CRUD + ordering + corrupt-file
resilience against a temp directory (inject the base directory —
FileSessionStore(baseDir:) with a default); KeychainStore round-trip
guarded to not clobber a real key (use a test-only service name via
init(service:)).

## Definition of done (integration, run by orchestrator)

`swift build` green; `swift run forge-tests` green; `scripts/build_app.sh`
produces a launchable Forge.app; a scripted end-to-end run with
MockTransport exercises chat → tool call → approval → result → finish.
