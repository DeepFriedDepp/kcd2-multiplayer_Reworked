# WO-83 progress

Read `docs/WO-83-findings.md` first — it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 — `ttac_man_9` social class | **Confirmed from `Tables.pak`**: class 101 `guard`, crime role 2. Not from log inference. |
| Phase 0 — field corroboration | **Observed**: the `ttac_man_9` ghost speaks the guard drawn-weapon bark 13×; the `ttro_man_59` ghost 0×. |
| Phase 1 — roster audit | **Done**: 7/19 crime-role-2 souls (guard ×3, soldier_crimeAuthority ×3, huntsman_crimeAuthority ×1); GuardLeader 0; the fallback soul was also a guard. |
| Phase 2 — fix | **Landed in Lua**: seven slots replaced in place, fallback moved to `ttkc_man_26`. No deletion, no reorder. |
| Phase 3 — mapping check | **Done offline**: 12 slots byte-identical, 8/8 untouched-slot keys unchanged, 6/6 affected keys reassigned to commoners. |
| Phase 3 — live spawn check | **Not done** — no running game this session. |
| Pak / `VERSION` | **Untouched** — maintainer's call. Lua is inert in the field until the pak is rebuilt. |

## What changed

`kdcmp/Data/Scripts/Startup/kdcmp.lua` only:

1. `KCD2MP.faceRoster.male` slots 1, 2, 9, 11, 12, 17, 19 now hold
   `tpod_man_1`, `tsem_man_21`, `ttkc_man_26`, `tzel_man_10`, `tvid_man_3`,
   `tvez_man_20`, `tsla_man_2` — each already in the list and REST-verified
   live in WO-69. Each row carries a `-- WO-83: was <soul> (<class>)` note.
2. `KCD2MP.faceFallback` is `ttkc_man_26` (was `ttkc_man_3`, a guard).
3. Three explanatory comments (roster header, fallback, picker) updated.

Nothing else: no protocol, relay, native, launcher or test change.

## Departure from the brief, stated

The brief said *remove* and *preserve everyone else's mapping*. With a
`% #list` picker those conflict — removal re-rolls all 19 (WO-34 did that
knowingly). In-place replacement is the only shape that keeps the mapping, so
that is what shipped; the seven souls are gone from the table either way.

The brief scoped the audit to Guard/GuardLeader. The data showed the lever is
the class's `soul_crime_role_id`, not its name (a commonFolk-faction guard
barks; a soldiers_guards-faction soldier does not), so the cut is "crime role
2", which also caught three `soldier_crimeAuthority` and one
`huntsman_crimeAuthority` soul. Same defect, same mechanism, same fix.

## Runbook for the live check (when a game is up)

1. Build and install the pak (`tools\Build-And-Install-Mod.ps1`), start a
   session, confirm `[KCD2-MP] === MOD INIT ===`.
2. Over REST on `:1403`, read
   `/api/rpg/SoulList/SoulsByName/ttkc_man_26/SharedSoulGuid` and expect
   `cfa65480-f361-4cf8-80c5-1900b7846bc8`.
3. Spawn a ghost whose key lands on slot 9 (`Host`, `Player3` or `Player4`
   all do) and expect
   `spawn verify … requested class=NPC soul=ttkc_man_26 guid=cfa65480-…`.
4. Draw a weapon next to it. Expect no
   `crime_reaction_barks.vytazena_zbran.straz_*` line with
   `Ex: kcd2mp_<id>` as the speaker, and no `combat.skirmish_barks.*__soldier`
   from the ghost.
5. To widen the roster past 12 faces, resolve any of the §3.2 candidates in
   `WO-83-findings.md` over the same REST path first, then append — never
   reorder, never shorten.

## Traps met

- **Faction string ≠ authority.** Grepping for `_soldiers_guards` /
  `_soldiers_militia` undercounts (4 vs 7) and would have kept a
  commonFolk-faction guard. Key on `soul_crime_role_id`.
- **The `extraCombatMod` warnings are boot noise** — one per social class,
  every class, lines 1,551–1,670 of the host log. They name nothing about the
  session.
- **`spawn verify … resolved soul=nil` is normal** (10/10 lines in both field
  logs). The net catches class mismatches only; it cannot vouch for a soul.
