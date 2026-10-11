# camera-card-importer

Plug in a camera SD card on Windows and the photos move themselves into a dated
library folder. Nothing to click.

```
Canon  ->  %USERPROFILE%\CameraImports\Canon\2026\Sep-10\
GoPro  ->  %USERPROFILE%\CameraImports\GoPro\2026\Sep-06\DCIM\100GOPRO\   (1:1 mirror of the card)
```

It is a background watcher plus a verified-move engine, written in Windows
PowerShell 5.1 with **no external dependencies** — no exiftool, no Python, no
modules to install. The metadata parsers are hand-rolled against the file
formats, for reasons explained below.

Two rules drive the whole design:

1. **A card that holds no camera media is left completely alone.** No folder is
   created, nothing is deleted, nothing is imported. Plugging in a card full of
   3D-printer gcode touches neither the card nor the library — the watcher just
   says so and stops (see *Notifications*).
2. **Nothing is deleted from a card until its copy has been hash-verified on
   disk.** A failed verification aborts that file and leaves the card untouched.

---

## Contents

| File | Role |
|---|---|
| `MediaLib.ps1` | EXIF / ISO-BMFF parsers, card identification, verified copy. Dot-sourced; defines functions only. |
| `Import-CameraMedia.ps1` | The engine: scan, classify, date, group, copy, verify, delete. |
| `Watch-CameraDrives.ps1` | Background watcher that reacts to volume arrival. |
| `Install-CameraWatcher.ps1` | Installs/removes the watcher as a startup item. |

---

## Install

```powershell
git clone https://github.com/MikeMontana1968/camera-card-importer.git
cd camera-card-importer
.\Install-CameraWatcher.ps1
```

That writes a launcher to your Startup folder and starts the watcher immediately —
no logout required. Defaults put Canon media in `%USERPROFILE%\CameraImports\Canon`
and GoPro in `%USERPROFILE%\CameraImports\GoPro`.

> **Why not `Pictures\`?** An earlier version imported into
> `%USERPROFILE%\Pictures\Canon`, which was a mistake worth explaining. When the
> Pictures known folder is redirected to OneDrive — the default on many Windows 11
> installs — `%USERPROFILE%\Pictures` is a *different, ordinary* directory from the
> one Windows calls "Pictures". Imports landing there are invisible in Explorer's
> sidebar, in the Photos app, and in every "open Pictures" dialog, because all of
> those follow the known folder to OneDrive. Worse, a desktop shortcut to that path
> silently opens the OneDrive folder instead: a `.lnk` to a known-folder path stores
> a folder ID that takes precedence over the literal string it was given.
> Importing into a directory that shadows a known folder is a trap. `CameraImports\`
> has no such collision. Point `-CanonRoot`/`-GoProRoot` anywhere you like.

To remove it:

```powershell
.\Install-CameraWatcher.ps1 -Uninstall
```

### Options

Every switch below works on both `Install-CameraWatcher.ps1` (persisted into the
startup item) and `Import-CameraMedia.ps1` (one-off).

| Switch | Effect |
|---|---|
| `-CanonRoot <path>` | Where Canon media goes. |
| `-GoProRoot <path>` | Where GoPro media goes. |
| `-KeepOriginals` | Copy instead of move; the card is not modified at all. |
| `-Eject` | Eject the card after a clean import. |
| `-Quiet` | No console output and no toasts; the log is still written. |

### Manual runs

```powershell
.\Import-CameraMedia.ps1 -Drive D: -WhatIf     # show the plan, change nothing
.\Import-CameraMedia.ps1 -Drive D:             # import one card
.\Import-CameraMedia.ps1                       # every removable drive
```

`-Drive` accepts any directory, not just a drive letter, which is handy for
testing against a copied card image.

Log: `%LOCALAPPDATA%\CameraImport\import.log`

> **If you ever find `import.log.locked` next to it**, another process was holding
> the main log open and entries were diverted there so they would not be lost.
> Windows denies the append outright, and an earlier version swallowed that error
> silently — which made a locked log look exactly like an idle watcher, twice.
> Writes are now retried briefly before diverting, and the watcher raises a toast
> the first time it happens. Close whatever has the file open (an editor, a
> `tail -f`, a backup or AV scanner) and logging resumes on its own.

---

## How a card is identified

Identification happens in two stages, and the order matters.

**Stage 1 — root markers.** Reading a few filenames in the card root is far
cheaper than opening every file, and for GoPro it names the exact camera:

| Vendor | Evidence |
|---|---|
| GoPro | `Get_started_with_GoPro.url`, `MISC\version.txt`, `DCIM\###GOPRO` |
| Canon | `DCIM\###CANON`, `DCIM\EOSMISC`, volume label `EOS_DIGITAL` / `CANON*` |

`MISC\version.txt` gives model and firmware directly:

```
GoPro HERO6 Black (fw HD6.01.02.10.00)
  via Get_started_with_GoPro.url, MISC\version.txt, DCIM\100GOPRO
```

> **Gotcha:** that file *looks* like JSON but has a trailing comma before the
> closing brace, so `ConvertFrom-Json` dies with `Invalid JSON primitive`.
> The fields are pulled out with a regex instead.

**Stage 2 — per-file EXIF, which overrides stage 1.**

This is not belt-and-braces; the prior really is wrong sometimes. The Canon card
this was first built against had been through several cameras and a Mac. Its root
advertised Sony (`MP_ROOT\`, `AVF_INFO\`), its DCIM contained folders named
`212CASIO` and `214MSDCF` — and every single photo on it was Canon, sitting in
the *Sony-named* folder. Folder names are decoration. EXIF `Make` is the fact.

So root markers are used to classify files that carry no metadata of their own —
MP4s, proxies, thumbnails — while any file with a readable `Make` decides for
itself. Files that match neither are skipped and reported, never moved.

---

## How capture dates are decided

Folders are named for when the shutter fired, not when the file was written:

1. EXIF `DateTimeOriginal`, then `CreateDate`, then `ModifyDate`.
2. For video, the `mvhd` creation time from the MP4 container.
3. For a movie with no usable container date, its `.THM` sidecar's EXIF.
4. Only as a last resort, the filesystem timestamp.

File timestamps are genuinely unreliable. On the first card tested, one JPEG's
`LastWriteTime` read 3:37 PM while its EXIF capture time was 2:13 PM — something
had touched the file after the camera wrote it. Sorting by file time would have
filed it under the wrong session, and on a late-evening shot, the wrong day.

---

## GoPro: a 1:1 mirror of the card

GoPro cards are not sorted, grouped or filtered. The card's `DCIM` tree is
reproduced exactly, under a single day folder:

```
D:\DCIM\100GOPRO\G0010001.JPG   ->   GoPro\2026\Sep-06\DCIM\100GOPRO\G0010001.JPG
D:\DCIM\101GOPRO\GH010123.MP4   ->   GoPro\2026\Sep-06\DCIM\101GOPRO\GH010123.MP4
```

- **Every file under `DCIM` is taken**, whatever its extension or name -- including
  `.LRV`/`.THM` proxies -- so nothing is left behind or deleted unseen.
- **No regrouping.** Folder and file names are untouched; time-lapse frames and
  video chapters stay exactly where the camera put them.
- **One day folder per card**, named for the card's *earliest* capture time, so a
  time-lapse that runs past midnight is not split across two days.

Canon cards still sort into one folder per capture day.

---

## Why the parsers are hand-rolled

Reading `Make` and `DateTimeOriginal` on Windows without dependencies is harder
than it sounds:

- **`System.Drawing` cannot open CR2 or CR3.** It handles JPEG and little else
  of interest here.
- **The Windows property system needs a vendor raw codec installed** per camera
  model, so `Shell.Application` "Date taken" silently returns nothing on a
  machine without Canon's codec pack.
- **Neither can tell you the vendor of an MP4 at all.**

So `MediaLib.ps1` parses the containers directly:

| Format | Approach |
|---|---|
| JPEG | Walk marker segments to the `APP1`/`Exif` block, then parse TIFF IFDs. |
| TIFF / CR2 / GPR | TIFF header at offset 0. |
| CR3 / HEIF | Locate the `CMT1` box; EXIF lives immediately after it. |
| MP4 / MOV / 360 | Walk ISO-BMFF boxes to `moov`, read `mvhd`, scan for a vendor string. |

Every read is bounds-checked and returns `$null` on malformed input rather than
throwing — a corrupt file should be skipped and reported, not abort an import.

The MP4 walker **seeks** through 8-byte box headers instead of reading the file.
That matters: GoPro writes `moov` at the *end* of the recording, so a
head-oriented parser finds nothing in a 4 GB clip, while a tail-oriented one
fails on cameras that front-load it. Walking the box list handles both and reads
only kilobytes either way.

---

## The verified move

For each file:

1. Copy to a temp name in the destination, computing SHA-256 **inline over the
   single read of the card**. Card reads are the slow part; hashing the source
   separately would double them.
2. Re-hash the written file from disk.
3. If the hashes differ, delete the temp file, log an error, and **leave the
   source alone**.
4. Look for a byte-identical copy already in the library — searching the target folder
   (and one level of subfolders beneath it).
   A match means already imported: delete the source, count it as a duplicate.
   A file of the same name but different bytes at the target keeps both, with a
   `_1` suffix.
5. Restore the original timestamps, then delete the source.

Re-inserting an already-imported card is therefore a safe no-op rather than a
second copy.

---

## The watcher

`Watch-CameraDrives.ps1` blocks on a WMI indication:

```sql
SELECT * FROM Win32_VolumeChangeEvent WHERE EventType = 2 OR EventType = 3
```

On every wake it **rescans all removable drives** rather than trusting the event
payload, so a drive whose letter appears late, or that arrives during a hiccup,
is still caught. The 15-second wait timeout doubles as a safety poll.

Volumes are remembered by serial number while they remain plugged in, so a card
is imported once per insertion, and a non-camera drive is examined once and then
ignored — no repeated scanning. Pulling the card forgets it, so reinserting works.

A freshly mounted card can report a drive letter before its tree is browsable, so
the watcher retries for up to 12 seconds before concluding there is no `DCIM`.

A named mutex keeps a single watcher per logon session.

### Notifications

Every removable volume produces a two-stage announcement, then the importer adds
a third toast if it actually moved anything:

| stage | raised by | when | example |
|---|---|---|---|
| 1 | watcher | any removable volume arrives | **Drive detected** — `E: (EOS_DIGITAL)` |
| 2a | watcher | no `DCIM` folder at all | **No camera media** — nothing to import |
| 2b | importer | `DCIM` scanned and it holds media | **Canon card** — importing 71 file(s), 187 MB… |
| 2c | importer | `DCIM` scanned and it holds nothing usable | **No camera media** — nothing to import |
| 3 | importer | import finished with files moved or errors | **Canon EOS 70D** — 71 files, 187 MB |

Stage 2b is raised **after** the file scan, not on the mere presence of `DCIM`.
A drive can carry a `DCIM` folder full of things no camera wrote, and announcing
an import that then does not happen is worse than announcing it a moment later.
That is also why 2a and 2c both exist: the watcher can rule out a card cheaply
when there is no `DCIM`, but only the importer can tell that a `DCIM` is empty of
media, and either way you get told.

The vendor in stage 2b still comes from root markers — a prior, not a verdict.
Per-file EXIF decides where files actually land, so a card carrying stale markers
from another camera can toast one name and file under another. The file count and
size in that toast are real, though: they come from the completed scan.

A balloon belongs to its `NotifyIcon` and dies when the icon is disposed, so the
dwell is also how long `Show-Toast` blocks. Detection toasts therefore use a short
2.5 s dwell, adding about 5 s before an import starts; the completion toast keeps
the original 6 s. `-Quiet` silences all of them.

### Why a Startup item and not a Scheduled Task

A Scheduled Task would be the better home — it can restart on failure — but
`Register-ScheduledTask` returns *Access is denied* without elevation on a
standard Windows 11 install. The installer writes a `.vbs` launcher to the
Startup folder instead, which needs no elevation. VBScript rather than a `.lnk`
because `WScript.Shell.Run(cmd, 0, False)` starts the process with genuinely no
window; a shortcut to `powershell.exe` flashes a console for a moment.

---

## Adding a camera

Vendors are table-driven. Add an entry to `$script:Profiles` in
`Import-CameraMedia.ps1`:

```powershell
[pscustomobject]@{
    Name        = 'Nikon'
    Root        = $NikonRoot
    MakePattern = 'nikon'                       # matched against EXIF Make
    NamePattern = '^(DSC|_DSC)_?\d+$'           # for files with no metadata
    StillExt    = @('.jpg', '.nef')
    OtherExt    = @('.mov', '.mp4')
    Mirror      = $false                        # $true = copy the card's DCIM tree 1:1
}
```

Then add its root markers to `Get-CardIdentity` in `MediaLib.ps1`. `Mirror = $true`
takes every file under `DCIM` and reproduces its folder layout, as GoPro does.

---

## Verified against

| Card | Result |
|---|---|
| Canon EOS 70D, 32 GB (`EOS_DIGITAL`) | 18 files / 251 MB → 3 date folders, 0 errors |
| GoPro HERO6 Black, 64 GB | 830 files / 1.5 GB → 2 date folders → `G001`, 0 errors, 65 s (pre-mirror layout) |
| 8 GB card of 3D-printer gcode | ignored; nothing created, card byte-identical |

The Canon card was the useful one: mixed `100CANON` / `213CANON` / `212CASIO` /
`214MSDCF` folders, macOS `.Spotlight-V100` and `._` resource forks, a Dropbox
sync artifact, and file timestamps that disagreed with EXIF. Most of the rules
above exist because of something that card did.

The MP4 branch — `mvhd` dating and the 1:1 mirror — is implemented
and unit-exercised but has **not** yet been run against real GoPro video, only
against stills. One open question for that first run: whether the HERO6 writes
`mvhd` creation time as UTC or local, since a wrong assumption shifts
evening clips into the next day's folder.

---

## Requirements

Windows PowerShell 5.1 (ships with Windows 10/11). No modules, no admin rights.
