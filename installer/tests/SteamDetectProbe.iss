; Test harness for installer\SteamDetect.iss.
;
; Compiles the installer's real detection code -- the same file KCDMP.iss
; includes, not a copy -- into a tiny setup that runs the detection against a
; fixture tree and prints one RESULT line per case, then aborts before
; installing anything.
;
; Driven by tools\Test-InstallerDetect.ps1, which builds the fixtures, runs
; this, and asserts on the output. Not meant to be run by hand.
;
;   SteamDetectProbe.exe /VERYSILENT /SUPPRESSMSGBOXES /LOG=<log> /FIXTURES=<dir>

[Setup]
AppName=KCDMP SteamDetect probe
AppVersion=1.0
DefaultDirName={localappdata}\KCDMPSteamDetectProbe
PrivilegesRequired=lowest
OutputDir=.
OutputBaseFilename=SteamDetectProbe
Uninstallable=no
CreateAppDir=no
SetupLogging=yes

[Code]
#include "..\SteamDetect.iss"

procedure RunCase(const Name, SteamPath: String);
var
  Exe: String;
  Found: Boolean;
  Libs: TArrayOfString;
begin
  Libs := GetSteamLibraries(SteamPath);
  Found := DetectModdingToolsIn(SteamPath, Exe);
  Log('RESULT ' + Name +
      ' | libs=' + IntToStr(GetArrayLength(Libs)) +
      ' | found=' + IntToStr(Integer(Found)) +
      ' | exe=' + Exe);
end;

function InitializeSetup(): Boolean;
var
  Fixtures, Exe: String;
begin
  Fixtures := ExpandConstant('{param:fixtures}');

  { Synthetic cases. }
  RunCase('multi-library', Fixtures + '\multi\Steam');
  RunCase('app-in-root-library', Fixtures + '\rootlib\Steam');
  RunCase('missing-app', Fixtures + '\missing\Steam');
  RunCase('malformed-vdf', Fixtures + '\malformed\Steam');
  RunCase('no-vdf-at-all', Fixtures + '\novdf\Steam');
  RunCase('manifest-but-no-files', Fixtures + '\ghost\Steam');
  RunCase('retail-not-modding-tools', Fixtures + '\retail\Steam');
  RunCase('offline-library', Fixtures + '\offline\Steam');
  RunCase('empty-steam-path', '');

  { The real Steam install on the machine running this. }
  Log('RESULT real-steam-path | value=' + GetSteamPath());
  if DetectModdingToolsIn(GetSteamPath(), Exe) then
    Log('RESULT real-machine | found=1 | exe=' + Exe)
  else
    Log('RESULT real-machine | found=0 | exe=');

  { GameRootOf / IsModdingToolsBuild against the fixture that has a full
    layout, so the Mods target derivation is covered too. }
  DetectModdingToolsIn(Fixtures + '\multi\Steam', Exe);
  Log('RESULT gameroot | value=' + GameRootOf(Exe));

  Log('RESULT quotedtoken | a=' + QuotedToken('	"path"		"D:\\SteamLibrary"', 1) +
      ' | b=' + UnescapeVdf(QuotedToken('	"path"		"D:\\SteamLibrary"', 2)) +
      ' | missing=[' + QuotedToken('no quotes here', 2) + ']');

  Result := False;
end;

