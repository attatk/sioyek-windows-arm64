; Inno Setup script for the Windows sioyek installer.
;
; Built by build_windows_arm64.ps1 -Installer, or manually with:
;   ISCC /DSourceDir=<packaged release folder> /DArch=arm64 scripts\sioyek_installer.iss
;
; Arch is an Inno Setup architecture identifier: arm64 or x64compatible.

#ifndef SourceDir
  #error SourceDir must point to the packaged release folder (the one containing sioyek.exe)
#endif
#ifndef Arch
  #define Arch "arm64"
#endif
#ifndef AppVersion
  #define AppVersion "2.0.0"
#endif
#ifndef OutputDir
  #define OutputDir SourcePath + "\.."
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "sioyek-setup-windows-" + Arch
#endif

[Setup]
AppId={{6F6B4D3E-5A0C-4C59-9C7B-2E7F3B1D8A41}
AppName=Sioyek
AppVersion={#AppVersion}
AppVerName=Sioyek {#AppVersion}
AppPublisher=Sioyek
AppPublisherURL=https://github.com/ahrm/sioyek
AppSupportURL=https://github.com/ahrm/sioyek/issues
DefaultDirName={autopf}\Sioyek
DefaultGroupName=Sioyek
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\sioyek.exe
UninstallDisplayName=Sioyek
ArchitecturesAllowed={#Arch}
ArchitecturesInstallIn64BitMode={#Arch}
; installs for the current user without admin rights unless the user chooses "all users"
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ChangesAssociations=yes
LicenseFile={#SourcePath}\..\LICENSE
SetupIconFile={#SourcePath}\..\pdf_viewer\icon2.ico
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "pdfassociation"; Description: "Register Sioyek as a PDF viewer (it can then be chosen in ""Open with"" and Default apps)"; GroupDescription: "File associations:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Sioyek"; Filename: "{app}\sioyek.exe"
Name: "{autodesktop}\Sioyek"; Filename: "{app}\sioyek.exe"; Tasks: desktopicon

[Registry]
; Windows doesn't let installers silently become the default PDF app; this registers sioyek
; so it shows up in "Open with" and in Settings > Apps > Default apps.
Root: HKA; Subkey: "Software\Classes\Sioyek.PDF"; ValueType: string; ValueName: ""; ValueData: "PDF Document"; Flags: uninsdeletekey; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Classes\Sioyek.PDF\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\sioyek.exe,0"; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Classes\Sioyek.PDF\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\sioyek.exe"" ""%1"""; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Classes\.pdf\OpenWithProgids"; ValueType: string; ValueName: "Sioyek.PDF"; ValueData: ""; Flags: uninsdeletevalue; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Classes\Applications\sioyek.exe\SupportedTypes"; ValueType: string; ValueName: ".pdf"; ValueData: ""; Flags: uninsdeletekey; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Sioyek\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Sioyek"; Flags: uninsdeletekey; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Sioyek\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "PDF viewer for research papers and technical books"; Tasks: pdfassociation
Root: HKA; Subkey: "Software\Sioyek\Capabilities\FileAssociations"; ValueType: string; ValueName: ".pdf"; ValueData: "Sioyek.PDF"; Tasks: pdfassociation
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Sioyek"; ValueData: "Software\Sioyek\Capabilities"; Flags: uninsdeletevalue; Tasks: pdfassociation

[Run]
Filename: "{app}\sioyek.exe"; Description: "{cm:LaunchProgram,Sioyek}"; Flags: nowait postinstall skipifsilent
