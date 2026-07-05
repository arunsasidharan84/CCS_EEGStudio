; CCSEEGStudio-installer.iss
; Inno Setup script for CCS EEG Feature Studio — Windows x64 installer.
;
; Usage (from the repository root):
;   iscc /F"CCSEEGStudio-Installer" windows\installer.iss
;
; The installer packages the Flutter Windows build output together with the
; ccs-eeg-engine.exe Rust binary into a single self-contained installer.
; Output is placed in dist\CCSEEGStudio-Installer.exe.

#define AppName      "CCS EEG Feature Studio"
#define AppExeName   "ccs_eeg_app.exe"
#define AppPublisher "Centre for Consciousness Studies, NIMHANS"
#define AppURL       "https://github.com/arunsasidharan84/CCS_EEGApp"
#define AppVersion   "0.1.0"
#define BuildDir     "..\build\windows\x64\runner\Release"
#define OutputDir    "..\dist"

[Setup]
AppId={{F3A2D8B1-4C7E-4F29-9A1D-6B8E2C5D0F43}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={autopf}\CCSEEGStudio
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Output installer binary.
OutputDir={#OutputDir}
OutputBaseFilename=CCSEEGStudio-Installer
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
WizardStyle=modern
; Require Windows 10 1903 or later (Flutter minimum).
MinVersion=10.0.18362

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter Windows build output (all files in the Release folder).
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}";    Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall";     Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
