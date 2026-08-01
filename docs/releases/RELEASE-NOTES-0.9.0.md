# KCD2 Multiplayer — 0.9.0

> **Label note, added 2026-07-31.** This file was committed at the repo root
> as `RELEASE-NOTES-0.8.5-Beta.md`. `VERSION` never held `0.8.5-Beta`: its real
> history is `0.8.0` (`5447c34`) → `0.9.0` (`4fd2ff8`, the armor-sync work
> these notes describe) → `0.9.1` (`10ad471`). Renamed to the version it
> actually shipped under and moved here; nothing below changed except the
> version strings and link paths that were wrong. The update-zip filename it
> names is left as-is because that is genuinely what was hand-built at the
> time — from `0.9.2` onward the update zip is
> `KCDMP-DirectInstall-<version>.zip`, produced by
> `tools\Build-DirectInstall.ps1`. See [docs/VERSIONING.md](../VERSIONING.md).

## New things

- **Ghosts now mirror your real equipped outfit.** Swap your boots, armor,
  helmet, or your whole loadout mid-game, and your friend sees it change on
  you — not one fixed costume anymore. Updates automatically within a few
  seconds of a real change.
- **New console command: `mp_sync_appearance`** — forces an immediate
  outfit resync if you don't want to wait for it to catch up on its own.

Everything else carries over unchanged from 0.8.0 — see the main
[README](../../README.md) for the full feature list and current status.

## Already installed 0.8.0? Update in 2 steps — no reinstall needed

Everyone you play with needs this update, not just the host — an old and a
new version won't connect to each other.

Download **`KCDMP-Update-0.8.5-Beta.zip`** from this release, then:

1. Copy the **`App`** folder's contents into your existing install folder
   (`%LocalAppData%\KCDMP` — paste that into Explorer's address bar),
   overwriting when asked.
2. Copy the **`Mod`** folder's contents into your game's mod folder
   (`<your KCD2 Modding Tools folder>\Mods\kdcmp`), overwriting when asked.

That's it — no need to run Setup.exe again, and nothing else on your PC is
touched. (Prefer a full reinstall instead? The `KCDMP-Setup-*.exe` in this
release does that too.)
