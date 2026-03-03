#define MyAppName "RecorderPhone"
#define MyAppExeName "RecorderPhone.exe"

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppSourceDir
  #define AppSourceDir "..\\..\\dist\\windows\\RecorderPhone"
#endif
#ifndef OutputDir
  #define OutputDir "..\\..\\dist\\windows"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "RecorderPhone-Setup"
#endif

[Setup]
AppId={{D3A8F3B5-3A57-4A17-9A2B-D8C1A8E1D95D}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppName}
DefaultDirName={localappdata}\Programs\RecorderPhone
DefaultGroupName=RecorderPhone
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
CloseApplications=yes
ForceCloseApplications=yes
RestartApplications=no
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create desktop shortcut"; GroupDescription: "Additional tasks:"; Flags: unchecked

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\RecorderPhone"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\RecorderPhone"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Classes\recorderphone"; ValueType: string; ValueName: ""; ValueData: "URL:RecorderPhone Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\recorderphone"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\recorderphone\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch RecorderPhone"; Flags: nowait postinstall skipifsilent
