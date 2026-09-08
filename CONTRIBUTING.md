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
a scratch source and destination instead — the checklist to work through is
[`CLAUDE.md` § Development conventions](CLAUDE.md#development-conventions).

To test against real clips without duplicating tens of gigabytes, `cp -Rc`
makes an instant APFS copy-on-write clone of an archive.

## High-risk areas

**Name collisions** and **date resolution** have each already caused silent
data loss, found only after the fact. Changes there get scrutinised hard, and
a PR touching them should say which of the collision repro cases you ran.
[`CLAUDE.md`](CLAUDE.md) explains why both work the way they do — read it
before changing either.

## Conventions

- Target **bash 3.2** — the system bash on macOS. No `mapfile`/`readarray`,
  no associative arrays.
- Decide behaviour in the planning stage, not mid-copy. `--dry-run`, the
  free-space check, and the progress bar are all honest only because the plan
  is built before anything is written.
- Keep `README.md` and `CLAUDE.md` in sync with script changes.
