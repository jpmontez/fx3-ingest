# FX3 Media Ingest Script

## Context

The user shoots on a Sony FX3 and needed a way to offload MP4 clips from an SD
card onto a MacBook Pro in an organized fashion, so that bins in the video
editor (DaVinci Resolve) aren't a mess on import.

### Background / tools evaluated

- **Offshoot by Hedge** — previously used, but the owned license is
  incompatible with the current macOS version.
- **DaVinci Resolve's Clone tool** (Media page) — does verified/checksummed
  copying, but is a flat copy with no metadata-derived folder templating.
  Resolve *can* auto-bin on import by mirroring folder structure, so this
  remains the intended import step after ingest.
- **phockup** (open source, exiftool-based) — sorts by date only, no
  camera-model/reel folder templating, and not very actively maintained
  (~3 years stale at time of evaluation).
- **Elodie** (open source, exiftool-based) — more actively maintained, but
  aggressively renames files, which conflicts with keeping native FX3
  filenames (`C0001.MP4` etc.) intact.
- **Conclusion**: no single open-source tool fully met requirements, so the
  solution is a custom shell script wrapping `exiftool` directly.

## Current solution: `fx3_ingest.sh`

A bash script that:

1. Recursively finds `.MP4` files in a source directory (the SD card's clip
   folder).
2. Derives a destination folder path `<destination>/<YYYY-MM-DD>/<filename>`
   (e.g. `Footage/2026-07-12/C0001.MP4`) from each clip's *local* shooting
   date. **Do not use the bare `CreateDate` tag here** — see "Date
   resolution" below; getting this wrong silently splits a shoot across two
   folders and it is not obvious from the output.
3. Falls back to the file's modification time (`stat -f %Sm`) if metadata
   is missing, then to an `Unknown-Date` folder as a last resort.
4. Copies each clip's Sony NRT metadata XML sidecar (e.g. `C0001M01.XML`
   for `C0001.MP4`) into the same date folder. Note: DaVinci Resolve does
   not use these (it reads metadata embedded in the MP4); they're kept for
   archival completeness and Sony's own tools (Catalyst Browse/Prepare).
5. Copies each file, preserving original filenames and timestamps
   (`touch -r`). The source is read only once — `tee` streams it into a
   `.part` staging file while `shasum` hashes the same stream — roughly
   halving ingest time vs. hash-then-copy, since the SD card is the
   bottleneck. The staged copy is renamed into place only after its hash
   is verified, so the destination never holds an unverified file (safe to
   point Resolve at mid-ingest). A trap cleans up the `.part` file if the
   script is interrupted.
6. Writes a `.sha256` sidecar file next to each copied file in standard
   `shasum -c` format, so the archive can be re-verified later without the
   original SD card.
7. Is idempotent — on re-run, skips files already ingested by comparing the
   **source** against the **destination** (size + mtime). See "Name
   collisions" below for why it must not compare the destination against its
   own sidecar instead.
8. Discards the staged copy and reports failure if a checksum mismatch or a
   write error occurs (protects against corrupt or truncated copies).
9. Checks the destination volume has enough free space (`df -Pk`) before
   starting, counting only the files the plan says need copying.
10. Shows a live, in-place progress bar (`[####----] 42% (5/20 files,
   4.2GB/9.8GB)`) pinned beneath the per-clip log lines. Progress is weighted
   by bytes rather than file count, since FX3 clip sizes vary wildly (a few
   hundred MB up to several GB), and byte-weighting reflects actual time
   remaining more accurately than a flat per-file count would.

### Architecture: plan then execute

The script walks the card **once** into an array, resolves all dates in one
batched `exiftool` call, then writes a tab-separated plan file
(`<action>\t<src>\t<dst_dir>\t<size>\t<reason>`, action ∈
`COPY`/`SKIP`/`COLLISION`) into a `mktemp -d` scratch dir. Execution just
walks the plan.

This is what makes `--dry-run` honest, the free-space check exact, and the
progress bar reflect only real work. When adding behaviour, decide it in
`plan_actions` rather than mid-copy. Bash 3.2 (system bash) — no
`mapfile`/`readarray`, no associative arrays; the plan file exists partly
because of that.

### Date resolution

QuickTime `CreateDate` in an MP4 is stored in **UTC**. Reading it directly —
which the original version did — files anything shot after ~19:00 local into
the next day's folder. This misfiled 8 of 9 clips in the user's real archive
before being caught, splitting one evening shoot across two folders.

Order of preference, all in a single batched exiftool call:

1. `CreationDateValue` — Sony NRT tag, carries the camera's own UTC offset
   (`2026-07-20T19:01:58-05:00`). True local wall-clock; preferred.
2. `CreateDate` with `-api QuickTimeUTC=1` — converts UTC to the Mac's local
   time. Correct only if Mac and camera share a timezone.
3. `stat -f %Sm` mtime.
4. `Unknown-Date`.

Batching matters: exiftool costs ~0.5s of perl startup per invocation, which
dominated ingest on a large card when called per file.

### Name collisions

FX3 cards restart at `C0001.MP4` after a format, so two cards from one shoot
day hold different clips with identical names. The original skip check
compared the destination against its own sidecar — which always matched — so
the second card's clips were reported "Skipping (verified)" and silently
never copied, with exit 0.

The check must compare **source vs. destination**. On mismatch the script
reports a collision, copies nothing, leaves the existing file alone, and
exits 1 with `Do not format the card`.

Trade-off of the size+mtime fast path: routine ingest no longer detects bit
rot in already-archived files. That is deliberate — `--verify` covers it.

### Usage

```bash
chmod +x fx3_ingest.sh
./fx3_ingest.sh <source_dir> <destination_dir>
./fx3_ingest.sh --dry-run <source_dir> <destination_dir>   # preview, writes nothing
./fx3_ingest.sh --verify <archive_dir>                     # re-hash a whole archive

# Example:
./fx3_ingest.sh /Volumes/SDCARD/PRIVATE/M4ROOT/CLIP /Volumes/MyDrive/Projects/Shoot_Name/Footage
```

Re-verifying a single archived clip by hand. Note `shasum -c` resolves the
filename in the sidecar relative to the **current directory**, not to the
sidecar's location, so you must be in the file's folder — the previously
documented `shasum -a 256 -c /path/to/clip.MP4.sha256` does not work:

```bash
cd /path/to/2026-07-20 && shasum -a 256 -c C0001.MP4.sha256
```

### Archive migration (completed 2026-07-27)

A one-off `refile_archive.sh` was written to correct archives created before
the timezone fix, and applied to `~/Movies/Projects`: 8 of 9 clips re-filed,
32 files moved, all re-verified against their checksums. The script was then
deleted at the user's request — don't go looking for it in git history, it was
never committed.

If another pre-fix archive turns up (e.g. on an external project drive that
wasn't mounted at the time), it will need re-filing: move each clip together
with its `.XML` and `.sha256` sidecars into the folder matching its
`CreationDateValue` date, then confirm with `--verify`.

### Dependencies

- `exiftool` (installed via Homebrew: `brew install exiftool`)
- `shasum` (built into macOS, no install needed)

### Development conventions

- The repo is local-only: no CI, no test suite (the user explicitly
  declined GitHub Actions and a smoke-test harness). Lint locally with
  `shellcheck fx3_ingest.sh` (already installed via Homebrew) before
  committing, and keep README.md / CLAUDE.md in sync with script changes.
- No automated tests by choice, so exercise changes by hand against a
  scratch source/destination: fresh ingest, re-run (should skip), a second
  source with a same-named but different file (should report a collision and
  exit 1), `--dry-run`, and `--verify` against a deliberately corrupted copy.
- To test against real clips without duplicating tens of GB, `cp -Rc` makes
  an instant APFS copy-on-write clone of the archive.

## Next steps / open threads

- Script handles `.MP4` clips plus their matching Sony XML sidecars
  (case-insensitive). If the user starts shooting RAW or proxy files, the
  `find ... -iname "*.mp4"` filter and folder templating will need
  extending.
- No multi-destination (simultaneous backup) cloning — the user confirmed
  they don't need this, so it hasn't been built.
- No reel/card-ID folder level. Considered and declined 2026-07-27: the FX3
  writes no usable card identifier (`serialNo` is `4294967295` = unset,
  `umidRef` is per-clip), so it would have to come from the SD volume name or
  a `--reel` flag. Collisions are caught at ingest instead. Revisit only if
  same-day multi-card shoots become routine.
- Resolve's Media Pool auto-bin step (right-click → Auto-Bin by Metadata, or
  drag folders in directly) is the intended next step after ingest, but is a
  manual step in Resolve itself, not part of this script.
