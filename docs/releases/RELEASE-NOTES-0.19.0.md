# KCD2-MP 0.19.0

The label for everything on `main` as of WO-74 (2026-08-28), and a packaged
release: `KCDMP-Setup-0.19.0.exe` plus the update-only
`KCDMP-DirectInstall-0.19.0.zip`.

**If you might be on a broken 0.18.8, just run the 0.19.0 installer. It
repairs.**

## This is an installer release

Nothing in the game changed. The only shipping code between 0.18.8 and this
version is the installer, the update-only package and the build tooling — the
work in between (WO-71/72/73) was headless-server research that ships nothing.
Ghost gender, ghost crime isolation, ghost yaw smoothing and the relay's
claim-update hardening all reached you in **0.18.8**; they are listed at the
bottom for anyone upgrading from before that.

## What was wrong

Setup could stop part way through an upgrade and leave you worse off than
before you ran it. **One file it could not overwrite was enough.** When that
happened:

- some components stayed on the old build while others updated — a mix of two
  versions that looks installed and is not;
- the mod folder inside your game was left **empty**, because Setup cleared it
  before copying and never got as far as putting the new one back;
- Setup exited with the code Windows uses for *"the user pressed Cancel"*, so
  nothing anywhere said a file had failed;
- the install folder's own `install-verify.txt` still read `PASS` — from the
  *previous* run.

Run interactively, the same situation offered an Ignore button that skipped the
file and carried on to a green "Setup finished" page.

## What 0.19.0 does instead

- **It repairs an install that is already in that state.** Mixed versions,
  missing files, corrupt files, and files from older layouts that no release
  ships — including the kind that can stop the relay starting at all — are all
  corrected or removed, and each removal is named in the report.
- **It checks its own work.** Every single file, in the install folder *and*
  in your game's mod folder, is verified by SHA-256 before Setup says it is
  done. The mod half was previously checked by nothing at all.
- **It cannot finish quietly over a broken install.** A failure now says
  `THIS INSTALL IS NOT COMPLETE`, names the components, writes them to
  `install-verify.txt`, and returns a non-zero exit code.
- **It never leaves your game with no mod.** An upgrade that fails now leaves
  the previous version's mod in place and working.
- **It stops before it starts, if something is running.** The launcher, the
  agent, the relay, the master server and the game all hold files an update has
  to replace. The master server was missing from that list.
- **Your files stay yours.** `settings.json`, favourites, custom servers, logs
  and anything you put in the install folder are never touched by the repair.

The update-only zip now contains an `Apply.ps1` that does all of the same
checks — copying `App\` and `Mod\` over the top by hand still works, but
nothing verifies it, and a file that was in use is skipped in silence.

## Where to look if something goes wrong

`install-verify.txt`, in the install folder. It names the version, says `PASS`
or `FAIL`, lists any component that did not land, and lists anything the
repair removed. If you report a problem, send that file.

## For anyone coming from before 0.18.8

- **Ghost gender** — ghosts of female characters no longer appear male.
- **Ghost crime isolation** — the reachable half; a ghost can no longer be
  talked to. Punching a ghost in front of a guard still files a real crime;
  that needs a native fix and is not done.
- **Ghost yaw smoothing** — turning ghosts no longer snap their heads round.
- **Relay claim-update hardening** — implausible NPC movement from a peer is
  rejected and counted instead of applied.

Full evidence trail: `docs/WO-74-findings.md` and `docs/WO-74-progress.md`.
