#pragma once
// WO-113: end the open-world punishment gameplay cleanly after a swallowed
// execution (Game Over 44).
//
// Quests/Final/Barbora/open_world/nextnextgenpunishment.xml: a punishment sets
// the State node `disabledEvents` true (triggersequence15.C). Its SetFalse is
// wired only from playpunishment_cutscenebuffsmonolog.punishmentdone. An
// execution fires GameOver(44) at PunishmentCutscene.AfterPlay instead, so
// punishmentdone never runs; in vanilla the Game Over reload discards that.
// With 44 swallowed the State would stay true, and with it
// DisableRandomEvent(All) and the crime_playerInPunishment /
// crime_disabledFrisk game contexts -- all of which persist in saves.
//
// The reset fires that State node's own SetFalse port -- the edge the quest
// would have fired itself -- and reads the State back. Everything is resolved
// by export (ConceptModule, CrySystem) and RTTI; nothing by RVA.

namespace kcdmp::punishment {

// Idempotent. Logs one line: armed, or NOT armed and why.
bool resolve();
bool available();

// disabledEvents.State. False when unreadable (then *out is untouched).
bool in_punishment(bool* out);

// If disabledEvents is true: fire its SetFalse and read the State back.
// Returns true when the State reads false afterwards (including "was already
// false"). `was` (optional) receives the State before.
bool reset(bool* was);

// Test only (the opt-in test file): fire SetTrue, standing in for a
// punishment that has started. Returns true when the State reads true after.
bool test_set_true();

} // namespace kcdmp::punishment
