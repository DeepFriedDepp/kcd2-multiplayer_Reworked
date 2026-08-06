# WO-22 §3 — `altire-dev/kcd-toolkit`, assessed

Cloned and read 2026-08-06. Practical assessment only, as scoped.

**Verdict: not worth adopting. Current tooling is equivalent or better for
everything this project actually does.** One genuinely useful fact came out of
reading it anyway, and it is at the bottom.

## What each component does

| component | what it is | what it does |
|---|---|---|
| `kcd-pak-builder` | Python + wxWidgets GUI app | walks a directory, writes it into a `.pak` (a ZIP) with `zipfile.ZIP_DEFLATED`, splitting into `-partN.pak` files past a user-set size cap |
| `kcd-mod-generator` | Python + wx GUI | scaffolds a new mod's folder tree and writes a `mod.manifest`; bundles the modding EULA text |
| `kcd-asset-finder` | Python + wx GUI | scans a directory of game `.pak`s, indexes their entry names, and searches them by substring / not-contains / regex, then extracts matches |
| `kcd-mod-suite` | Python + wx GUI | pre-release (0.1.1) shell that wraps the three apps above in one window |
| `kcd-core` | Python library | pre-release (0.1.0) `PAKFile` / `PAKAsset` classes and pak helpers the apps share |

All five are Python, all GUI-first (`wxPython~=4.2.2`, packaged with
`pyinstaller`). There is no CLI entry point and no library API intended for
scripted use — `kcd-core` is a support library for the GUIs, not a headless
toolkit.

## Does `kcd-pak-builder` handle anything ours doesn't?

**No — and on the one point that matters it does the opposite of what this
project's own `Build-And-Install-Mod.ps1` deliberately does.**

```python
# kcd-pak-builder/kcd_pak_builder/pakbuilder.py
with zipfile.ZipFile(pak_path, 'w', zipfile.ZIP_DEFLATED) as pak_file:
```

```powershell
# tools/Build-And-Install-Mod.ps1
#   Entries are stored uncompressed, matching how the existing pak was built --
#   the game's pak loader is happier with stored entries ...
$entry = $zip.CreateEntry($rel.Replace('\','/'),
                          [System.IO.Compression.CompressionLevel]::NoCompression)
```

The only feature it has that ours lacks is **size-capped splitting into
`-partN.pak`**, which matters for multi-gigabyte texture mods and is irrelevant
to a ~100 KB Lua mod. Everything else — recursive walk, in-pak path
normalisation, deterministic output — ours already does, plus install and
deploy steps this tool has no concept of.

There is also a practical blocker: **there is no Python on this machine**
(a standing constraint in this project's notes). Adopting any of these would
mean installing a Python toolchain and wxPython to replace a PowerShell script
that already works and has no dependencies.

## Would `kcd-asset-finder` be a faster way to search the real game's paks?

**No.** It is a GUI that indexes *entry names* inside paks and matches them by
substring or regex. The searching this project actually does is
**content** search across already-extracted game data — grepping XML and Lua
text for a soul GUID, a faction name, a behaviour-tree name. `kcd-asset-finder`
does not search file contents at all.

The workflow WO-21 and WO-22 both used — decompress `Scripts.pak` /
`Tables.pak` once, then ripgrep the extracted tree — is strictly more capable
and strictly faster than a GUI filename filter. `muyuanjin/kcd2-mod-docs`
(§1) now makes even the decompression step unnecessary: it ships the extracted
trees directly.

`kcd-mod-generator` scaffolds a mod that this project generated years of work
ago. `kcd-mod-suite` and `kcd-core` are pre-release wrappers around the above.

## Recommendation

**Adopt nothing.** Keep `tools/Build-And-Install-Mod.ps1` and extracted-tree
grep. This is a "not worth changing" verdict, and it is a complete result: the
toolkit is aimed at asset/texture modders working through a GUI, which is a
different job from this project's.

If pak *splitting* ever becomes necessary (it would take a >2 GB payload), the
~40 lines of logic are trivial to reimplement in the existing PowerShell rather
than take on a Python dependency.

## The one useful finding

Reading `kcd-pak-builder` surfaced a real contradiction worth recording:

- **This project believes** KCD2 paks must be zero-compression ZIPs
  (`Build-And-Install-Mod.ps1`'s comment, "the game's pak loader is happier
  with stored entries").
- **`kcd-pak-builder`** — a community tool with tagged releases, used by
  actual mod authors — writes `ZIP_DEFLATED` unconditionally.
- **The Nexus aggression mod in §2** — a published, working mod — ships its
  single table XML as `Defl:N`, 70% compressed.

Two independent data points say deflate loads fine, at least for `Libs/Tables`
XML. That does **not** mean it is safe for every asset class (streamed assets
and textures are the usual suspects for a stored-only requirement, and neither
data point covers those), and it is **not a reason to change our build** —
NoCompression is working, costs nothing at this file size, and is the
conservative choice. But the comment in `Build-And-Install-Mod.ps1` states this
more strongly than the evidence supports, and that is worth softening if anyone
ever touches it.

## Licensing

**The repository ships no LICENSE file.** With no licence granted, the default
is all-rights-reserved: nothing from it may be copied into this repo. Nothing
was, and the verdict above means nothing needs to be. The README invites
contributions but does not license the code. Any future reuse would need the
author asked directly.
