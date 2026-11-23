# Deploying ZeroTouch with Intune

ZeroTouch works in two ways:

- **With a technician:** double-click `Start-ZeroTouch.cmd` from a USB stick or a share, pick the
  department, type who receives the computer, print the form and sign it.
- **Zero-touch, with Intune:** the PC is registered in Windows Autopilot with the department as its
  group tag. When the user signs in for the first time, Intune installs ZeroTouch as a Win32 app,
  which runs as SYSTEM with the right `-Department`, and the handover form is ready in
  `C:\ProgramData\ZeroTouch\Reports` (or on a share, with `-OutputPath`).

This page covers the second way.

## 1. Package it as a Win32 app

Copy only what has to run on the PC into a staging folder:

```
C:\Build\ZeroTouch\
  Invoke-ZeroTouch.ps1
  src\          (all files)
  resources\    (all files)
  profiles\     (all files, including schema\)
```

Then wrap it with the [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):

```powershell
IntuneWinAppUtil.exe -c C:\Build\ZeroTouch -s Invoke-ZeroTouch.ps1 -o C:\Build\Out
```

## 2. Create one app per department

Upload the same `.intunewin` once per department (or once, with one assignment per department and a
different install command each time):

| Setting | Value |
|---|---|
| Install command | `%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-ZeroTouch.ps1 -Department comercial` |
| Uninstall command | `cmd.exe /c exit 0` (provisioning is not undone) |
| Install behavior | System |
| Device restart behavior | Determine behavior based on return codes |
| Return codes | `0` Success, `3010` Soft reboot, `1` Failed (default list is fine) |
| Requirements | Windows 10 22H2 or later, 64-bit |

**Why `Sysnative`:** the Intune Management Extension can start the install command from a 32-bit
process. A 32-bit PowerShell has no BitLocker, DISM or Appx cmdlets, and its writes to
`HKLM:\SOFTWARE` are redirected to `WOW6432Node`, where the detection rule does not look.
`Sysnative` forces the 64-bit PowerShell. `Invoke-ZeroTouch.ps1` also relaunches itself in 64-bit if
it detects a 32-bit process, so a plain `powershell.exe` works too, but being explicit costs nothing.

**Logs:** `C:\ProgramData\ZeroTouch\Logs\ZeroTouch-<PC>-<date>.log`, next to the Intune
Management Extension logs in `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs`.

## 3. Detection rule

Every real run (not `-WhatIf`) writes `HKLM:\SOFTWARE\ZeroTouch`:

| Value | Example |
|---|---|
| `Profile` | `comercial` |
| `Status` | `Success`, `Warning` or `Failed` |
| `ExitCode` | `0`, `3010`, `1` |
| `LastRun`, `FormId`, `ToolVersion`, `ReportPath` | when, which form, which version, where the form is |

Use a custom detection script, so that a failed run is not considered installed and Intune retries it:

```powershell
$marker = Get-ItemProperty -Path 'HKLM:\SOFTWARE\ZeroTouch' -ErrorAction SilentlyContinue
if ($marker -and $marker.Profile -eq 'comercial' -and @('Success', 'Warning') -contains $marker.Status) {
    'ZeroTouch comercial provisioned'
    exit 0
}
exit 1
```

`Warning` counts as installed on purpose: it means "provisioned, with notes on the form" (an
optional app failed, or BitLocker is in report mode and the disk is not encrypted yet).

## 4. Assign by Autopilot group tag

When you register the devices in Autopilot, give each one its department as the **group tag**
(`comercial`, `oficina`, `taller`). Then create one dynamic device group per department:

```
(device.devicePhysicalIds -any (_ -eq "[OrderID]:comercial"))
```

Assign each department's ZeroTouch app as **Required** to its group. A laptop for sales arrives in
its box, the user signs in, and it is provisioned as a sales laptop without anyone touching it.

## 5. Things to know

- **winget on a brand-new PC.** winget comes with *App Installer*, a Store app. On a fresh Windows
  install it can take a few minutes after the first sign-in to be registered or updated, and some
  older images ship a version that does not work as SYSTEM. If the form says *winget is not
  available*, the run exits with `1`, detection fails and Intune tries again later. To avoid the
  first failed attempt, do not make ZeroTouch block the Enrollment Status Page, or update App
  Installer in your image.
- **Store apps (`"source": "msstore"`) cannot be installed as SYSTEM.** Use the winget source, or
  deploy them as *Microsoft Store app (new)* in Intune.
- **BitLocker `Enable` needs a place for the key.** On an Entra ID joined PC the recovery key is
  escrowed to Entra ID before encryption starts; on a domain PC, to Active Directory (the domain
  must allow it). With neither, ZeroTouch does not encrypt and says so on the form.
- **Printer drivers.** As SYSTEM, `driverInf` must point to a share the computer account can read
  (*Domain Computers* on the share and the folder), or to a local path that another Win32 app filled.
  On a PC that is only Entra ID joined there is no computer account for SMB, so ship the driver as its
  own Win32 app, or use Universal Print.
- **Where the forms go.** `-OutputPath \\server\IT$\ZeroTouch` collects every form in one place.
  The computer account (SYSTEM) needs write access to that share.

## From ZeroTouch to native Intune policies

ZeroTouch is useful while a company is moving to Modern Workplace: it gives a consistent result on
day one, with or without Intune. As Intune takes over, each part has a native equivalent:

| ZeroTouch | Intune equivalent |
|---|---|
| Applications from the profile | Win32 apps, or WinGet apps (*Microsoft Store app (new)*), assigned per group |
| Network printers | Universal Print, or a Win32 app with the driver plus a printer configuration script |
| BitLocker check / enable with key escrow | *Endpoint security > Disk encryption*: BitLocker policy with silent enablement and key backup to Entra ID |
| SMBv1 off | Security baselines and the settings catalog (*MS Security Guide*: SMB v1 server and client driver) |
| Firewall defaults and rules | *Endpoint security > Firewall* and firewall rules policies |
| Removing preinstalled apps | A remediation script, or the default Store packages removal policy on recent Windows 11 Enterprise/Education |
| Handover form | No equivalent. Intune knows the device; the signed form says *who received it, in what state*. |

The department profiles are a good starting point for those policies: they already list, per
department, what each group needs.
