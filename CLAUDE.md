# FX3 Media Ingest Script

## Context

This script offloads MP4 clips from a Sony FX3's SD card onto a Mac in an
organized, checksum-verified fashion, so that bins in the video editor
(DaVinci Resolve) aren't a mess on import.

### Background / tools evaluated

- **Offshoot by Hedge** — the obvious commercial answer, but an owned
  license can be incompatible with the current macOS version.
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

The script walks the card **once** into an array, resolves all dates and gyro
flags in one batched `exiftool` call, then writes a tab-separated plan file
into a `mktemp -d` scratch dir:

```
<action>\t<src>\t<dst_dir>\t<size>\t<mtime>\t<gyro>\t<reason>
```

`action` ∈ `COPY`/`SKIP`/`DUPLICATE`/`COLLISION`; `reason` is last because
it's the only free-text field. Planning happens in two stages:

1. `plan_actions` decides each file against the **destination on disk**.
2. An `awk` two-pass then resolves collisions **within the plan** — see "Name
   collisions". This is a separate stage because `plan_actions` only ever
   sees one source file at a time and structurally cannot detect two sources
   converging on one path.

Execution just walks the plan. This is what makes `--dry-run` honest, the
free-space check exact, and the progress bar reflect only real work. When
adding behaviour, decide it in the planning stages rather than mid-copy.

Bash 3.2 (system bash) — no `mapfile`/`readarray`, no associative arrays; the
plan file exists partly because of that. The intra-plan pass is `awk`
precisely because it needs associative arrays that bash 3.2 doesn't have.

### Date resolution

QuickTime `CreateDate` in an MP4 is stored in **UTC**. Reading it directly —
which the original version did — files anything shot after ~19:00 local into
the next day's folder. This misfiled 8 of 9 clips in a real archive
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
day hold different clips with identical names. This has now caused **two**
distinct silent-data-loss bugs, both found after the fact. Treat any change
in this area as high risk.

**Bug 1 — destination compared against itself (fixed in aad61f1).** The
original skip check compared the destination against its own sidecar, which
always matched, so the second card's clips were reported "Skipping
(verified)" and never copied, with exit 0. The check must compare **source
vs. destination**.

**Bug 2 — sources never compared against each other (fixed in `abdbcd2`).**
`plan_actions` examines one source file at a time against the destination on
disk, so when one source tree held two different `C0001.MP4`s heading for the
same date folder, both were planned `COPY` and the second overwrote the
first. Confirmed repro: two dirs each with a different `C0001.MP4` and the
same mtime reported `Copied & verified: 2`, left one file on disk, and exited
**0** — i.e. it actively told the operator the card was safe to format.

Resolution now happens in the `awk` intra-plan pass, keyed on
`dst_dir/basename`:

- differing size/mtime → every member becomes `COLLISION`, nothing copied,
  exit 1, reported as one grouped block naming all the source paths
- identical size/mtime → first is copied, rest become `DUPLICATE` (a card and
  a backup of it under one parent; copying once loses nothing)

Members already marked `COLLISION` by `plan_actions` are excluded from
grouping, so a source-vs-destination collision keeps its own detailed
message. Both collision kinds are distinguished at report time by matching
the reason string `"N source files map to this path"` — if you change that
wording, change it in `report_collision_groups`, the dry-run printer, and the
execute loop together.

Trade-off of the size+mtime fast path: routine ingest no longer detects bit
rot in already-archived files. That is deliberate — `--verify` covers it.

### Gyro data / Gyroflow

FX3 gyro/IMU data lives in the `rtmd` timed-metadata track **inside the
MP4**, which Gyroflow parses itself. Ingest already preserved it (the copy is
byte-exact); what was added is *detection*, so a clip that can't be
stabilized is flagged while the card is still in the reader.

`MetaFormat` rides along in the **same batched exiftool call** as the dates.
It comes from the sample description box in `moov`, so it costs nothing.
`-T` joins multiple tracks' values (`tmcd, rtmd`), hence a substring test.

**The deep check was considered and rejected**: `exiftool -ee -PitchRollYaw`
confirms the samples are actually populated, but walks the `mdat` — a second
full read of every clip, destroying the single-read property that the whole
`tee` copy design exists to protect. If it's ever wanted, run it against the
**destination** after the copy, never the card.

Do not confuse `rtmd` with `nrtm` — the latter is the Non-Real Time Metadata
that the `.XML` sidecar carries, and it holds no gyro.

Gyro state is `unknown`, not `no`, when exiftool fails outright; only `no`
warns, so a broken exiftool can't produce a wall of false alarms. **The gyro
flag must never affect the exit code** — a clip shot in a mode without IMU
data is not an ingest failure, and conflating the two would corrupt the
"safe to format the card" meaning of exit 0.

Tag names were verified against exiftool 13.55 (`Sony.pm:10837-10847`,
`QuickTime.pm:7762`) and confirmed against real FX3 footage: normally-shot
clips carry `rtmd` and are not flagged. Spot-check with
`exiftool -T -MetaFormat <clip>` if the flag ever looks wrong.

### Usage

```bash
chmod +x fx3_ingest.sh
./fx3_ingest.sh <source_dir> <destination_dir>
./fx3_ingest.sh --dry-run <source_dir> <destination_dir>   # preview, writes nothing
./fx3_ingest.sh --verify <archive_dir>                     # re-hash a whole archive
./fx3_ingest.sh --verify <archive_dir>/2026-07-20          # one date folder
./fx3_ingest.sh --verify <archive_dir>/2026-07-20/C0001.MP4  # one clip (or its .sha256)
./fx3_ingest.sh --version                                  # print version

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

### Re-filing an archive built before the timezone fix

Archives ingested before the UTC fix (commit `aad61f1`) have evening clips
filed one day late. Correcting one means moving each clip together with its
`.XML` and `.sha256` sidecars into the folder matching its
`CreationDateValue` date, then confirming the result with `--verify`. This
was done once, with a throwaway script that was not committed; if it needs
doing again, `--verify` is what proves the move was clean.

### Dependencies

- `exiftool` (installed via Homebrew: `brew install exiftool`)
- `shasum` (built into macOS, no install needed)

### Development conventions

- CI runs `shellcheck` only (`.github/workflows/shellcheck.yml`). There is
  no automated test suite by choice — the script's real behaviour is about
  filesystem state, mtimes, and interrupted copies, which is awkward to fake
  and easy to fake wrongly. Lint locally before committing
  (`shellcheck fx3_ingest.sh`), and keep README.md / CLAUDE.md / CONTRIBUTING.md
  in sync with script changes.
- Since there are no automated tests, exercise changes by hand against a
  scratch source/destination:
  - fresh ingest, then re-run (should skip everything, `Nothing to do`)
  - a second source with a same-named but different file → collision, exit 1
  - **two dirs under one parent, each with a different `C0001.MP4` and the
    same mtime** → grouped collision, nothing copied, exit 1. This is the
    regression test for bug 2 above; it is the case that silently destroyed
    a clip while reporting success.
  - two byte-identical copies (`cp -p`) under one parent → one COPY, one
    DUPLICATE, exit 0, one file on disk
  - a `._C0001.MP4` and a `SUB/C0001S01.MP4` → neither ingested, proxy
    counted in the summary
  - `--dry-run`, and `--verify` against a deliberately corrupted copy
  - `./fx3_ingest.sh src dst | tee log` → the log must contain no ANSI
    escape codes and no progress bar
- To test against real clips without duplicating tens of GB, `cp -Rc` makes
  an instant APFS copy-on-write clone of the archive.

## Next steps / open threads

- Script handles `.MP4` clips plus their matching Sony XML sidecars
  (case-insensitive). To support RAW or other Sony formats, the
  `find ... -iname "*.mp4"` filter and folder templating will need
  extending.
- Sony proxies (`SUB/C0001S01.MP4`) are now explicitly detected and skipped
  with a reported count, rather than ingested as if they were originals. If
  proxies are ever wanted, the decided-but-unbuilt option was a
  `<date>/Proxy/` subfolder so they can't be confused with the real clips.
- Known wrinkle: a clip's `.XML` sidecar is planned independently of the
  clip, so when a clip is refused as a `COLLISION` its sidecar is still
  copied, leaving a briefly orphaned `C0001M01.XML`. Not data loss, and it
  self-heals on the next run once the collision is resolved; the run exits 1
  and says not to format the card either way. Fix by having the intra-plan
  pass demote a sidecar whose clip collided, if it ever becomes annoying.
- Gyro detection is presence-only (`MetaFormat` contains `rtmd`), and
  validated against real FX3 footage. It does not confirm the samples are
  populated — see the rejected deep check above.
- No multi-destination (simultaneous backup) cloning — deliberately out of
  scope; a single destination keeps the copy path simple.
- No reel/card-ID folder level. Considered and declined: the FX3
  writes no usable card identifier (`serialNo` is `4294967295` = unset,
  `umidRef` is per-clip), so it would have to come from the SD volume name or
  a `--reel` flag. Collisions are caught at ingest instead. Revisit only if
  same-day multi-card shoots become routine.
- Resolve's Media Pool auto-bin step (right-click → Auto-Bin by Metadata, or
  drag folders in directly) is the intended next step after ingest, but is a
  manual step in Resolve itself, not part of this script.
- Same-day multi-card shoots are handled by collision detection rather than
  structurally; revisit the reel-folder question if they become routine.
