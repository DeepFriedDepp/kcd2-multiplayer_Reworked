// Steam library / Modding Tools discovery, factored out of KCDMP.iss so it can
// be compiled into a test harness as well as into the installer.
//
// #include this from inside a [Code] section. It defines no UI and touches no
// installer state, so the harness in tests\SteamDetectProbe.iss exercises
// exactly the code the installer runs.

// Steam application ID of "Kingdom Come: Deliverance II Modding tools", read
// off a real appmanifest rather than from a search result:
//   D:\SteamLibrary\steamapps\appmanifest_2429020.acf
//     "appid"      "2429020"
//     "name"       "Kingdom Come: Deliverance II Modding tools"
//     "installdir" "KCD2Mod"
// Retail KCD2 is a separate entry (1771300, installdir KingdomComeDeliverance2)
// and cannot run this mod -- see docs/LAUNCHING.md.
#define ModdingToolsAppId "2429020"

function BackslashPath(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '/', '\', True);
  while (Length(Result) > 0) and (Result[Length(Result)] = '\') do
    Result := Copy(Result, 1, Length(Result) - 1);
end;

{ Returns the Index'th double-quoted token on a line. Steam's VDF/ACF text
  format is a flat sequence of "key" "value" pairs, so a value is token 2. }
function QuotedToken(const Line: String; Index: Integer): String;
var
  I, Count, Start: Integer;
  InQuote: Boolean;
begin
  Result := '';
  Count := 0;
  Start := 0;
  InQuote := False;
  for I := 1 to Length(Line) do
  begin
    if Line[I] = '"' then
    begin
      if not InQuote then
      begin
        InQuote := True;
        Start := I + 1;
      end
      else
      begin
        InQuote := False;
        Count := Count + 1;
        if Count = Index then
        begin
          Result := Copy(Line, Start, I - Start);
          Exit;
        end;
      end;
    end;
  end;
end;

{ VDF escapes a path separator as a doubled backslash. }
function UnescapeVdf(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\\', '\', True);
end;

function ValueForKey(const Lines: TArrayOfString; const Key: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to GetArrayLength(Lines) - 1 do
    if QuotedToken(Lines[I], 1) = Key then
    begin
      Result := UnescapeVdf(QuotedToken(Lines[I], 2));
      Exit;
    end;
end;

{ Both builds ship an executable called KingdomCome.exe, and both ship
  WHGame.dll, so neither tells them apart. The Modding Tools build links its
  engine modules separately (45 DLLs beside the exe) where retail is
  monolithic (6). Framework.dll and CrySystem.dll are the two the plugin
  actually needs -- the IAT hook rewrites WHGame.dll's import of
  Framework.dll's C_ModulesManager::Update, and the rttr reflection ABI is
  exported from CrySystem.dll. Same test as the launcher's own
  Home.razor.cs:IsModdingToolsBuild, deliberately. }
function IsModdingToolsBuild(const ExePath: String): Boolean;
var
  Dir: String;
begin
  Result := False;
  if (ExePath = '') or (not FileExists(ExePath)) then Exit;
  Dir := ExtractFileDir(ExePath);
  Result := FileExists(Dir + '\Framework.dll') and FileExists(Dir + '\CrySystem.dll');
end;

{ The install root, walking up from Bin\<config>\KingdomCome.exe. Found by
  looking for two folders that root actually has rather than by counting
  levels, so a differently-named Bin subfolder still resolves. }
function GameRootOf(const ExePath: String): String;
var
  Dir: String;
  I: Integer;
begin
  Result := '';
  if ExePath = '' then Exit;
  Dir := ExtractFileDir(ExePath);
  for I := 1 to 4 do
  begin
    if Dir = '' then Exit;
    if DirExists(Dir + '\Data') and DirExists(Dir + '\Engine') then
    begin
      Result := Dir;
      Exit;
    end;
    Dir := ExtractFileDir(Dir);
  end;
end;

function FindGameExeUnder(const InstallDir: String): String;
var
  FindRec: TFindRec;
  Candidate: String;
begin
  Result := '';
  if InstallDir = '' then Exit;

  { The layout the real install has; try it before scanning. }
  Candidate := InstallDir + '\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe';
  if IsModdingToolsBuild(Candidate) then
  begin
    Result := Candidate;
    Exit;
  end;

  if FindFirst(InstallDir + '\Bin\*', FindRec) then
  try
    repeat
      if ((FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0)
         and (FindRec.Name <> '.') and (FindRec.Name <> '..') then
      begin
        Candidate := InstallDir + '\Bin\' + FindRec.Name + '\KingdomCome.exe';
        if IsModdingToolsBuild(Candidate) then
        begin
          Result := Candidate;
          Exit;
        end;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

function GetSteamPath(): String;
var
  S: String;
begin
  Result := '';
  { Steam writes this one with forward slashes, e.g. c:/program files (x86)/steam }
  if RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', S) and (S <> '') then
  begin
    Result := BackslashPath(S);
    if DirExists(Result) then Exit;
  end;
  if RegQueryStringValue(HKLM32, 'SOFTWARE\Valve\Steam', 'InstallPath', S) and (S <> '') then
  begin
    Result := BackslashPath(S);
    if DirExists(Result) then Exit;
  end;
  if RegQueryStringValue(HKLM64, 'SOFTWARE\Valve\Steam', 'InstallPath', S) and (S <> '') then
  begin
    Result := BackslashPath(S);
    if DirExists(Result) then Exit;
  end;
  Result := '';
end;

{ Every library root Steam knows about: the install root itself plus each
  "path" entry in steamapps\libraryfolders.vdf. A missing or malformed vdf
  degrades to "just the Steam root" rather than failing -- a library that is
  currently offline (external drive) is skipped by the DirExists test. }
function GetSteamLibraries(const SteamPath: String): TArrayOfString;
var
  Lines, Libs: TArrayOfString;
  I, N: Integer;
  P: String;
begin
  SetArrayLength(Libs, 1);
  Libs[0] := SteamPath;
  N := 1;

  if LoadStringsFromFile(SteamPath + '\steamapps\libraryfolders.vdf', Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if QuotedToken(Lines[I], 1) = 'path' then
      begin
        P := BackslashPath(UnescapeVdf(QuotedToken(Lines[I], 2)));
        if (P <> '') and (CompareText(P, SteamPath) <> 0) and DirExists(P) then
        begin
          N := N + 1;
          SetArrayLength(Libs, N);
          Libs[N - 1] := P;
        end;
      end;
    end;
  end;

  Result := Libs;
end;

// True if any library holds an appmanifest for the Modding Tools at all,
// regardless of whether the files it names are on disk. This is the
// difference between "you do not have them" and "Steam knows about them but
// the files are not there yet" -- what a download still running, a cancelled
// one, and a damaged install all look like, and three very different things
// to tell someone to do about it.
function ModdingToolsRegisteredIn(const SteamPath: String): Boolean;
var
  Libs: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if SteamPath = '' then Exit;

  Libs := GetSteamLibraries(SteamPath);
  for I := 0 to GetArrayLength(Libs) - 1 do
    if FileExists(Libs[I] + '\steamapps\appmanifest_{#ModdingToolsAppId}.acf') then
    begin
      Result := True;
      Exit;
    end;
end;

{ True only if the Modding Tools were found AND pass the discriminator. Both
  halves matter: an appmanifest can name an app whose files are gone, and a
  folder can be the retail game wearing the same executable name. }
function DetectModdingToolsIn(const SteamPath: String; var ExePath: String): Boolean;
var
  Acf, InstallDir, Exe: String;
  Libs, Lines: TArrayOfString;
  I: Integer;
begin
  Result := False;
  ExePath := '';
  if SteamPath = '' then Exit;

  Libs := GetSteamLibraries(SteamPath);
  for I := 0 to GetArrayLength(Libs) - 1 do
  begin
    Acf := Libs[I] + '\steamapps\appmanifest_{#ModdingToolsAppId}.acf';
    if FileExists(Acf) and LoadStringsFromFile(Acf, Lines) then
    begin
      InstallDir := ValueForKey(Lines, 'installdir');
      if InstallDir <> '' then
      begin
        Exe := FindGameExeUnder(Libs[I] + '\steamapps\common\' + InstallDir);
        if Exe <> '' then
        begin
          ExePath := Exe;
          Result := True;
          Exit;
        end;
      end;
    end;
  end;
end;
