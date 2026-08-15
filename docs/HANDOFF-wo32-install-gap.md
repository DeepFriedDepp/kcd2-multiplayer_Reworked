# Handoff to WO-32 — the 0.11.8 install is half-applied, and NPC sync is silently off

Found 2026-08-15 in WO-34, while verifying that WO-34's own fix reached the
game. It did. WO-32's did not — but only half of it, in the half that fails
without any error.

**This is not a build failure. The build is correct. The install is not.**

---

## Bottom line

| layer | state |
|---|---|
| **Built** — `release\KCDMP\*`, `kdcmp\Data\kdcmp.pak` | correct, all work orders present |
| **Installed pak** — `<ModdingTools>\Mods\kdcmp\Data\kdcmp.pak` | correct, WO-32 **and** WO-34 present |
| **Installed app** — `%LocalAppData%\KCDMP\*` | **stale**, missing WO-32's agent half |

So WO-32's NPC sync is **inert on this machine**: the mod side is installed and
waiting, and the agent that is supposed to drive it is a build old. Nothing
errors, nothing logs, nothing looks wrong. NPCs simply never sync.

WO-34's fix is unaffected — it lives entirely in the pak, which did install.

---

## Evidence

`KcdMpClient.dll`, the agent:

```
BUILT     release\KCDMP\KcdMpClient.dll      203,264 b   modified 12:41:25
INSTALLED %LocalAppData%\KCDMP\KcdMpClient.dll  199,680 b   modified 11:06:52
                                                           created  Aug 12
```

String-literal probe of the two (these are plain literals in `GameBridge.cs`,
so absence of the literal means absence of the call):

| marker | BUILT | INSTALLED |
|---|---|---|
| `KCD2MP_ApplyNpcState` | present | **ABSENT** |
| `KCD2MP_StartNpcSync` | present | **ABSENT** |
| `npc_state` | present | **ABSENT** |
| `KCD2MP_ReconcileGhosts` | present | present |
| `KCD2MP_SetGhostDead` | present | present |
| `KCD2MP_StartEmitter` | present | present |

`KcdMpServer.dll` is stale the same way (61,440 built vs 60,416 installed),
along with ~28 framework DLLs. `KcdMp.Protocol.dll` and `KCDMP_launcher.dll`
**did** update — so the install partially succeeded, which is why nothing
looked obviously broken.

### The installer definitely ran

`unins000.exe` created **12:51:04**; `kdcmp.pak` and `mod.manifest` created
**12:51:12**. So Setup 0.11.8 ran at 12:51 and wrote the mod half. It just did
not overwrite most of the app half.

### Why — and what it is not

- **Not a version-comparison skip.** All three `[Files]` lines in
  `installer\KCDMP.iss` carry `ignoreversion`.
- **Not deferred to a reboot.** `PendingFileRenameOperations` has entries, none
  of them `KCDMP`.
- **Almost certainly files in use.** `KcdMpClient` (pid 15096, started 12:21)
  and `KcdMpServer` (pid 17396, started 12:07) were running at 12:51 — though
  both from `dotnet\...\bin\Debug\`, not from the install directory, so a
  launcher running out of `{app}` and since closed is the likelier lock.
  **Unproven; the remedy below does not depend on which it was.**

---

## The fix

1. Close **everything**: the launcher, the agent, the relay, and the two
   `bin\Debug` processes above (they may belong to another session — check
   before killing).
2. Re-run `release\KCDMP-Setup-0.11.8.exe`.
3. Verify rather than assume:

```bash
powershell -ExecutionPolicy Bypass -File tools\Verify-Install.ps1
```

Exit 0 and `ALL CHECKS PASSED` means built and installed agree. Anything else
prints exactly which marker is missing from which layer.

If the app half still does not update with everything closed, the next thing to
check is whether Inno is writing to a different `{app}` than the launcher reads
from — see the note on redirection below.

---

## Two traps this cost, recorded so nobody pays them twice

### 1. A UTF-16 probe that decodes only from offset 0 lies

`tools\Verify-Install.ps1` reads assemblies as raw bytes and looks for string
literals. .NET stores them UTF-16 in the `#US` heap, and **a literal can start
at either byte parity**. Decoding from offset 0 only misses every literal
starting on an odd offset — a coin flip per string, and it shifts between
builds as the heap moves.

The first run of this script reported `KCD2MP_ReconcileGhosts` **ABSENT from
the new build** — a WO-28/34 regression that did not exist. The literal was
there; the probe was misaligned. `Get-Strings` now decodes from **both**
offsets, and the comment there says why.

A false negative in this probe reads as "the feature is not in this build",
which is precisely the conclusion the script exists to make trustworthy. Treat
any single-source "ABSENT" as a hypothesis until a second, independent signal
agrees. The WO-32 gap above has two: file size and `CreationTime`.

### 2. `LastWriteTime` cannot tell you whether an install landed

Inno preserves the source file's `LastWriteTime`, so a freshly installed file
looks as old as the build that produced it. **`CreationTime` is the one that
moves** when a file is actually written — that is how the 12:51 install was
distinguished from the 11:06 build sitting there untouched.

Comparing **file size** between `release\KCDMP` and the install directory is
the cheapest reliable check, and is what the script's last section does.

---

## Unrelated, but noticed while doing this

`%LocalAppData%` resolves differently inside a sandboxed tool than it does for
you. There are two real, distinct trees on this machine:

```
C:\Users\Jonasty\AppData\Local\KCDMP                                      1023 files
C:\Users\Jonasty\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Local\KCDMP   1021 files
```

Both currently hold the **same stale agent**, so it does not change the finding
above. But a desktop shortcut created from inside a sandboxed tool can point
into the redirected copy, which would launch a different build from the one the
installer wrote. If a launcher ever behaves like an older version for no
reason, check which of these two it is actually running from.
`Verify-Install.ps1` takes `-AppDir` so either can be checked explicitly.

---

## What this does not touch

WO-34's fix (five bandit souls removed from the face roster; dead ghosts frozen
and recycled instead of sliding around) is verified present in the **installed**
pak and needs nothing here. See `docs/WO-34-findings.md`.
