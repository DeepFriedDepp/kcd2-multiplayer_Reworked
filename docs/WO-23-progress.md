# WO-23 progress — auditing every open limitation against `kcd2-mod-docs`

Session run 2026-08-06. Desk audit only — the game was not running
(`localhost:1403` unreachable), and the human chose to proceed without it
rather than pause to launch KCD2. Nothing shipped was changed.

## Method

Applied WO-22's technique systematically: for each open limitation, identify
the exact call/assumption behind it, then check it against Warhorse's real
shipped scriptbind docs, the extracted `Scripts.pak`/`Tables.pak`, and the
Skald function schema (`d_definitions.xml`) for a parameter-shape mismatch or
a documented alternative — before falling back to general browsing.

Source repo: the `muyuanjin/kcd2-mod-docs` clone WO-22 already made, recovered
from a prior session's scratchpad (path in `WO-23-findings.md`'s header — that
directory belongs to an expired session and will not persist).

## Coverage

All six priority items investigated. Priority order followed as instructed;
no item skipped.

| item | result |
|---|---|
| 1. `HasMeleeWeapon` | Session prompt's premise already stale (WO-21 fixed it pre-WO-22). No call-shape mismatch found. Found a real bug: `kdcmp.lua:1404-1410`'s comment still states the disproven WO-17 claim. |
| 2. Female gear | Checked `Libs/Tables/item/item.xml` + `item.xsd` directly: no gender-pairing table exists in the shipped schema, and Warhorse never authored female combat armor at all. WO-20's limitation confirmed structurally impossible to fix via a lookup table, not just "not attempted." |
| 3. Soul-row hostility (WO-22 lead C) | Partially validated by WO-22's own existing evidence (hostile soul + proxy already drew real aggro, no native attach). The specific shippable combination — hostile soul, no proxy — is the one untested cell. Flagged for live follow-up. |
| 4. `HasCombatHistoryWithSoul` | Session prompt's premise was stale: the native in-process escalation it asked for was already done, in commit `00360a2`, before WO-15. Confirmed negative, correctly escalated, signature matches Skald docs exactly. Closed. |
| 5. Dice native UI | **New finding.** `script_bind_2025_01_14/` documents a full `C_ScriptBind_Dice` Lua scriptbind surface (`Dice.SetScore`, `Dice.OverrideNextThrow`, `Dice.RollDie`, etc.) that is architecturally separate from the RTTR-reflection surface WO-6 found closed. Never checked for liveness in this build. Flagged as the strongest lead this session produced. |
| 6. Sweep | Voice chat/launcher/sessions: no lever to check, correctly out of scope. Menu-freeze: one shallow, unconfirmed possibility (`Entity:SetTimer` vs `Script.SetTimer`) surfaced by name search only, explicitly not trusted. |

## What's fixed

Nothing. This was a pure investigation WO, same as WO-22's non-brain sections.

## What's a promising, flagged, untested lead for the next session

1. **`Dice` Lua scriptbind liveness** (item 5) — check `type(Dice)` and
   `type(Dice.SetScore)` first, before any further overlay-UI work.
2. **Hostile soul, no `SchedulerProxyName`** (item 3) — the one untested cell
   in WO-22's own aggro matrix; would replace the native `SetParent` mechanism
   if it holds.
3. **`AI.AddPersonallyHostile`/`AI.SetAttentiontarget` on a soul-backed ghost**
   (item 1) — WO-22's own flagged follow-up, still unanswered.

All three need the game running and a human present, per this project's own
standing practice.

## Files touched

- `docs/WO-23-findings.md` (new)
- `docs/WO-23-progress.md` (this file, new)

No changes to `kdcmp.lua`, `native/`, `dotnet/`, `VERSION`, or the installer.
