; Installer for mpv-portable with its motion smoothing (MVTools, gpumv).
; RIFE and SVP are left out: RIFE's runtime is several GB, and SVP's plugins
; aren't ours to hand out. Ctrl+4 and Ctrl+7 say so instead of failing.
;
; Built by tools/build-installer.ps1 locally and by the CI workflow, both with
; Inno Setup 6. Src is the tree to package: the repo with its binaries in place.

#ifndef Src
  #define Src ".."
#endif
#ifndef AppVersion
  #define AppVersion GetDateTimeString('yyyy.mm.dd', '', '')
#endif

[Setup]
AppId={{6EA71A78-D862-4823-88DD-7ECBFB75F5B3}
AppName=mpv-portable
AppVersion={#AppVersion}
AppVerName=mpv-portable {#AppVersion}
AppPublisher=mpv-portable
; Per user, no admin rights: installs to %LOCALAPPDATA%\Programs
PrivilegesRequired=lowest
DefaultDirName={autopf}\mpv-portable
DisableDirPage=auto
DisableProgramGroupPage=yes
; The task checkboxes are the only page, and its button installs
DisableReadyPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
UninstallDisplayIcon={app}\bin\mpv.exe
UninstallDisplayName=mpv-portable
; mpv keeps its plugins open, so close it before replacing them
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
OutputDir=Output
OutputBaseFilename=mpv-portable-setup
Compression=lzma2/ultra64
SolidCompression=yes

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"
Name: assoc; Description: "Add mpv to ""Open with"" for video and audio files"
Name: protocol; Description: "Open mpv:// links (for browser extensions)"; Flags: unchecked

[Files]
Source: "{#Src}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs; \
  Excludes: "__pycache__,*.log,*.engine,*.engine.cache,*.pyc,\portable_config\cache,\portable_config\watch_later,\portable_config\subtitles,\portable_config\subdl_api_key.txt,\Lib\site-packages\onnx,\Lib\site-packages\onnx-*,\Lib\site-packages\vsmlrt.py,\Lib\site-packages\vapoursynth\plugins\vsort,\Lib\site-packages\vapoursynth\plugins\vsmlrt-cuda,\Lib\site-packages\vapoursynth\plugins\models,vsort.dll,vsncnn.dll,vstrt_rtx.dll,svpflow*.dll,\portable_config\rife.vpy,\portable_config\svp.vpy,\setup-cuda.ps1,\setup-trt.ps1,\unregister-mpv-protocol.bat,\.cuda-dl-tmp"
; The shipped settings, so an update can tell which ones the user changed
Source: "{#Src}\bin\portable_config\vs_config.conf"; DestDir: "{app}\bin\portable_config"; DestName: "vs_config.default.conf"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\mpv"; Filename: "{app}\bin\mpv.exe"; WorkingDir: "{app}\bin"
Name: "{autodesktop}\mpv"; Filename: "{app}\bin\mpv.exe"; WorkingDir: "{app}\bin"; Tasks: desktopicon

[Registry]
; "Open with" and Settings > Default apps. Windows doesn't let an installer make
; itself the default player; the user picks mpv once in the Open with dialog.
Root: HKA; Subkey: "Software\Classes\mpv-portable.file"; ValueType: string; ValueData: "Media file"; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\mpv-portable.file\DefaultIcon"; ValueType: string; ValueData: """{app}\bin\mpv.exe"",0"; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\mpv-portable.file\shell\open"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "mpv"; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\mpv-portable.file\shell\open\command"; ValueType: string; ValueData: """{app}\bin\mpv.exe"" ""%1"""; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\Applications\mpv.exe\shell\open\command"; ValueType: string; ValueData: """{app}\bin\mpv.exe"" ""%1"""; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\Clients\Media\mpv-portable\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "mpv"; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\Clients\Media\mpv-portable\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "mpv video player with motion smoothing"; Tasks: assoc
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "mpv-portable"; ValueData: "Software\Clients\Media\mpv-portable\Capabilities"; Flags: uninsdeletevalue; Tasks: assoc
#dim Exts[23] {"mkv", "mp4", "avi", "mov", "webm", "m4v", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "3gp", "ogv", "vob", "mp3", "flac", "wav", "ogg", "opus", "m4a", "aac", "wma"}
#sub ExtEntries
Root: HKA; Subkey: "Software\Classes\.{#Exts[i]}\OpenWithProgids"; ValueType: none; ValueName: "mpv-portable.file"; Flags: uninsdeletevalue; Tasks: assoc
Root: HKA; Subkey: "Software\Clients\Media\mpv-portable\Capabilities\FileAssociations"; ValueType: string; ValueName: ".{#Exts[i]}"; ValueData: "mpv-portable.file"; Tasks: assoc
#endsub
#define i
#for {i = 0; i < DimOf(Exts); i++} ExtEntries
; mpv://<url> links, handled by bin\mpv-protocol-handler.cmd
Root: HKA; Subkey: "Software\Classes\mpv"; ValueType: string; ValueData: "URL:mpv Protocol"; Flags: uninsdeletekey; Tasks: protocol
Root: HKA; Subkey: "Software\Classes\mpv"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: protocol
Root: HKA; Subkey: "Software\Classes\mpv\DefaultIcon"; ValueType: string; ValueData: """{app}\bin\mpv.exe"",0"; Tasks: protocol
Root: HKA; Subkey: "Software\Classes\mpv\shell\open\command"; ValueType: string; ValueData: """{app}\bin\mpv-protocol-handler.cmd"" ""%1"""; Tasks: protocol

[Run]
Filename: "{app}\bin\mpv.exe"; WorkingDir: "{app}\bin"; Description: "Start mpv"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; What mpv and Python create while running
Type: filesandordirs; Name: "{app}\bin\portable_config\cache"
Type: filesandordirs; Name: "{app}\bin\portable_config\watch_later"
Type: filesandordirs; Name: "{app}\bin\portable_config\__pycache__"
Type: filesandordirs; Name: "{app}\bin\Lib\site-packages\__pycache__"
Type: filesandordirs; Name: "{app}\bin\Lib\site-packages\vapoursynth\__pycache__"
Type: files; Name: "{app}\bin\*.log"
Type: files; Name: "{app}\bin\portable_config\subdl_api_key.txt"

[Code]
// An update keeps the settings the user changed (in the settings window or by
// hand) and takes the new defaults for the rest. Changed means different from
// the defaults the previous version shipped, kept in vs_config.default.conf.
var
  UserConf, OldDefaults: TArrayOfString;
  HaveUser, HaveDefaults: Boolean;

function ConfKey(Line: String; var Key, Value: String): Boolean;
var
  P: Integer;
begin
  Line := Trim(Line);
  P := Pos('=', Line);
  Result := (Line <> '') and (Line[1] <> '#') and (P > 1);
  if Result then
  begin
    Key := Trim(Copy(Line, 1, P - 1));
    Value := Trim(Copy(Line, P + 1, Length(Line)));
  end;
end;

// The last one wins, as in the .vpy scripts' parser
function FindValue(Lines: TArrayOfString; Key: String; var Value: String): Boolean;
var
  I: Integer;
  K, V: String;
begin
  Result := False;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if ConfKey(Lines[I], K, V) and (CompareText(K, Key) = 0) then
    begin
      Value := V;
      Result := True;
    end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Conf: String;
  NewConf: TArrayOfString;
  I: Integer;
  K, V, UserV, OldV: String;
begin
  Conf := ExpandConstant('{app}\bin\portable_config\vs_config.conf');
  if CurStep = ssInstall then
  begin
    HaveUser := LoadStringsFromFile(Conf, UserConf);
    HaveDefaults := LoadStringsFromFile(ExpandConstant('{app}\bin\portable_config\vs_config.default.conf'), OldDefaults);
  end
  else if (CurStep = ssPostInstall) and HaveUser and LoadStringsFromFile(Conf, NewConf) then
  begin
    for I := 0 to GetArrayLength(NewConf) - 1 do
      if ConfKey(NewConf[I], K, V) and FindValue(UserConf, K, UserV) then
        if not HaveDefaults or not FindValue(OldDefaults, K, OldV) or (OldV <> UserV) then
          NewConf[I] := K + '=' + UserV;
    SaveStringsToFile(Conf, NewConf, False);
  end;
end;
