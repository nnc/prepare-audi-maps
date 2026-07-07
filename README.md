# prepare-audi-maps

A macOS command-line utility that prepares a USB flash drive for **Audi / VW MIB2**
navigation map updates from an official map package ZIP
(e.g. `HIGH2_P450_EU_202625.zip`).

It verifies the package, formats the drive the way the MMI expects
(MBR + FAT32), copies the package to the USB root, and — critically —
strips all macOS metadata that is known to make MIB2 head units reject the
drive.

FAT32 is the default because MIB2 units read it reliably; some head units
ignore ExFAT drives entirely (symptom: *"no update available"*, as if the
port were empty). Pass `--exfat` only for a package containing a file larger
than FAT32's 4 GB limit — the script refuses such a package on FAT32 and
tells you.

## Is this for you?

Use this if **all** of these are true:

- You are on **macOS** (Ventura or newer) and want to write a USB stick for an
  **Audi or VW MIB2** navigation map update.
- You already have an **official map package ZIP** (e.g.
  `HIGH2_P450_EU_202625.zip`, containing `metainfo2.txt` + `Mib1`/`Mib2`).
- The car **won't accept a stick you prepared on a Mac** — it says *"no update
  available / found"*, doesn't detect the USB at all, or aborts mid-update.

The usual causes, both of which this tool fixes:

1. **macOS metadata.** Finder/Spotlight silently write hidden files (`._*`,
   `.DS_Store`, `.Spotlight-V100`, `.fseventsd`) onto the drive; the MMI's
   strict updater chokes on them or fails its checksum against `metainfo2.txt`.
2. **Wrong filesystem.** Sticks formatted ExFAT (or GPT-partitioned) are
   ignored by many MIB2 units. The MMI expects **FAT32 + MBR**.

The tool formats the drive as FAT32 + MBR, copies the package to the root, and
strips the macOS metadata (including the extended attributes macOS otherwise
rewrites at eject) so the update is recognized.

**This tool does _not_:** source, download, generate, or unlock map data — you
bring your own legally-obtained package. It is built and tested for **MIB2**
(High and Standard); other head-unit generations (MIB1-only cars, MIB3) use a
different update flow. Windows/Linux are out of scope — use it on a Mac.

```
===========================================
 Audi / VW MIB2 Map USB Creator
 Version 1.1.0
===========================================
==> Map package: /Users/you/Downloads/HIGH2_P450_EU_202625.zip
✓ ZIP verified
SHA-256: 47fc53…
✓ Package structure detected

Package summary
  Region:   Europe
  Contains:
    ✓ metainfo2.txt
    ✓ Mib1
    ✓ Mib2

Detected USB drives:
  1) Kingston DataTraveler 3.0  (disk4)
     Volume:     AUDIUSB
     Filesystem: ExFAT
     Capacity:   61.9 GB
```

## Requirements

- macOS 13 Ventura or newer (Sonoma, Sequoia and later work; Intel and
  Apple Silicon are both supported).
- Only stock system tools are used: `zsh`, `diskutil`, `plutil`, `unzip`,
  `rsync`, `shasum`, `dot_clean`, `mdutil`. No Homebrew dependencies.
- A USB drive at least as large as the unpacked map package (16–64 GB
  depending on region).
- Free space on the boot volume (or `$TMPDIR`) for the extracted package.

## Installation

```sh
git clone https://github.com/nnc/prepare-audi-maps.git
cd prepare-audi-maps
chmod +x prepare-audi-maps.zsh

# optional: put it on your PATH
ln -s "$PWD/prepare-audi-maps.zsh" /usr/local/bin/prepare-audi-maps
```

## Usage

```sh
# interactive — the script asks for the ZIP (drag & drop works)
./prepare-audi-maps.zsh

# direct — relative or absolute path, quotes and spaces are fine
./prepare-audi-maps.zsh HIGH2_P450_EU_202625.zip
./prepare-audi-maps.zsh "~/Downloads/HIGH2_P450_EU_202625.zip"
```

| Option | Effect |
| --- | --- |
| `--verify-copy` | After copying, re-compare source and USB with checksums (`rsync -c`). Reads every byte twice; slow but airtight. |
| `--dry-run` | Validate the ZIP, show detected drives and the plan; change nothing. |
| `--skip-format` | Keep the existing volume (must already be FAT32 or ExFAT). |
| `--exfat` | Format as ExFAT instead of FAT32. Only needed for a package with a file over FAT32's 4 GB limit; most MIB2 units prefer FAT32. |
| `--no-eject` | Leave the drive mounted when finished. |
| `-v`, `--verbose` | Extra diagnostics. |
| `-q`, `--quiet` | Only warnings, errors and prompts. |
| `-h`, `--help` | Help. |
| `--version` | Version. |

Every run appends to `prepare-audi-maps.log` in the current directory
(ZIP path, SHA-256, selected disk, timestamps, errors).

### What a run does

1. Tests the ZIP with `unzip -t` and prints its SHA-256.
2. Locates `metainfo2.txt` inside the archive — at the ZIP root or inside a
   single wrapper directory — **before** extracting, so a wrong file fails in
   seconds, not after a 30 GB extraction. Anything else is rejected.
3. Extracts to a temporary directory (removed automatically, also on Ctrl-C).
4. Detects USB drives via `diskutil`'s plist output (no fragile text
   parsing) and shows a numbered menu: volume, filesystem, capacity, disk id.
5. Asks you to type `YES`, then erases the drive as **MBR + FAT32** (or
   ExFAT with `--exfat`) and verifies the resulting partition scheme and
   filesystem.
6. Disables Spotlight indexing (`.metadata_never_index`) and suppresses the
   filesystem-events journal (`.fseventsd/no_log`) before any data lands.
7. Copies with `rsync` (progress shown, timestamps preserved; re-running
   resumes an interrupted copy).
8. Removes all macOS metadata: runs `dot_clean`, clears extended attributes
   (`xattr -rc`), and deletes `.DS_Store`, `._*`, `.Spotlight-V100`,
   `.Trashes`.
9. Verifies `metainfo2.txt` sits at the USB root with no wrapper folder,
   lists the root, optionally checksum-verifies (`--verify-copy`), and ejects.

### Installing in the car

Insert the USB into the car's USB port (MIB2 High: glovebox / centre
console), then: **MENU → Setup MMI → System maintenance → System update →
Update from USB**. Keep the engine running or a charger connected; large
updates take 30–60 minutes.

## Examples

```sh
# the works: format, copy, clean, checksum-verify, eject
./prepare-audi-maps.zsh --verify-copy ~/Downloads/HIGH2_P450_EU_202625.zip

# see what would happen without touching anything
./prepare-audi-maps.zsh --dry-run HIGH2_P450_EU_202625.zip

# drive already formatted, just refresh the files
./prepare-audi-maps.zsh --skip-format HIGH2_P450_EU_202625.zip

# boot disk too small for the extracted package? extract elsewhere
TMPDIR=/Volumes/BigDisk/tmp ./prepare-audi-maps.zsh HIGH2_P450_EU_202625.zip
```

## Why macOS metadata breaks Audi MMI updates

MIB2 units run a QNX-based firmware whose updater scans the drive for
`metainfo2.txt` and then reads the package with a strict, simple parser.
macOS, however, decorates every volume it touches:

- **`.DS_Store`** — Finder view settings, written into every browsed folder.
- **`._*` (AppleDouble) files** — ExFAT/FAT32 can't store extended
  attributes or resource forks, so macOS writes them as hidden `._name`
  companion files next to the real ones.
- **`.Spotlight-V100`** — the Spotlight search index.
- **`.fseventsd`** — the filesystem-events journal, (re)written at eject.
- **`.Trashes`** — per-volume trash.

The updater either chokes on these unexpected entries during package
enumeration or fails its signature/checksum validation because the file set
no longer matches `metainfo2.txt`. The symptom is always the same: the MMI
says *"No update found"* or aborts mid-update.

This tool removes all of the above **after** copying, and additionally
plants two harmless guard files (`.metadata_never_index` and
`.fseventsd/no_log`) that stop macOS from re-creating its metadata when the
drive is ejected. MIB2 units ignore these.

Two subtleties, found by testing on macOS Tahoe, drive the implementation:

- Deleting `._*` files is not enough. macOS keeps the underlying extended
  attributes (e.g. `com.apple.provenance`) cached and **writes them back as
  fresh `._` files at eject**. The tool therefore clears the xattrs
  themselves (`xattr -rc`) as the final write, which verifiably keeps the
  volume clean across an eject cycle.
- `mdutil -i off` is deliberately **not** used: on current macOS it *creates*
  `.Spotlight-V100` (to store the disabled flag), and on FSKit-mounted exFAT
  volumes that directory cannot be deleted without root. Planting
  `.metadata_never_index` before any file lands prevents the index from ever
  being created in the first place.

## Troubleshooting

**No USB drives detected**
- The script only lists *external, physical, USB* whole-disks. Direct-plug
  the drive; some hubs and SD readers enumerate differently.
- Check the drive appears in `diskutil list external physical`.
- The script offers a rescan prompt — replug and press Enter.

**`eraseDisk` fails with "restricted by Sandbox" (-69464)**
- Recent macOS requires the terminal app to hold the *Removable Volumes*
  permission before it may erase external drives. Enable it under
  System Settings → Privacy & Security → Files & Folders → your terminal
  app, or grant it Full Disk Access (apps with Full Disk Access show no
  separate Removable Volumes toggle — that's expected).
- The grant only applies to processes started afterwards: **quit the
  terminal app completely (Cmd+Q) and reopen it**, then re-run. A tab or
  window opened before the grant keeps the old permissions.
- Still blocked? Erase once by hand and skip the format step:
  `sudo diskutil eraseDisk FAT32 AUDIMAPS MBR diskN`, then re-run this
  tool with `--skip-format`. (Or format in Disk Utility: View → Show All
  Devices → select the device → Erase → MS-DOS (FAT), Master Boot Record.)

**`eraseDisk` fails otherwise**
- Something is holding the volume (Spotlight, antivirus, an open Finder
  copy). Wait a few seconds and retry; replug the drive if it persists.
- Very old/failing sticks can't be partitioned — try another drive.

**`.Spotlight-V100` is on the drive and won't delete**
- Something (often a manual `mdutil -i off`) created it; on FSKit exFAT
  mounts it is root-protected. Reformat with this tool — the
  `.metadata_never_index` guard stops it from coming back.

**The car says "No update found" / "no update available"**
- If the car reacts to the stick but reports no update: the package
  region/version must match what your MMI firmware accepts — a P450 (MIB2
  High) package will not install on MIB2 Standard, and some units require
  activation (FeC) for newer map releases.
- If the car does **not see the stick at all** (as if the port were empty):
  the drive is almost certainly **ExFAT** — reformat as **FAT32** (the
  default; drop `--exfat`). Confirmed on a MIB2 High that ignored a 64 GB
  ExFAT stick but read the identical package on the same stick as FAT32.
- Confirm `metainfo2.txt` is at the USB **root** (the script verifies this).
- Try the other USB port; some cars only update from one of them.

**Copy is slow**
- USB 2.0 ports and cheap sticks write at 5–15 MB/s; a 25 GB package can
  take an hour. Use a USB 3.0 stick in a USB 3.0 port.

**Not enough temp space**
- Extraction needs the unpacked package size in `$TMPDIR`. Point it at a
  bigger volume: `TMPDIR=/Volumes/BigDisk/tmp ./prepare-audi-maps.zsh …`

## Known issues

- ShellCheck does not parse zsh, so the script cannot be machine-checked by
  it; the code follows ShellCheck-clean practices (full quoting, no word
  splitting, explicit error handling) and is syntax-checked with `zsh -n`.
- macOS 15.4+ ships `openrsync` in place of classic rsync. The script only
  uses flags both implementations support; if you installed rsync via
  Homebrew, that one is used instead (first in `PATH`) and also works.
- `--skip-format` uses the drive's *first* partition. Multi-partition
  layouts are unusual on map USBs; reformat (default mode) if in doubt.
- The MMI itself may reject GPT-partitioned drives; the script formats MBR
  and warns if `--skip-format` finds GPT.

## License

[MIT](LICENSE)
