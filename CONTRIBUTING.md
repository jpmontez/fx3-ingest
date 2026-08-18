# Contributing

This is a small, single-file bash script. Patches are welcome; the bar is
that a change has to be safe for someone about to format an SD card.

## Before opening a PR

**Lint.** `shellcheck fx3_ingest.sh` must be clean — CI runs it on every PR.

```bash
brew install shellcheck
shellcheck fx3_ingest.sh
```

**Test by hand.** There is no automated test suite, by design: the script's
real behaviour is about filesystem state, mtimes, and interrupted copies,
which is awkward to fake and easy to fake *wrongly*. Exercise changes against
a scratch source and destination instead. The full checklist lives in
[`CLAUDE.md`](CLAUDE.md#development-conventions); at minimum:

- fresh ingest, then re-run — the second run should skip everything
- two dirs under one parent, each with a **different** `C0001.MP4` at the same
  mtime → grouped collision, nothing copied, exit 1
- two byte-identical copies (`cp -p`) under one parent → one `COPY`, one
  `DUPLICATE`, exit 0
- `--dry-run`, and `--verify` against a deliberately corrupted copy
- `./fx3_ingest.sh src dst | tee log` → the log must contain no ANSI escape
  codes and no progress bar

To test against real clips without duplicating tens of gigabytes, `cp -Rc`
makes an instant APFS copy-on-write clone of an archive.

## High-risk areas

Two parts of this script have already caused **silent data loss**, both found
only after the fact. Changes there get scrutinised hard, and a PR touching
them should say which of the collision repro cases above you ran.

- **Name collisions.** FX3 cards restart at `C0001.MP4` after a format, so
  two cards from one shoot day hold different clips with identical names. A
  bug here once reported `Copied & verified: 2`, left one file on disk, and
  exited 0 — telling the operator the card was safe to format.
- **Date resolution.** QuickTime `CreateDate` is UTC. Reading it directly
  files evening clips into the next day's folder and splits a shoot across
  two directories, which is not obvious from the output.

`CLAUDE.md` explains why both work the way they do. Read it before changing
either.

## Conventions

- Target **bash 3.2** — the system bash on macOS. No `mapfile`/`readarray`,
  no associative arrays.
- Decide behaviour in the planning stage, not mid-copy. `--dry-run`, the
  free-space check, and the progress bar are all honest only because the plan
  is built before anything is written.
- Keep `README.md` and `CLAUDE.md` in sync with script changes.
