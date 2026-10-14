---
name: whittle-setup
description: Set up Whittle on a Mac (tools, build, signing, permissions) and connect it to an editor model — ChatGPT through the Codex CLI, a local model through Ollama, or another backend such as Claude Code, an OpenAI-compatible API (LM Studio, xAI Grok, OpenRouter), the Anthropic API or the Cursor CLI. Use when someone asks to install, build, configure, or change the model behind Whittle.
---

# Setting up Whittle

Whittle is a macOS app (SwiftUI + AppKit, built with xcodegen). Speech is transcribed locally by whisper.cpp; edits go
to an "editor model". Work through the steps in order and check each one before moving on. Ask the person before
anything that costs money, needs their password, or signs in to an account: they do those themselves.

## 1. Check the Mac

```bash
sw_vers -productVersion        # needs 14.0 or later
uname -m                       # needs arm64 (Apple silicon)
xcodebuild -version            # Xcode installed and opened once
brew --version                 # Homebrew
```

If Xcode was never opened, `sudo xcodebuild -license accept` is needed; the person runs it (it asks for their password).

## 2. Install the tools

```bash
brew install xcodegen whisper-cpp
which whisper-cli whisper-server   # both should resolve
```

Whittle looks for `whisper-cli` and `whisper-server` in `/opt/homebrew/bin`, `/usr/local/bin` and
`/opt/homebrew/opt/whisper.cpp/bin`.

## 3. Pick an editor model

Ask which they want. Check what's already installed first: `which codex ollama claude cursor-agent`.

**ChatGPT through Codex** (the default, and the only one Structure and Review modes use):

```bash
npm install -g @openai/codex
codex login                 # the person signs in with their ChatGPT account in the browser
codex debug models          # what their plan offers
```

The defaults are `gpt-6-luna` (everyday edits) and `gpt-5.6-sol` (whole-draft work, Structure, Review). If their plan
lacks those, set others:

```bash
defaults write com.personal.scriber codexFastModel <fast model>
defaults write com.personal.scriber codexModel <strong model>
```

Whittle finds `codex` in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`, `~/.volta/bin`
and nvm's node versions. Elsewhere, symlink it into one of those.

**Local, through Ollama** (free and private; weaker at rewriting; Structure and Review won't work):

```bash
brew install ollama
brew services start ollama
ollama pull qwen2.5:7b      # or qwen2.5:14b on a Mac with 32 GB or more
```

Then in Whittle: menu bar icon → Editor → Local model.

**Anything else:** see "Connecting a different backend" below. Do that before building.

## 4. Build, sign and install

```bash
scripts/install.sh
```

It builds a Release version, signs it, installs `/Applications/Whittle.app` and starts it. The signature matters:
macOS ties the microphone, Accessibility and Screen Recording permissions to it.

- With an Apple Development certificate in the keychain (`security find-identity -v -p codesigning`), it's used and
  permissions survive rebuilds. A free Apple ID is enough: Xcode → Settings → Accounts → Manage Certificates → + →
  Apple Development. The person does this in Xcode.
- With several, set the one to use in `scripts/local.env` (git ignores it):
  `WHITTLE_SIGN_IDENTITY="Apple Development: Name (TEAMID)"`.
- With none, it signs ad hoc. That works, but macOS asks for permissions again after every rebuild.

## 5. First launch

Tell the person to expect:

- Microphone, Accessibility and (optional) Screen Recording prompts. Accessibility and Screen Recording are toggled in
  System Settings → Privacy & Security; after granting Screen Recording, Whittle has to be restarted.
- A one-time download of the Whisper model (~1.6 GB) into `~/Library/Application Support/Whittle/models/`.
- ⌃⌥S opens the writing window. Talk, then say "okay, send".

If something fails, read `~/Library/Application Support/Whittle/logs/timing.log` (menu bar → Reveal Logs). Codex
errors show as `Codex: …`, Whisper problems as `whisper-cli …`.

Optionally help them fill in `~/Library/Application Support/Whittle/context/profile.md` and `writing-style.md`
(name, role, how they sign off, how they write). Ask; don't invent details.

## Connecting a different backend

All cloud calls go through one function in `Sources/Scriber/Interpreter/CodexEditor.swift`:

```swift
func json(kind: String, instructions: String, schema: [String: Any], prompt: String, model: String? = nil) async throws -> String
```

- `kind`: `edit`, `structure`, `review`, `review-reply` or `source`.
- `instructions`: the system prompt.
- `schema`: a JSON Schema (strict: every property required, `additionalProperties: false`).
- `prompt`: the user message.
- `model`: `fastModel` or `model`, or nil for the strong one.
- Returns: one JSON object as a string, matching the schema. Callers parse it with `InterpreterJSON.extractJSONObject`,
  so stray text around the object is tolerated.

Also relevant in that file:

- `isAvailable` (true when `launch` found the `codex` binary) decides whether the cloud editor is used at all.
- `prepareFiles(kind:instructions:schema:)` writes the instructions and schema to files.
- `run(_:_:stdin:path:)` runs a process with a 60 s timeout and returns its exit status and combined stdout + stderr.

To switch backends, change what `json` does and what `isAvailable` checks. Keep the rest of the app as it is. Leave
Codex as an option if the person might want it back: add a setting (a `UserDefaults` key) rather than deleting code.

**Security rule, for every backend:** the prompt contains text read from the person's screen (emails, web pages),
which may contain instructions aimed at the model. The call must be text in, JSON out, with no tools, no shell, no
file access and no MCP servers. Never pass flags that let the model act.

### Claude Code (`claude -p`)

Uses the person's Claude subscription login (`claude` then `/login`, done by them). Arguments for `run`:

```
-p "Follow the system instructions. The input is on stdin."
--system-prompt-file <instructions file from prepareFiles>
--json-schema <the schema as a JSON string, not a path>
--output-format json
--tools ""
--strict-mcp-config
--no-session-persistence
--model sonnet            # or opus / haiku / a full model name
```

The prompt goes on stdin. Stdout is one JSON object: the answer is in `structured_output` (check `subtype == "success"`
first), so re-serialise that field and return it. `run` merges stderr into the output, so extract the JSON object
rather than parsing the whole string.

- Without `--bare`, Claude Code still loads the user's own CLAUDE.md, hooks and plugins. Set the process's
  `currentDirectoryURL` to Whittle's `codex` folder in Application Support (`run` doesn't set one today), so at least
  no project's files are picked up.
- `--bare` skips all of that, but only works with `ANTHROPIC_API_KEY` (API billing), not the subscription.
- Check the flags against `claude --help` on their version. Test one real call, and one with an invalid schema to see
  the failure shape.

### OpenAI-compatible HTTP APIs: LM Studio, xAI (Grok), OpenRouter, Ollama's `/v1`

Replace the process call with a `URLSession` request:

```
POST {base}/v1/chat/completions
Authorization: Bearer <key>          # not needed for LM Studio or Ollama
{
  "model": "<model>",
  "messages": [{"role": "system", "content": instructions}, {"role": "user", "content": prompt}],
  "response_format": {"type": "json_schema", "json_schema": {"name": kind, "strict": true, "schema": schema}}
}
```

Return `choices[0].message.content`. Base URLs: LM Studio `http://localhost:1234`, Ollama `http://127.0.0.1:11434`,
xAI `https://api.x.ai`, OpenRouter `https://openrouter.ai/api`. Not every model honours `json_schema`; if one doesn't,
fall back to `{"type": "json_object"}` and say so in the instructions.

API keys: never hard-code them or commit them. Read them from the Keychain (or, at minimum, an environment variable)
and tell the person where to put theirs; they enter it themselves.

### Anthropic API

`POST https://api.anthropic.com/v1/messages` with `system: instructions`, the prompt as the user message, and one
tool whose `input_schema` is the schema, forced with `tool_choice: {"type": "tool", "name": ...}`. Return the
tool call's `input`, serialised. Same key handling as above.

### Cursor CLI (`cursor-agent`)

`cursor-agent -p --output-format json --model <model>` with the instructions and prompt combined (check
`cursor-agent --help` for a system prompt option). It doesn't enforce a schema: validate the reply's keys and types
against the schema and retry once with the error appended. Make sure it runs without tool permissions; if the CLI can't
guarantee that, prefer an API backend.

### After changing the backend

1. Build and run the tests: `xcodegen generate && xcodebuild -project Scriber.xcodeproj -scheme Scriber -destination 'platform=macOS,arch=arm64' test`.
2. Reinstall with `scripts/install.sh`.
3. Try a real edit: open Whittle, say "write a short note to Sam saying the meeting moved to Friday, okay send", and
   check `timing.log` for the call and its timing.
4. Then try Structure and Review if the backend should cover them.
