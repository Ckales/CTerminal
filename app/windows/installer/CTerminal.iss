; Inno Setup script for the CTerminal Windows installer.
; Build with app/tool/package_windows.ps1, which passes /DAppVersion, /DBuildDir and /DDistDir.
; The AppId must stay stable so upgrades replace the previous installation.

#define AppName "CTerminal"
#define AppPublisher "Ckales"
#define AppURL "https://github.com/Ckales/CTerminal"

#ifndef AppVersion
  #error AppVersion is required: /DAppVersion=<version>
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef DistDir
  #define DistDir "..\..\..\dist"
#endif

[Setup]
AppId={{2FE5BF91-373D-4BF2-B73A-DCADA65DE714}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Per-user installation under %LOCALAPPDATA%\Programs: no administrator prompt.
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#DistDir}
OutputBaseFilename={#AppName}-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\CTerminal.exe
LicenseFile=..\..\..\LICENSE.md
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ShowLanguageDialog=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\CTerminal.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\CTerminal.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CTerminal.exe"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
