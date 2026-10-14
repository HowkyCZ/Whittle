# Architecture decisions

| Choice | Decision | Why |
|---|---|---|
| App name | **Whittle** (product name and display name; the Xcode project, targets, modules and bundle identifier still say Scriber) | Keeping the identifier keeps macOS permissions; Application Support moves over once (`AppSupport.moveFromPreviousName`) |
| Brand | The pixel quill, and a pixel serif wordmark drawn on its grid (12 px caps, crossed W); palette "Clay and dusky slate": clay for anything live, plum for exact words, slate teal for settled, violet-leaning greys | One mark, one loud colour |
| UI | Light panel per the voice-writer design handoff v3: the draft is a plain `NSTextView` (select, type, cut, paste) with paragraph numbers, approvals, locks and highlights drawn behind the text; voice box with the unsent transcript styled by role | Talking and typing work on the same text; marks never get in the way of editing |
| Modes | Write, Structure and Review (design handoff v6) share the session, voice box and history; the dropdown sits on the chips row in Write and in the header elsewhere | One document, three views of it |
| Structure | `Outline` (ScriberCore): sections own paragraph numbers from the latest check. Every Structure call returns the whole outline (`OutlineReply`); new ids are numbered locally, a paragraph belongs to one section, and moved written sections reorder the draft (`Outline.regroup`) as one version. A check runs 1.2 s after every change lands. "Write the rest" becomes an ordinary editor request with each section's place and points | Full-state replies are easier to keep consistent than op lists for 5–10 sections; the paragraph mapping comes from the model so it survives free editing |
| Review | Each enabled agent is one parallel ChatGPT call returning quotes and comments; quotes are found in the draft (`ReviewText.locate`, tolerant of case and spacing). Approved comments and agreed conclusions go to the editor as one request | Models can't count character offsets; quoting is reliable |
| Dictation | ⌥Space or the selection mic: clips go verbatim into a `Dictation` preview (selection struck through, words after it); Replace applies one version | No model in the loop, so the words are exactly what was said |
| Phrase rules | `SpokenMechanics` (ScriberCore) reads places as people say them ("the last sentence of paragraph three", "the greeting", "this") and applies mechanical edits with no model: move, swap, delete, merge, split, exact wording, bold, list. Anything with a judgement goes to the editor with the place found sent as POINTED AT; the place lights up in the draft while it's said | Edits that need no judgement land in ~15 ms instead of 4–14 s, and the editor no longer has to count paragraphs |
| Formatting | `DraftFormat`: the draft stays plain text with "• ", "1. ", `**bold**`, `*italic*`. The editor draws them (markers laid out as null glyphs via `MarkerHider`; caret, Shift-arrows and Delete step over them; ⌘B / ⌘I; lists continue on Return). Model output is normalised on apply; Done pastes HTML lists and `<strong>`/`<em>` with marker-free plain text alongside | One string for the document model, diffs, undo and the editor prompt; formatting still pastes as formatting |
| Editor models | ChatGPT through `codex exec` with Codex's own skills, permissions, multi-agent and environment text switched off (19.3 KB → 1.5 KB per call). `EditRouting`: everyday edits to gpt-6-luna (~4–5 s), whole-draft rework, long briefs, Structure, Review and "Write the rest" to gpt-5.6-sol (~9–14 s); Ollama is kept loaded 30 min | Replaying 14 real requests: luna matched sol except on whole-draft rework |
| Sending | Push-to-send: speech collects in the voice box until Send, Return or "okay, send" | Pauses are for thinking; nothing reaches the editor until you say so |
| Hotkey | ⌃⌥S via Carbon `RegisterEventHotKey` | Reliable without an event tap |
| STT | **whisper.cpp** (`whisper-cli`, Metal), `large-v3-turbo` else `base.en` | Apple Speech dropped most utterances |
| VAD | `SpeechGate`: loudness against the room's own background (quietest tenth of the last 6 s); 3× starts a clip, 2× keeps it going, a 1.6 s pause ends it; 0.4 s pre-roll; clips under 150 ms of voice dropped | A fixed bar (0.008) missed quiet speakers: at 0.005 rms it heard 1.7 s of a 4.7 s sentence |
| Noise clips | `NoiseFilter`: a finished clip under rms 0.003 (and under 6× the room) isn't transcribed; Whisper's stock lines ("Thank you.", "The End") only count from clips over rms 0.006 and 10× the room | Taps and knocks held clips open for 3–8 s and came back as "Thank you."; in 39 logged clips noise was 0.0010–0.0034 rms, speech 0.0052 and up |
| Live words | `whisper-server` on 127.0.0.1:8178 keeps the model loaded while the panel is open (stops 10 min after close); the clip in progress is re-transcribed every 0.8 s and shown faintly | ~0.5 s per transcription instead of ~1.5 s with `whisper-cli`, which stays as the fallback |
| LLM | **Ollama**, strongest installed of `qwen2.5:7b` → `llama3.1:8b` → `llama3.2` | llama3.2 (3B) mislabeled asks as asides and invented quotes |
| Text fields | `TextFieldWatcher` polls the focused element over Accessibility (off the main thread, 0.3 s timeouts); `FieldButton` sits right after the caret (`AXBoundsForRange` on the letter before it), hides while the caret moves, and falls back to the field's corner where the app only reports the whole field (Chromium, Electron); dragged, it keeps that place per app (`ButtonPlace`: across from the field's nearer side, up and down from the window's nearer edge, since web fields report their position loosely — Claude's moves when an image is attached); `TextInserter` waits for the app to take keystrokes, refocuses the field, posts ⌘V and reads the field back (retry, then `AXSelectedText`) | Works in native fields and browser editors (Electron needs `AXManualAccessibility`, Chrome `AXEnhancedUserInterface`); paste carries the HTML clipboard; "Inserted" only when verified |
| Screen context | `ScreenReader`: ScreenCaptureKit captures the source app's frontmost window at 2×, scaled to fit (a window on a 1× display otherwise lands in a corner and its text is unreadable), Vision reads it on-device, only the text is kept; sent to ChatGPT as ON SCREEN. A banner above the draft shows the source, a ChatGPT one-line summary, or why reading failed | Knows what's being replied to without an email integration; the banner makes it visible what the editor sees |
| Selections | `Accessibility.selectedText`: AXSelectedText in native views, `AXSelectedTextMarkerRange` / `AXStringForTextMarkerRange` / `AXBoundsForTextMarkerRange` in web views (Chrome, Electron); polled with the field watcher, shown once it holds still | The button follows text the writer selects anywhere, not only focused fields |
| Context files | The writer's own folder; the + picker chooses files per draft; `profile.md` / `writing-style.md` templates go with every draft once filled; HTML comments are stripped | Nothing personal ships with the app |
| Install | `scripts/install.sh`: Release build, `codesign` with the Apple Development certificate, `/Applications`; Open at Login via `SMAppService` | A stable signature keeps TCC permissions across updates |

## Editor engines

Default: **ChatGPT through the Codex CLI** (`codex exec`, signed in with the ChatGPT account; menu bar icon → Editor
switches to the local model). The local model labels the unsent transcript for its highlights and guesses where the
edit lands, which drives the working highlight. The ChatGPT call starts when the writer sends, never before.

Contract (`ParagraphEdits`): the draft goes out as `[p1] … [pN]`, one per line, matching the ¶ margin numbers; the
reply is `{ops:[{op: replace|insert_after|insert_before|delete, id, text, from_speech}], reply, could_not_do, approved}`.
The prompt also carries the selection (what "this" means), locked wording and approved paragraph ids.
Ops apply against the draft as sent, mapped onto the current draft by paragraph text, so edits made meanwhile are kept
and an op on a paragraph that changed is a conflict. The prompt also carries profile/style/project context and the last
few turns ("said X → rewrote p4 (was …) as …"), so reactions to the last change can be understood. Codex's own agent
prompt, tools, plugins and MCP servers are switched off for these calls (`model_instructions_file`, `--disable …`),
which brings a call to ~6 s. `build/codex_probe.py` replays a session through the same prompt.

In ChatGPT mode the spoken-command parser and the review pass are off; both still run with the local engine.

## Speaking, sending, marks

- Clips are numbered and transcribed in parallel, but `ClipSequencer` hands them out in spoken order, so a quick
  "okay, send" can't overtake the sentence before it. Send (button or Return) ends the clip being spoken and waits
  until everything said before the press is transcribed (at most 12 s).
- Failed clips (speech but no words) are kept in `logs/missed-clips` (last 8); each clip's loudness is in timing.log.
- `VoicePhrases` sorts each transcribed clip: "okay, send" (stripped, then send), "scratch that" (clear unsent), and
  "undo that" / "redo" / "stop" act right away. Everything else is appended to the unsent text.
- With text selected when sending, the selection is the target: ChatGPT gets it as SELECTION, the local engine
  swaps it in for "this"/"that" (`SelectionTarget`) and the working highlight sits on exactly those words.
- **Locks**: "say exactly" wording that lands is locked (`LockedWording`). An AI edit that would change it is taken
  back (`DocumentModel.discardLastChange`) and the answer card says so. Editing the words by hand releases the lock.
- **Approvals**: "good, the opening works" puts a check in the gutter (ChatGPT returns `approved`; the local engine uses
  `ApprovalParser`). Approved paragraphs are sent as APPROVED and left alone unless named directly.
- **History**: every AI change and every burst of typing (keystrokes < 2 s apart) is one version; ⌘Z / ⇧⌘Z and
  "undo that" step through them. The app installs a hidden Edit menu so text shortcuts work in a menu-bar app.
- **Highlights**, drawn in `DraftTextView.drawBackground`: while an edit is written, a light sweeps across the target
  lines (or a seam glows where a paragraph will be inserted, or placeholder lines shimmer at the end; the whole draft
  softly when the place is unknown). Added text then glows for ~2 s and fades. A question's subject is tinted green
  while its answer is open.

## Pipeline (local engine)

```
mic → clip on pause → whisper → fragment → unsent text (labeled for display)
  → Send / Return / "okay, send"
  → every sentence a spoken command (or filler)? → command mode, skips the labeler (see below)
  → ClauseChunker (deterministic split on punctuation and framing words)
  → LLM labels each numbered clause: aside / ask / gist / words / where / tone, plus complete?
  → SpanPlanner: known edit (where + words → replace, bare words → append) or needs the writer
  → writer LLM: one action (append / replace / replace_all / delete / none) with the actual text
  → reconcile (asks/asides never become text; a "replace" that restates the greeting or sign-off is a full rewrite)
  → applier (revision-checked, snapshot undo) → paper
  → after 3 s of quiet: review pass
```

The review pass checks the draft as a whole and lands as one undoable change. Code does the checks it can verify itself:
repeated paragraphs or greetings, text after the sign-off, and "instead of X say Y" requests from the last few minutes
whose X is still there (unless a later request touched the same text). If the latest request's wording is missing, the
writer gets one more try. The model only answers a narrow per-paragraph question for new or changed paragraphs: is this
a leftover spoken instruction (removed only if it matches something actually said) or content, and if content, the same
paragraph without spoken filler (accepted only if it keeps most of the original words). Speaking cancels the review.
A paragraph only counts as a leftover if it's short, mostly matches speech labeled ask/aside, and barely matches speech
labeled words/gist — dictated text always overlaps the utterance, so overlap alone proves nothing. One deletion per pass.

### Command mode

Starting a sentence a certain way picks the mode explicitly (`CommandParser`): Replace ("replace X with Y", "instead of X,
say Y", "you say X, just say Y"), Delete ("delete X", "delete that"), Rewrite ("make X shorter", "rewrite X"), Exact words
("say exactly …, after X"). Code locates X (`TextLocator`) and builds the op (`CommandPlanner`); the model only writes the
new text for Rewrite. If X can't be found, nothing changes and the panel says so — a command never falls back to appending.

`TextLocator` finds spoken references in the draft: exact text, then word-level Smith–Waterman alignment that tolerates
dropped/extra words and misheard words (edit distance or Soundex, so "heaven founders" finds "Haven Founders"), then
structural references ("the sign-off", "the second paragraph", "the part about X"). Paragraphs are blank-line blocks.
Names in replacement text are respelled to match the draft, and names in the draft are passed to Whisper as a prompt.

Local commands that skip the model: undo, stop/cancel, "delete everything".

## Logs

- `logs/timing.log` — every step, including labels and the model used
- `logs/turns.jsonl` — one line per acted utterance: transcript, spans, ops, document before/after

## Deferred

- Silero VAD / adaptive pause
- Streaming Whisper partials in the tray
- Keyword retrieval over all project files
- Selected-text import from the previous app (the "Replying to your selection" quote in the v3 mockups)
