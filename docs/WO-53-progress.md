# WO-53 progress

## 2026-08-25 (Fable 5) — Mannequin source as decode key; headless-mode check

Investigation only. No code, no `VERSION`, nothing copied from the CRYENGINE
fork, no game-file edits. Deliverable: `docs/WO-53-findings.md`.

### Lead 1 — reading the real ActionController/ICryMannequin source

- Sparse-cloned `MergHQ/CRYENGINE` (release, commit `8b63f61c`, 2023-05-10)
  into the session scratchpad — Mannequin + CryAction only, never into this
  repo.
- WO-42 §3's `TAction` layout maps **1:1** onto `IAction`'s real member list
  (`ICryMannequin.h:1807–1825`); the Warhorse 7-arg ctor is the stock ctor
  signature verbatim (`:1404`).
- Decoded: +0x14 = `m_queueTime` (and its meaning: pending-queue expiry,
  -1 = forever — `ICryMannequin.h:1538–1550`, `ActionController.cpp:1712`);
  0xFFFFFFFF = `TAG_ID_INVALID`; 0xFFFFFFFE = `OPTION_IDX_RANDOM`; status 4 =
  `Finished`; restart flags 0x40/0x80 = `Requeued|TrumpSelf`; +0x68 =
  `CMannequinParams` (confirms WO-42 §6.3).
- **One correction:** +0x54 is `m_userToken`, not a scope mask; the real
  forced scope mask is +0x18 (`ActionController.cpp:666`). Documentation-only;
  grep confirms no shipped code depends on it.
- `m_pSyncPartner` exists nowhere in the fork. Stock paired animation =
  controller enslavement (`SetSlaveController`,
  `ActionController.cpp:1317–1409`; `m_slaveActions`), structurally different
  from KCD2's observed two-independent-directors pairing — WO-42 §5.1's
  reading confirmed by contrast.
- Gate 1: prior work confirmed accurate; one name corrected; no better
  approach than the shipped WO-45–49 mechanism; no new WO warranted.

### Lead 2 — headless/no-renderer mode in KCD2's own build

- Retail `WHGame.dll` and MT `CrySystem.dll` string-scanned with offsets
  recorded: renderer selector knows DX12/DX11 (+AGC/GNM/Vulkan names) and has
  **no NULL branch**; the only `CryRenderNULL` string in either build is the
  stock memory-profiler module list (with D3D9/D3D10/Editor.exe). MT build
  ships exactly one renderer module: `CryRenderD3D12.dll`.
- Live test: direct exe launch dies at Steam DRM (flag never exercised —
  recorded to prevent misreading); `steam -applaunch 1771300 +r_Driver NULL
  -devmode` booted `CryRenderD3D12` with a real window; the CVar stored NULL
  only as `[DUMPTODISK, REQUIRE_APP_RESTART]`. Hard-killed before clean exit;
  verified nothing persisted to user.cfg/system.cfg/Saved Games.
- Warning recorded: never persist `r_Driver=NULL` — expected unbootable game
  until reverted.
- Gate 2: nothing found; the objection stands. The c1-launcher precedent
  depends on Crysis shipping `CryRenderNULL.dll`; KCD2 does not, in either
  build. WO-51's inputs unchanged.
