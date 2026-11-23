# Department profiles: how to get the JSON for each department

A department profile is one JSON file in `profiles\` that says which applications a department's
computers get and which security settings apply. You rarely need to write one by hand. There are
four ways to get it, from the most to the least automatic:

| Method | Use it when | Command |
|---|---|---|
| **A. Capture a reference PC** | One computer in the department is already set up the way people work. | `.\New-DepartmentProfile.ps1 -FromThisComputer -Name taller` |
| **B. Convert an export** | Same, but you cannot run the script on that PC (no admin rights, someone else's desk). | `winget export -o taller.json` there, then `-ExportFile` here |
| **C. From a spreadsheet** | IT keeps a list of "who uses what" in Excel, or you are starting from scratch for several departments. | `.\New-DepartmentProfile.ps1 -CsvPath .\departments.csv` |
| **D. From a list of ids** | You already know the winget ids. | `.\New-DepartmentProfile.ps1 -PackageId Zoom.Zoom, SumatraPDF.SumatraPDF -Name formacion` |

Whatever the method, the script:

- **leaves out what the parent profile already installs.** With the default `-Extends base`, 7-Zip,
  Chrome and Acrobat Reader are not repeated in every department file. The new file only holds what
  is specific to the department, so changing a company-wide app means editing `base.json` once.
- **leaves out runtimes, built-in apps and hardware tools** (`-ExcludePattern`, see below). A
  reference PC always has Visual C++ runtimes, Edge, WebView2 and its maker's driver tools; none of
  them belong in a department profile.
- **never overwrites an existing profile** unless you add `-Force`, and supports `-WhatIf`.
- **refuses invalid winget ids**, so nothing strange ends up in a file that will later be run as SYSTEM.

Then you **review the file, test it with `-WhatIf`, and commit it**. Profiles in git give you change
control for free: who added which app to which department, and when.

---

## A. Capture a reference PC

Pick the computer of someone in the department whose setup "just works". On that PC, from the
ZeroTouch folder (a USB stick is fine):

```powershell
.\New-DepartmentProfile.ps1 -FromThisComputer -Name taller -DisplayName 'Taller' `
    -Description 'Puesto de planta: planos, programas CNC y transferencia a las máquinas.'
```

It runs `winget export`, converts the result, deletes the temporary export and also takes the PC's
**network printers** (TCP/IP ports). Output:

```
taller: ...\profiles\taller.json (written)
  4 application(s): Notepad++.Notepad++, WinSCP.WinSCP, SumatraPDF.SumatraPDF, TheDocumentFoundation.LibreOffice
  1 network printer(s): Taller - Impresora de planta
  already in base: 7zip.7zip, Google.Chrome
  left out by -ExcludePattern: Microsoft.VCRedist.2015+.x64, Microsoft.Edge, Microsoft.EdgeWebView2Runtime, Lenovo.SystemUpdate, Intel.IntelDriverAndSupportAssistant
```

Printers shared from a print server (`\\server\queue`) are per-user connections, and USB or WSD
printers belong to one desk, so they are not taken; the script says so for each one. Add the
driver package path (`driverInf`) by hand if the driver is not part of Windows (see *Printers* below).

`winget export` only lists applications that winget can match to a package in its catalog. Anything
installed from a vendor's own installer that is not in winget (an ERP client, CNC software, a
licensed CAD package) is **not** captured: winget prints a warning for each one. Note those down;
they need their own deployment (see *Applications that are not in winget* below).

## B. Convert an export taken somewhere else

When you cannot run scripts on the reference PC, winget alone is enough there. Any user can run:

```powershell
winget export -o D:\taller-export.json
```

Back on your own computer:

```powershell
.\New-DepartmentProfile.ps1 -ExportFile D:\taller-export.json -Name taller
```

[`examples\winget-export-taller.json`](../examples/winget-export-taller.json) is a real-looking
export of a workshop PC if you want to try it without one:

```powershell
.\New-DepartmentProfile.ps1 -ExportFile .\examples\winget-export-taller.json -Name taller-test -WhatIf
```

## C. One profile per department from a spreadsheet

Keep one row per department and application. In Excel: *File > Save As > CSV UTF-8* (or plain
*CSV*; both work, and so do `;` and `,` separators):

```
Departamento;Id;Nombre;Obligatoria
Oficina;Microsoft.Office;Microsoft 365 Apps;Sí
Oficina;Microsoft.Teams;Microsoft Teams;Sí
Oficina;geeksoftwareGmbH.PDF24Creator;PDF24 Creator;No
Dirección;Zoom.Zoom;Zoom;No
Recepción;Microsoft.Teams;Microsoft Teams;Sí
```

```powershell
.\New-DepartmentProfile.ps1 -CsvPath .\examples\departments.csv
```

- One file per department: `Dirección` becomes `direccion.json`, with `"displayName": "Dirección"`.
- Column names are matched without accents or case: `Departamento`/`Department`,
  `Id`/`PackageId`/`WingetId`, `Nombre`/`Name`, `Version`, `Obligatoria`/`Required`.
- `Obligatoria` = `No` / `false` / `0` / `opcional` makes the app optional: if it fails, the handover
  form shows a note instead of a failed provisioning.
- Rows with an empty or invalid id are skipped with a warning.
- Existing department files are skipped (add `-Force` to regenerate them).

**Do not know what each department uses?** If the computers are already in Intune, *Apps > Monitor >
Discovered apps* lists the software found on them, and can be exported. If they are domain-joined,
a GLPI or other inventory tool usually has the same information. Use it to fill the spreadsheet.

## D. From winget ids you already know

```powershell
winget search pdf                       # find ids
winget show --id SumatraPDF.SumatraPDF  # check one
.\New-DepartmentProfile.ps1 -PackageId Zoom.Zoom, SumatraPDF.SumatraPDF -Name formacion -DisplayName 'Formación'
```

---

## Review, test and commit

1. **Open the file** (VS Code gives autocompletion and validation through `profiles\schema\profile.schema.json`).
   - Add friendly `name`s: they appear on the handover form.
   - Mark nice-to-have apps with `"required": false`.
   - Pin a version with `"version"` only if the department really needs that version.
   - Add department-specific security settings, if any (see the format below).
2. **Test it without changing anything**, ideally on a clean VM:

   ```powershell
   .\Invoke-ZeroTouch.ps1 -Department taller -WhatIf
   ```

   It loads and validates the profile, checks which apps are already installed and what the
   baseline would change, and writes a handover form marked *SIMULATION*.
3. **Commit the file.** The pull request is the review: someone else sees exactly what changes for
   the department.

## Profile format

```json
{
  "$schema": "./schema/profile.schema.json",
  "name": "taller",
  "displayName": "Taller",
  "description": "Puesto de planta: planos, programas CNC y transferencia de ficheros a las máquinas.",
  "extends": "base",
  "removeApplications": [ "Adobe.Acrobat.Reader.64-bit" ],
  "applications": [
    { "id": "SumatraPDF.SumatraPDF", "name": "SumatraPDF" },
    { "id": "Notepad++.Notepad++", "name": "Notepad++" },
    { "id": "LibreCAD.LibreCAD", "name": "LibreCAD", "required": false }
  ],
  "security": {
    "firewall": {
      "rules": [
        { "displayName": "ZT - Allow DNC from the machine network", "direction": "Inbound", "action": "Allow",
          "protocol": "TCP", "localPort": "5001", "remoteAddress": "192.168.50.0/24", "profile": "Domain,Private" }
      ]
    }
  }
}
```

| Key | Meaning |
|---|---|
| `name` | Same as the file name. Letters, digits, `-`, `_`. |
| `displayName`, `description` | Shown in the technician menu and on the handover form. |
| `extends` | Parent profile. Several levels are allowed: `comercial` → `oficina` → `base`. |
| `abstract` | `true` hides the profile from the menu (only `base.json` uses it). |
| `organization` | `name`, `itContact` and `language` (`en`/`es`) for the handover form. Usually only in `base.json`. |
| `applications` | `"7zip.7zip"` or `{ "id", "name", "scope", "version", "source", "override", "custom", "required" }`. |
| `removeApplications` | Inherited apps this department must not get. |
| `printers` | Network printers: `{ "name", "address", "driver", "driverInf", "port", "location", "comment" }`. |
| `security` | `bitlocker`, `disableSmb1`, `firewall`, `removeBloatware`. See the README. |

**Inheritance rules.** Values set by the child win. Objects merge key by key. Lists are added
together without duplicates: applications are matched by `id`, firewall rules by `displayName` and
printers by `name`, so
a child entry with the same id *replaces* the parent's (useful to change `scope` or pin a version
for one department). To turn a parent setting off, set it to `false` (`"bitlocker": false`).

## Printers

```json
"printers": [
  { "name": "Taller - Impresora de planta", "address": "192.168.50.20", "driver": "HP Universal Printing PCL 6",
    "driverInf": "\\\\srv-files\\drivers\\hp-upd-pcl6\\hpcu270u.inf", "location": "Nave 2", "port": 9100 }
]
```

| Key | Meaning |
|---|---|
| `name` | Queue name users see. No `\`, `,`, `*`, `?`, `[`, `]` or quotes. |
| `address` | IP address or host name of the printer. |
| `driver` | Exact driver name. On a PC that already prints to it: `Get-PrinterDriver \| Select-Object Name`. |
| `driverInf` | Optional. Full path of the driver's `.inf` (local or on a share the PC can read). Staged with `pnputil /add-driver /install` when the driver is not installed. |
| `port` | Raw TCP port, default `9100`. |
| `location`, `comment` | Shown in the printer's properties. |

If the driver is neither installed nor in `driverInf`, the printer is not added and the form says
which driver is missing. Drivers that already ship with Windows need no package. Under Intune, the computer account (SYSTEM) must be able to read the share.

## Default exclusions

`-ExcludePattern` defaults to:

```
Microsoft.VCRedist.*   Microsoft.VCLibs.*   Microsoft.UI.Xaml.*   Microsoft.DotNet.*   Microsoft.WindowsAppRuntime.*
Microsoft.AppInstaller   Microsoft.DesktopAppInstaller   Microsoft.Edge   Microsoft.EdgeWebView2Runtime
Microsoft.OneDrive   Microsoft.Teams.Free   Intel.*   Realtek.*   Nvidia.*   AMD.*   Dell.*   Lenovo.*   HP.*
```

Passing `-ExcludePattern` replaces the whole list: `-ExcludePattern @()` keeps everything, and
`-ExcludePattern 'Microsoft.VCRedist.*', 'Spotify.*'` leaves out only those two patterns.

## Applications that are not in winget

Line-of-business software (ERP clients, licensed CAD/CAM, machine vendor tools) is often not in the
public winget catalog. Options, from simplest:

1. **Intune Win32 app** for that installer, assigned to the department's group, next to ZeroTouch.
2. **A private winget REST source** for the company, so the app has a winget id like any other.
3. Installing it by hand after provisioning and writing it in `-Notes` so it appears on the form.

Local installers inside profiles are on the [roadmap](../README.md#roadmap).
