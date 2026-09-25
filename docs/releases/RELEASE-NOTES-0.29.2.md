# KCD2-MP 0.29.2 — NPCs the host killed stay dead

Everything on `main` as of WO-122 (2026-09-25). **No installer for this
version:** it is a source step towards the shared world, not a package.
Testers stay on `KCDMP-Setup-0.29.0.exe` until the next installer.

**Both machines and the relay must run the same build.** The protocol is
still **v8**, but the relay refuses a release mismatch, so a 0.29.2 machine
and a 0.29.0 machine turn each other away at the handshake.

**Verified solo:** one machine, a synthetic partner through a real local
relay. Nothing here has run two-player yet. The numbers are in
`docs/WO-122-findings.md`.

---

## An NPC the host killed stays dead on your screen

- If the host kills an NPC, it now dies on your screen too, even when your
  copy was still alive: after you reload, or if you arrived after it died.
- The body is put where it lies in the host's world.
- It only goes one way: nothing that is dead on your screen comes back to
  life because of the host.
- `mp_owner_death off` goes back to the 0.29.0 rule (only a death seen
  happening on the stream). `mp_preset_legacy` also turns it off.

## Groundwork for the shared world (off by default)

Nothing below does anything unless you type `mp_shared_world on`. With it
off, both machines save exactly as in 0.29.0.

- **Only the host saves.** On the joiner, saving is locked for the session:
  Save Game and Save & Quit are greyed out in the menu, and a refused save
  says "The host saves this world." The lock comes back after every load and
  goes away when the session ends.
- **The host autosaves** every `mp_autosave_minutes` (default 5, 0 = never)
  at a moment the game picks, and tells the joiner each time it saves.
- **`mp_world_save`** (host) writes a save of the world now and reports the
  file.
- The agent can read, check and splice save files itself
  (`KcdMpClient --save-tool verify|splice|check`), for the join that comes
  next.

## Known

- Each world save stalls the game for about 0.4 s (early game, measured).
  Late game: not measured yet.
- Not tested yet with the lock on: drinking Saviour Schnapps, sleeping, quest
  saves.
