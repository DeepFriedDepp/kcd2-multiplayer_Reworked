#pragma once
// WO-124: the engine's cached save list, for the joiner's transient world file.
//
// The game lists saves once and wh_sys_LoadGame resolves only against that
// list (WO-112 s3.5: a file copied in after startup is invisible). The menu's
// own flows rescan it (GUIModule calls UpdateSaveGameDescriptions before
// Continue and when it picks the current playline); this does the same, then
// answers "is this file listed" and "what would Continue load".
//
// Every piece is an export of Framework.dll (C_PlayerProfileWHManager and
// C_SaveGameDescription), plus two anchored offsets, each failing closed:
//   manager      GetGameIface()->[off]; off is lifted from WHGame's own
//                Game.AddSaveLock scriptbind ("call GetGameIface; mov rcx,
//                [rax+off]; ... call AddScriptSaveLock")
//   file name    C_SaveGameDescription+off (CryString base name); off is
//                lifted from the exported GetFilePath's first field read
// Main thread only (the menu and the loader use the same list); the pipe
// marshals it (0x1D -> 0x8D). Observed: the plugin's tick and pipe run at the
// main menu on 1.5.5, where the joiner needs this.

#include <cstdint>

namespace kcdmp::savelist {

bool resolve();
bool ready();
const char* why_not();

struct Report {
    bool ok = false;           // the list was read
    bool listed = false;       // `name` is in `playline`
    int  idx = -1;             // its description index
    int  count = 0;            // descriptions in `playline`
    int  current = -1;         // the manager's current playline
    int  contPlayline = -1;    // what Continue would load: GetNewestSavedGameFromPlayline(current)
    int  contIdx = -1;
    char contName[64]{};
};

// UpdateSaveGameDescriptions, then find `name` (base name, no .whs) in
// `playline` and read Continue's pick. `rescan` false = read only.
Report query(bool rescan, int playline, const char* name);

// Opt-in research trigger (kcdmp-savelist-test.txt in the game's working
// directory, polled from the tick once a second): "list <pl>",
// "find <pl> <name>", "continue". Absent file = idle.
void test_watch();

} // namespace kcdmp::savelist
