#pragma once
// WO-100 Phase 0 -- read the live Mannequin tag state. Read-only.
namespace kcdmp::mannequin {

// File-watched entry point, posted as a repeating main-thread task. No-ops
// unless kcdmp-mannequin.txt exists (game working directory first, then beside
// the DLL -- the WO-99.5 convention, because %LocalAppData% is sandbox
// redirected for the coding shell).
void tag_watch();

} // namespace kcdmp::mannequin
