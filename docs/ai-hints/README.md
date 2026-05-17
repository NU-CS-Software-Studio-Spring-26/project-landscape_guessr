# AI visual hints — phased implementation chats

Use **one new Cursor chat per phase**. Copy the entire contents of the phase file into the chat as your first message. Do phases in order (0 → 6).

| Phase | File | What it delivers |
|-------|------|------------------|
| 0 | [phase-0-setup.md](phase-0-setup.md) | Gemini API key, env vars, initializer |
| 1 | [phase-1-database.md](phase-1-database.md) | `image_ai_hints` table + model |
| 2 | [phase-2-generation.md](phase-2-generation.md) | Services + `GenerateAiHintJob` |
| 3 | [phase-3-api.md](phase-3-api.md) | `GET /practice/hint` + tests |
| 4 | [phase-4-backfill.md](phase-4-backfill.md) | Rake task to pre-generate hints |
| 5 | [phase-5-ui.md](phase-5-ui.md) | Practice “Visual” hint UI + Stimulus |
| 6 | [phase-6-ops.md](phase-6-ops.md) | Legal copy, fallbacks, README/Heroku |

**Model (all phases):** `gemini-2.5-flash-lite` via Google Gemini API (`generateContent`).

**Prerequisite:** Phases 1–6 assume Phase 0 is done. Each chat should only implement its phase unless you explicitly ask to catch up on dependencies.
