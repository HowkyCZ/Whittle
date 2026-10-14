# Whittle

A macOS app for writing by voice. Say the gist, then talk the draft into shape over as many passes as it takes: move,
cut, rephrase, plan sections, get review comments. Done pastes it back where you were typing.

Speech is transcribed on your Mac with [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Edits go to ChatGPT
through the [Codex CLI](https://github.com/openai/codex), or to a local model through [Ollama](https://ollama.com).

**Status: beta.** It's a personal tool made public: expect rough edges, and expect things to change.

- macOS 14 or later, Apple silicon
- Licensed under the [GNU AGPL v3](LICENSE)

## Install

You build it yourself; there's no download yet. It takes about ten minutes.

1. **Tools.** Install Xcode from the App Store and open it once. Then, with [Homebrew](https://brew.sh):

   ```bash
   brew install xcodegen whisper-cpp
   ```

2. **An editor model**, at least one of:

   - **ChatGPT** (recommended; needs a ChatGPT plan): install the Codex CLI and sign in with your ChatGPT account.

     ```bash
     npm install -g @openai/codex
     codex login
     ```

   - **A local model** (free, private, weaker at rewriting):

     ```bash
     brew install ollama
     brew services start ollama
     ollama pull qwen2.5:7b
     ```

3. **Build and install:**

   ```bash
   git clone https://github.com/HowkyCZ/Whittle.git
   cd Whittle
   scripts/install.sh
   ```

   This builds a release version, signs it, copies it to `/Applications/Whittle.app` and starts it. Run it again to
   update.

4. **Permissions.** On first use macOS asks for:
   - **Microphone**: to hear you.
   - **Accessibility**: the Whittle button in other apps' text fields, and pasting the draft back into them.
   - **Screen Recording** (optional): reading the window you came from, so the editor knows what you're replying to.

   Missing ones are listed in the menu bar menu. The first launch also downloads a Whisper model (about 1.6 GB) into
   `~/Library/Application Support/Whittle/models/`.

### Signing

macOS ties those permissions to the app's signature. `scripts/install.sh` signs with, in order:

1. `WHITTLE_SIGN_IDENTITY` from your environment or from `scripts/local.env` (git ignores it), e.g.
   `WHITTLE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"`
2. the first **Apple Development** certificate in your keychain. You don't need a paid developer account: in Xcode →
   Settings → Accounts, add your Apple ID, then Manage Certificates → + → Apple Development.
3. ad hoc. This works, but macOS asks for the permissions again after every rebuild.

## Using it

Press **⌃⌥S** anywhere, or click the menu bar icon, or the small Whittle button that appears next to the caret when you
click into a text field (or under text you select).

- **Talk, then send.** Your words collect in the voice box as you speak (faint until a pause settles them). Click
  **Send**, press Return, or say **"okay, send"**. "Scratch that" clears what's unsent; "undo that" steps back a
  version. You can also type into the voice box.
- **The draft is a normal text editor.** Select text before you send and "this" means the selection. ⌘Z / ⇧⌘Z step
  through versions.
- **Edits that need no model** land instantly: "move paragraph four before paragraph two", "delete the last sentence
  of paragraph three", "split paragraph two after the first sentence", "after paragraph three say exactly … end
  quote", "make paragraph three a list". Anything that needs judgement ("make it warmer") goes to the editor model,
  told exactly where. The place you name lights up while you say it.
- **Formatting.** Bullets, numbered items, **bold** and *italic*: ask for them, type "- " to start a list, or use
  ⌘B / ⌘I. Done pastes them as real formatting where the app accepts it.
- **Word for word.** Select text and press ⌥Space (or click the small mic at the end of the selection): what you say
  replaces it exactly, with no model involved.
- **Done** (⌘↩) pastes the draft into the field you came from and checks that it arrived; otherwise it's on the
  clipboard.

### Modes

The dropdown next to the context chips switches modes. Both of these use ChatGPT, whichever editor is chosen.

- **Structure** plans the piece before the prose: sections, why each is there, and the points it must make. Talk to
  add, move, merge or rename them. As you write, each point is ticked when the text covers it. **Write the rest**
  drafts the sections that aren't written yet.
- **Review** has reviewers comment on the draft: Skeptic, Cutter, Fact check, Reader and Tone, each in its own colour.
  Approve, dismiss, or reply to argue it out; **Send N to editor** applies everything you approved in one go. Add your
  own reviewers in the settings popover.

### Context files

The editor writes better when it knows who you are. Your Markdown files live in
`~/Library/Application Support/Whittle/context/` (menu bar → **Reveal Context Folder**). `profile.md` and
`writing-style.md` start as templates and go with every draft once you've filled them in; **+** next to the chips adds
any other file to the current draft.

### The text-field button

It sits next to the caret in native apps (Mail, Notes, Messages…). Browsers and Electron apps don't say where the caret
is, so there it sits in the field's corner. It steps aside while you type. Drag it anywhere and it stays there in that
app; right-click → **Put Back Next to the Cursor** undoes that. Menu bar → **Button in Text Fields** turns it off.

## Choosing the editor model

Menu bar icon → **Editor** switches between **ChatGPT (Codex)** and **Local model**.

**ChatGPT.** Whittle runs `codex exec` with a read-only sandbox, the shell tool and MCP servers off, and your Codex
config ignored: the model can only answer with JSON. Everyday edits use a fast model, while whole-draft rewrites,
Structure and Review use a stronger one. To change them (`codex debug models` lists what your plan offers):

```bash
defaults write com.personal.scriber codexFastModel gpt-6-luna
defaults write com.personal.scriber codexModel gpt-5.6-sol
defaults write com.personal.scriber codexEffort low
```

`codexEffort` is `low`, `medium` or `high`. Menu bar → Editor → **Fast Edits** off sends everything to the stronger
model.

**Local model.** Whittle uses the strongest of `qwen2.5:14b`, `qwen2.5:7b`, `llama3.1:8b` and `llama3.2` that Ollama
has installed, at `http://127.0.0.1:11434`. Structure and Review still need ChatGPT.

**Something else** (Claude, Cursor, Grok, LM Studio, an API key…) isn't built in, but it's a small change. Every
ChatGPT call goes through one function, `CodexEditor.json(kind:instructions:schema:prompt:model:)` in
[`Sources/Scriber/Interpreter/CodexEditor.swift`](Sources/Scriber/Interpreter/CodexEditor.swift). It takes system
instructions, a JSON Schema and a prompt, and returns JSON that matches the schema. Swap what it runs:

| Backend | How |
|---|---|
| Claude Code | `claude -p` with `--system-prompt-file`, `--json-schema '<schema>'`, `--output-format json` (the answer is in `structured_output`), `--tools ""` and `--model sonnet`. It uses your Claude login; adding `--bare` (skips CLAUDE.md, hooks and plugins) needs an `ANTHROPIC_API_KEY`. |
| OpenAI-compatible APIs: LM Studio, xAI (Grok), OpenRouter, Ollama's `/v1` | `POST /v1/chat/completions` with the instructions as the system message and `response_format: {"type": "json_schema", ...}` |
| Anthropic API | The Messages API, with the schema as the one tool the model must call |
| Cursor CLI | `cursor-agent -p --output-format json`. It doesn't enforce a schema, so validate the reply and retry. |

Whatever you use, keep it a plain text-in, JSON-out call with no tools: the prompt includes text read from your
screen, which you don't control.

There's a step-by-step guide for coding agents in
[`.claude/skills/whittle-setup/SKILL.md`](.claude/skills/whittle-setup/SKILL.md). Open the repo in Claude Code, Codex
or Cursor and ask it to set Whittle up with your model.

## Privacy

- **Speech** is transcribed on your Mac. Audio never leaves it.
- **With ChatGPT as the editor**, OpenAI receives the draft, what you said, the context files you chose for the draft,
  and (if Screen Recording is on and you keep the banner) the text of the window you came from. Screen text is
  recognized on your Mac; the image isn't kept or sent.
- **With the local model**, nothing leaves your Mac except Structure and Review, which use ChatGPT.
- **Logs** stay on your Mac: `~/Library/Application Support/Whittle/logs/` holds `turns.jsonl` (what you said and the
  draft before and after each edit) and `timing.log`. Menu bar → **Reveal Logs**; delete them whenever you like.
- **Accessibility.** To see text fields in Chrome and Electron apps, Whittle switches on their accessibility mode
  (`AXEnhancedUserInterface` / `AXManualAccessibility`), as screen readers do.

## Development

```bash
xcodegen generate
open Scriber.xcodeproj
xcodebuild -project Scriber.xcodeproj -scheme Scriber -destination 'platform=macOS,arch=arm64' test
```

The app was called Scriber at first; the Xcode project, targets, modules and bundle identifier still are.
`ScriberCore` holds the logic that doesn't need AppKit (reading speech, the document model, formatting) and has the
tests; `Sources/Scriber` is the app.

- [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md): the decisions and why
- [Docs/FOCUS_RESTORE.md](Docs/FOCUS_RESTORE.md), [Docs/INVOCATION.md](Docs/INVOCATION.md): getting back to the app
  you came from
- [AGENTS.md](AGENTS.md): notes for coding agents

Issues and ideas are welcome. For anything bigger than a small fix, please open an issue before a pull request.

## License

[GNU Affero General Public License v3.0](LICENSE). The name Whittle and the quill logo aren't covered by the license.
