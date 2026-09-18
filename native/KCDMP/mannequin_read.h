#pragma once
// WO-100 Phase 0 -- read the live Mannequin tag state. Read-only.
#include <cstdint>

namespace kcdmp::mannequin {

// File-watched entry point, posted as a repeating main-thread task. No-ops
// unless kcdmp-mannequin.txt exists (game working directory first, then beside
// the DLL -- the WO-99.5 convention, because %LocalAppData% is sandbox
// redirected for the coding shell).
void tag_watch();

// ---------------------------------------------------------------------------
// WO-100.5 Phase 2 -- the continuous body-state channel.
//
// THE ENUM VALUES BELOW ARE THE WIRE FORMAT. They are mirrored, by number, in
//   dotnet/KcdMp.Protocol/Protocol.cs      (BodyPace / BodyDir / BodyStance)
//   kdcmp/Data/Scripts/Startup/kdcmp.lua   (KCD2MP.bodyPaceName / DirName / StanceName)
// and all three must change together. They are ours, not the engine's: a
// CryEngine TagID is a position in a CTagDefinition rebuilt from XML per
// build, so it is exactly the kind of table index WO-100 S6.5's rule keeps off
// the wire. The mapping here is name -> ordinal; the receiver maps
// ordinal -> its own build's tag BY NAME, and a name its build lacks is a
// specific, counted rejection rather than a silently different tag.
//
// Append-only. Renumbering one would make a mismatched pair misreport instead
// of saying "unknown".
// ---------------------------------------------------------------------------
enum : uint8_t {
    kPaceNone = 0, kPaceWalk = 1, kPaceRun = 2, kPaceSprint = 3,
    kPaceDash = 4, kPaceSteps = 5,
};
enum : uint8_t {
    kDirNone = 0, kDirForward = 1, kDirBackward = 2, kDirLeft = 3, kDirRight = 4,
};
enum : uint8_t {
    // "upright" is the ABSENCE of any Stance tag, not a tag of its own.
    kStanceUpright = 0, kStanceStealth = 1, kStanceSitting = 2, kStanceLying = 3,
    kStanceHorse = 4, kStanceLeaning = 5,
    // The Stance group has 38 tags, most of them scene furniture
    // (hanushRailing, sittingVariation03). Replicating all 38 is neither
    // useful nor honest about what we can drive, so anything outside the list
    // above reports kStanceOther and the real tag name is logged natively.
    kStanceOther = 6,
};

struct BodyState {
    uint8_t  pace        = kPaceNone;
    uint8_t  dir         = kDirNone;
    uint8_t  stance      = kStanceUpright;
    uint16_t animSpeedCenti = 0;   // pseudo-speed in 0.01 m/s, clamped 0..65535
    uint8_t  unknownTags = 0;      // tags the decode could not place; 0 is the healthy value
};

// Reads one actor's tag state and reduces it to the wire fields above.
// Returns false and touches nothing on any refusal -- the same five gates
// tag_watch() applies, minus the logging. Quiet by design: this runs at the
// position stream's cadence, and a probe that logs per sample is a flood.
bool read_body_state(bool wantPlayer, uint32_t entityId, BodyState* out);

} // namespace kcdmp::mannequin
