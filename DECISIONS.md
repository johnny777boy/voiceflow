# DECISIONS
Last updated: 2026-11-09

Full list: "Product principles" in CLAUDE.md. Main ones:
- Exact words win over everything: cleanup may not add, remove or swap words. Silence produces nothing.
- Same formatting in every app.
- Never auto-send (no Enter).
- English only for now; Hebrew later as second language.
- Privacy: audio never leaves the Mac. Cloud features are opt-in and off by default.
- All work on a feature branch; main is the last verified version. Never commit to main directly.
- Never change the audio-capture path without Yoni present. Reason: it broke twice and cannot be checked without a mic.
- Rollback means the previous archived build (Scripts/rollback_app.sh), not "reinstall from main".
Source for all: CLAUDE.md.
