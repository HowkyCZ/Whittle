# Universal invocation — short investigation

Goal: eventual “invoke from anywhere,” without blocking the first feel-test.

| Mechanism | Pros | Cons | Verdict |
|---|---|---|---|
| **Global hotkey** (`RegisterEventHotKey` / KeyboardShortcuts) | Simple, works system-wide once permitted | Needs Input Monitoring or Accessibility depending on API; user must learn the chord | **Implement for first test** (⌃⌥S) |
| Accessibility API | Can read focused UI / selected text | Spotty in web views; permission-heavy | Later for selected-text import |
| Services / Quick Actions | Native “Services” menu integration | Discovery poor; not continuous voice | Optional after hotkey |
| Context-menu extension | Familiar | Extension packaging cost; not required for MVP | Nice-to-have, not MVP |
| Overlay on foreign text fields | Feels magical | Hard, brittle, out of scope | Do not build |

**First test:** global hotkey only. Document selected-text import as post-validation work.
