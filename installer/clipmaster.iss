; ============================================================
;  ClipMaster Pro — Inno Setup Installer Script
;
;  To build: open this file in Inno Setup Compiler and hit Build.
;  Or from command line: iscc clipmaster.iss
;
;  Prerequisites: run build_installer.bat first to create
;  the dist\ClipMasterPro folder.
; ============================================================

#define AppName "ClipMaster Pro"
#define AppVersion "1.0.0"
#define AppPublisher "ClipMaster"
#define AppExeName "clipmaster_app.exe"
#define AppURL "https://github.com/bburge14/ClipMaster"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=..\dist
OutputBaseFilename=ClipMasterPro-Setup-v{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\clipmaster_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main application and all DLLs from Flutter build
Source: "..\dist\ClipMasterPro\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start Menu shortcut — launches via the VBS wrapper (no console window).
Name: "{group}\{#AppName}"; Filename: "{app}\ClipMaster Pro.vbs"; IconFilename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\ClipMaster Pro.vbs"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\ClipMaster Pro.vbs"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent shellexec
