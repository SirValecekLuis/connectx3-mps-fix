# ConnectX-3 in Windows: Code 43 / "MAP_FA command failed with error -5" - root cause and fix

Mellanox **ConnectX-3 / ConnectX-3 Pro** cards (mlx4, PCI `15B3:1003` / `15B3:1007`) fail in Windows on some
desktop motherboards with **Code 43** and `MAP_FA command failed with error -5 ... Most likely a FW problem`.
Sometimes the card works after a reboot, mostly it does not. Re-flashing firmware and changing drivers does not help.
The same card works fine in Linux.

**It is not the card and not the firmware.** The BIOS leaves the card's PCIe **Max Payload Size (MPS) at 128 bytes**
while the root port it is plugged into uses **256 bytes**. The first larger DMA read of the card gets a 256-byte
answer, the card rejects it as a *Malformed TLP*, and the driver fails. Linux silently fixes the mismatch at boot -
Windows does not.

This repository contains a full diagnosis guide and a **tested workaround**: a tiny UEFI Shell script that runs
before Windows at every boot and sets the card's MPS to the root port's value (exactly what Linux does), with a
safety interlock. After that the card works in Windows on every boot.

> Tested and confirmed on **ASRock B760 Pro RS/D4** + **ConnectX-3 Pro MCX314A-BCCT** + **Windows 11 25H2**
> (details in [Tested hardware](#13-tested-hardware)). Reports from other boards are very welcome - open an issue.

---

## Quick start - three double-clicks

1. **Download:** green **Code** button → **Download ZIP**. Right-click the ZIP → *Properties* → tick **Unblock** → OK.
   Extract it anywhere.
2. Double-click **`1-CHECK.cmd`** - *"Is my card affected?"* It only reads and changes nothing. It compares the
   Max Payload Size Windows recorded for your card with all your other PCIe devices and looks at the driver log:
   ```
   Card MPS    : 128 B   (card supports up to 512 B)
   Other PCIe devices: 256 B  (graphics card, NVM Express Controller, ...)
   Driver log  : last 90 days: 3x started OK, 41x failed (41x 'MAP_FA ... error -5')

   VERDICT: AFFECTED (very likely). The card runs with MPS 128 B while the rest of your PCIe devices use 256 B,
            and the driver fails with MAP_FA error -5. That is exactly this BIOS bug. -> Use 2-FIX.cmd
   ```
3. If affected: read [Requirements and risks](#6-requirements-and-risks---read-this) (Secure Boot off, BitLocker),
   then double-click **`2-FIX.cmd`** and follow the instructions. It runs twice:
   * **1st run** prepares a USB stick (FAT32). You restart and boot from the stick once (boot menu, e.g. F11) - it
     only *reads* the register values the BIOS left and starts Windows again.
   * **2nd run** shows the analysis, asks, and installs the fix. Then set *Boot Option #1* in the BIOS as shown.
4. After the restart double-click **`3-TEST.cmd`**. It must end with **`RESULT: everything OK`**.

To remove everything: **`UNINSTALL.cmd`**. Windows may ask for administrator rights - that is expected
(the scripts read firmware boot entries and the EFI partition). If Windows SmartScreen warns about the `.cmd` files,
choose *More info → Run anyway* (or unblock the ZIP as described in step 1).

The rest of this page explains everything in detail.

---

## Contents

1. [Symptoms](#1-symptoms)
2. [Root cause in short](#2-root-cause-in-short)
3. [Does this apply to you? (diagnosis)](#3-does-this-apply-to-you-diagnosis)
4. [Try these first](#4-try-these-first)
5. [How the workaround works](#5-how-the-workaround-works)
6. [Requirements and risks - read this](#6-requirements-and-risks---read-this)
7. [Installation, step by step](#7-installation-step-by-step)
8. [What you should see](#8-what-you-should-see)
9. [Daily use and maintenance](#9-daily-use-and-maintenance)
10. [Uninstall and recovery](#10-uninstall-and-recovery)
11. [Troubleshooting](#11-troubleshooting)
12. [Manual method (no scripts)](#12-manual-method-no-scripts)
13. [Tested hardware](#13-tested-hardware)
14. [FAQ](#14-faq)
15. [Repository layout](#15-repository-layout)
16. [Credits, license, disclaimer](#16-credits-license-disclaimer)

---

## 1. Symptoms

* Device Manager → *System devices* → **Mellanox ConnectX-3 (PRO) VPI ... Network Adapter**: **Code 43**.
  The Ethernet ports ("Mellanox ConnectX-3 Pro Ethernet Adapter") are missing or show an error.
* Event Viewer → *Windows Logs → System*, source **mlx4_bus**, at every failed boot:
  * ID 48: `Execution of FW command failed. op 0xfff, status 0x1, errno -5 ...`
  * ID 7: `MAP_FA command failed with error -5. The adapter card is non-functional. Most likely a FW problem.`
  * ID 73: `Driver startup failed because the hca could not be initialized.`
* Occasionally (not reproducibly) the card initializes after a reboot (event ID 6 instead of 73).
* The card works in Linux on the same PC, and works in other (server) machines.
* Firmware re-flash, other firmware versions, WinOF driver versions, other slots: no change.

## 2. Root cause in short

| | Max Payload Size |
|---|---|
| PCIe root port the card is plugged into (set by BIOS) | **256 B** |
| Mellanox card (left at power-on default by BIOS) | **128 B** |

A root port may send packets up to *its* MPS. When the card starts its first DMA read (firmware command `MAP_FA`),
the root complex answers with 256-byte completions. A 256-byte packet to a device configured for 128 bytes is a
**Malformed TLP** by the PCIe spec, the card drops it, its firmware reports an internal error and the Windows driver
gives up → Code 43.

* **Linux** compares every device with its upstream port at boot and fixes it
  (`pci 0000:08:00.0: Max Payload Size set to 256 (was 128, max 512)`), so the card works.
* **Windows** keeps whatever the BIOS left and even restores that value whenever the device is (re)started, so a
  fix from inside Windows is undone immediately.

Full evidence (AER registers, decoded packet header, experiments): [docs/technical-details.md](docs/technical-details.md).

## 3. Does this apply to you? (diagnosis)

The fix only helps with this specific mismatch - check before installing anything.

### A. The quick way: `1-CHECK.cmd` (Windows, read-only)
Windows records the PCIe Max Payload Size of every device (`DEVPKEY_PciDevice_CurrentPayloadSize`). Windows does
not show the root port's own value, but all other devices reveal what the BIOS uses. `1-CHECK.cmd`
(`windows\Check-MyCard.ps1`) compares the card with them, reads the `mlx4_bus` event log and, as administrator,
also shows whether the fix is installed and ran at this boot. Possible verdicts:

| Verdict | Meaning |
|---|---|
| **AFFECTED (very likely)** | card MPS below the rest of the system + MAP_FA -5 failures → use the fix |
| **LIKELY AFFECTED** | MPS mismatch, but the driver has not failed (yet) |
| **WORKS ON THIS BOOT, BUT FAILED BEFORE** | a "lucky" boot - run the check again when the card fails |
| **FIX ACTIVE AND WORKING** | the fix is installed, ran at this boot, card initialized |
| **NOT AFFECTED** / **DIFFERENT PROBLEM** | no mismatch - this fix will not help |

### B. Windows event log
Event Viewer → System → filter source `mlx4_bus`: you see IDs **48 / 7 / 73** with `MAP_FA ... error -5` (section 1).

### C. Linux live USB (100 % confirmation, changes nothing on your PC)
1. Download an Ubuntu Desktop ISO (any recent one; we used 26.04 LTS), write it to a USB stick with
   [Rufus](https://rufus.ie) or balenaEtcher.
2. Boot it (ASRock: **F11** boot menu → `UEFI: <stick>`), choose **Try Ubuntu** - do **not** install.
3. Open a terminal and run:
   ```bash
   sudo dmesg | grep -i "max payload"
   ```
   or copy [`linux/check-mps.sh`](linux/check-mps.sh) to the live system and run `sudo bash check-mps.sh`.
4. **If you see `Max Payload Size set to 256 (was 128, ...)` for your Mellanox device, this fix applies to you.**
   In Linux the card should also work (`ip -br link` shows the `enp...` interfaces).

If there is no such line, your problem is something else - do not use this fix.

### D. Optional: read the registers in Windows
With NVIDIA/Mellanox **WinMFT** (Mellanox Firmware Tools for Windows, from NVIDIA's networking firmware-tools page)
installed, in an elevated prompt (device name `mt4099_pciconf0` for ConnectX-3, `mt4103_pciconf0` for ConnectX-3 Pro, see `mst status`):
```
win_mini_setpci -s mt4103_pciconf0 0x68     # Device Control: 0x....2000 = MPS 128 B
win_mini_setpci -s mt4103_pciconf0 0x158    # AER uncorrectable status: 0x00040000 = Malformed TLP
```

## 4. Try these first

These are cleaner than the workaround - check them before you continue:

1. **BIOS update / BIOS option.** Some BIOSes have a *PCIe Max Payload Size* option (set it to 128 or "Auto"),
   and a newer BIOS may fix it. Please also report it to your board vendor -
   template: [docs/vendor-support-ticket.md](docs/vendor-support-ticket.md).
2. **Another slot.** CPU-attached slots are often configured differently from chipset slots.
   (On the test board both chipset slots were affected.)
3. **Linux** for this machine, if that is an option - it works out of the box.

## 5. How the workaround works

```
Power on → BIOS/POST (card left at MPS 128 B)
        → firmware boot entry #1 "PCIe MPS fix (UEFI Shell)"  =  \EFI\mpsfix\shellx64.efi  (UEFI Shell)
             startup.nsh:
               read 3 registers  →  compare with ref.txt (recorded by a read-only probe)
               all match?  yes → write card Device Control: MPS = root port MPS   (e.g. 0x2000 → 0x2020)
                           no  → write nothing
               start \EFI\Microsoft\Boot\bootmgfw.efi  (normal Windows boot)
        → Windows records MPS 256 B for the card and keeps it → mlx4_bus initializes the card
```

* **Nothing is changed permanently in the card or the BIOS.** The register write is volatile; at the next power-on
  the BIOS starts from scratch and the script does it again.
* **Safety interlock:** the write only happens if, at that boot,
  1. the device at the card address is still the same card (vendor/device ID),
  2. the root port above it still leads to the card's bus (bus number register), and
  3. the root port's Device Control is exactly what the probe recorded - so if a BIOS update ever changes the root
     port to 128 B, the script does **not** set the card to 256 B (that opposite mismatch would be worse).
* Windows Boot Manager, its files and its boot entry are not modified. If the shell entry fails to start, the
  firmware simply boots the next entry (Windows Boot Manager).

The UEFI Shell is the official EDK2 shell build by pbatard ([UEFI-Shell](https://github.com/pbatard/UEFI-Shell),
release 26H2). The scripts download it from GitHub and verify its SHA256
(`4922d9885ac92d8ab58e5da4eb8ad6cbfbe651ea9cdc03a1ba67355e5ede83b1`).

## 6. Requirements and risks - read this

* **UEFI boot** (not legacy/CSM boot of Windows). Check: `msinfo32` → BIOS Mode = UEFI.
* **Secure Boot must be OFF.** The UEFI Shell is not signed by Microsoft, so with Secure Boot on it will not start.
  (Some games' anti-cheat systems require Secure Boot - this fix is not compatible with those.)
* **BitLocker / Device Encryption:** changing the boot path changes the TPM measurements. If BitLocker is on,
  suspend it first (`Suspend-BitLocker -MountPoint C: -RebootCount 3`) and make sure you have your recovery key
  (<https://aka.ms/myrecoverykey>). The installer refuses to run while BitLocker protection is on.
* **Card directly on a root port.** Cards behind a PCIe switch are not handled (the scripts detect this and stop).
* **Boot takes ~5 s longer** (the shell's countdown).
* **Physical-access note:** during the 5 s countdown, pressing ESC opens a UEFI Shell prompt. With Secure Boot off
  and no BIOS password, someone at the keyboard could already boot anything from USB, so this adds no new remote risk.
* **You use this at your own risk.** Writing PCI registers and changing boot entries is low-level work. Everything is
  reversible ([Uninstall](#10-uninstall-and-recovery)), and every step was verified on the test system, but your
  hardware may differ.

## 7. Installation, step by step

**`2-FIX.cmd` does steps 7.3 - 7.6 for you** (check → probe stick → analysis → install). This section describes the
same steps manually and in detail. Steps 7.1 (drivers), 7.2 (BIOS settings) and 7.7 (boot order) are always yours.

All Windows scripts are in [`windows/`](windows). Run them in **PowerShell as administrator**
(Start → right-click *Terminal* → *Terminal (Admin)*). If scripts are blocked:
```powershell
Set-ExecutionPolicy -Scope Process Bypass
Get-ChildItem .\windows\*.ps1 | Unblock-File
```

### 7.1 Drivers (make bus and Ethernet driver the same version)
The card needs the **mlx4_bus** driver (shows the card under *System devices*) and the **mlx4eth63** driver
(the Ethernet ports). They must come from the **same** package. Either:
* WinOF **5.50.53000** (last version for ConnectX-3, driver 5.50.14740), or
* the driver built into Windows (inbox, 5.50.14695) - for both.

If the card works but the ports show *"There is an interface mismatch between ETH driver and the bus driver
(304 vs 302)"*, the two drivers come from different packages. After installing WinOF once you can re-install its bus
driver without running the installer again:
```powershell
pnputil /add-driver "C:\Program Files\Mellanox\MLNX_VPI\HW\mlx4_bus\mlx4_bus.inf" /install
```
> ⚠️ On the test system the **WinOF 5.50.53000 installer updated the card firmware automatically**
> (2.38 → 2.42). If you run a custom firmware, back it up first (`flint -d <dev> ri backup.bin`).

### 7.2 BIOS settings
Tested configuration: **CSM Enabled**, *Launch PXE OpROM Policy* = **Do not launch** (or anything that prevents
the card's own network boot ROM from running), Video/Storage OpROM policy = UEFI only where these items exist
(menus differ between BIOS versions - make sure your graphics card still shows a picture), **Secure Boot off**.
Without this, the card's FlexBoot option ROM runs during POST, hits the same mismatch and logs a fatal error before
Windows even starts. *Whether the fix also works with CSM disabled was not tested* - if you try it, please report.

### 7.3 Prepare the probe USB stick (read-only probe)
You need a USB stick formatted **FAT32** (UEFI cannot read exFAT/NTFS; for sticks > 32 GB use Rufus:
*Boot selection: Non bootable*, *Partition scheme: MBR*, *File system: Large FAT32*). Then:
```powershell
cd <this repository>\windows
.\New-ProbeUsb.ps1 -UsbDrive E:          # your stick's letter
```
The script finds the Mellanox card and its root port, downloads the UEFI Shell (SHA256 checked) and writes a
**read-only** probe script to the stick. (Want to look first? `.\New-ProbeUsb.ps1 -PreviewDir .\preview`.)

### 7.4 Boot the probe
Restart → boot menu (**ASRock: F11**, others: F8/F12/Esc) → **`UEFI: <your stick>`**.
Do not press anything during the 5 s countdown. The probe reads 2 × 256 bytes of PCI configuration space
(nothing is written), then asks for a key and starts Windows.

### 7.5 Analyse (changes nothing)
```powershell
.\Install-MpsFix.ps1 -ProbeFile E:\mpsfix\probe.txt -GenerateOnly
```
Expected output (test system):
```
Card      08:00.0  ID 0x100715B3  PCIe cap 0x60  DevCap MPS supported 512 B  DevCtl 0x2000 -> MPS 128 B  DevSta 0x0000
Root port 00:1C.4  ID 0x7A3C8086  PCIe cap 0x40  DevCap MPS supported 256 B  DevCtl 0x0020 -> MPS 256 B  buses 0x00080800
MISMATCH CONFIRMED: card 128 B < root port 256 B. Fix: write card DevCtl 0x2020 at offset 0x68 before Windows starts.
```
* `No Max Payload Size mismatch` → **stop, this fix does not apply** (unless the probe ran on one of the rare
  "lucky" boots - repeat the probe once more to be sure).
* The generated `startup.nsh` and `ref.txt` are in `generated\EFI\mpsfix\` - read them, they are short.

### 7.6 Install
```powershell
.\Install-MpsFix.ps1 -ProbeFile E:\mpsfix\probe.txt
```
What it does (and nothing else):
1. checks: administrator, Secure Boot off, BitLocker not active, no previous installation;
2. exports a **backup of the boot configuration** (`bcdedit /export`) into `generated\`;
3. copies `shellx64.efi`, `startup.nsh`, `ref.txt` to `\EFI\mpsfix\` on the EFI system partition (hash-verified);
4. creates the boot entry **"PCIe MPS fix (UEFI Shell)"** (`bcdedit /copy {bootmgr}` + new path) and puts it first;
5. clears the entry's *hidden* flag (Windows creates such entries hidden, and ASRock/AMI firmware then skips them).

If any step fails, the half-created boot entry is removed again.

### 7.7 Put the entry first in the BIOS
Firmware often re-sorts the boot order itself. Restart → BIOS setup → **Advanced mode (ASRock: F6) → Boot**:
* **Boot Option #1 = "PCIe MPS fix (UEFI Shell)"**
* if there is a *UEFI Hard Disk Drive BBS Priorities* list, move it above *Windows Boot Manager* there too.
Save and exit (F10).

### 7.8 Verify
Watch the boot: a black UEFI Shell screen, a 5 s countdown and `mpsfix: card 08:00.0 MPS set to 256 B`,
then Windows starts. In Windows (admin PowerShell):
```powershell
.\Test-MpsFix.ps1
```
Expected: all lines `[ OK ]`, ending with `RESULT: everything OK` (see next section).

## 8. What you should see

```
[ OK ] Secure Boot is off
[ OK ] Boot entry Boot0005 'PCIe MPS fix (UEFI Shell)' -> \EFI\mpsfix\shellx64.efi
[ OK ] Boot0005 is visible
[ OK ] Boot0005 is first in BootOrder
[ OK ] This boot was started through Boot0005
[ OK ] \EFI\mpsfix\shellx64.efi present
[ OK ] \EFI\mpsfix\startup.nsh present
[ OK ] \EFI\mpsfix\ref.txt present
[ OK ] now.txt matches ref.txt (all three safety checks passed at the last shell run)
[ OK ] mlx4_bus initialized the card (event 6)
[ OK ] Mellanox ConnectX-3 Pro Ethernet Adapter #3 - OK (driver 5.50.14740.0)
[ OK ] Mellanox ConnectX-3 PRO VPI (MT04103) Network Adapter - OK (driver 5.50.14740.0)
[info] Mellanox ConnectX-3 Pro Ethernet Adapter #3: Up 40 Gbps
RESULT: everything OK
```
(Boot#### numbers differ per system.) `now.txt` is written by the shell at every boot and contains the three values
it read - it is the proof that the script ran and the interlock passed.

## 9. Daily use and maintenance

* **Fast Startup** (Windows default): after *Shut down* Windows resumes its saved state. If the card ever fails
  after a cold power-on, simply use **Restart** once. To avoid this entirely, disable Fast Startup
  (Control Panel → Power Options → *Choose what the power buttons do*).
* **BIOS update or CMOS reset:** boot entries and BIOS settings are reset - the card fails again. Run
  `Uninstall-MpsFix.ps1`, then the probe and `Install-MpsFix.ps1` again (the new BIOS may also have fixed the bug -
  the probe will tell you).
* **Big Windows updates** may put *Windows Boot Manager* first again → set Boot Option #1 again in the BIOS.
* **Sleep (S3):** not yet tested on the test system - check once that the card still works after waking up.
* **Throughput:** in a chipset slot the card may get fewer PCIe lanes (test board: Gen3 x4 ≈ 31.5 Gb/s raw,
  ~25 Gb/s real) - the 40 GbE link comes up, but cannot be saturated.

## 10. Uninstall and recovery

* **Uninstall:** `.\Uninstall-MpsFix.ps1` (admin) - deletes the boot entry and `\EFI\mpsfix`. Nothing else.
* **Boot stops at `Shell>`:** type `exit` and Enter - the firmware continues with Windows Boot Manager.
* **Shell does not appear at all:** BIOS boot override / boot menu → *Windows Boot Manager* always works.
* **Boot configuration backup:** `generated\bcd-backup-*` (`bcdedit /import <file>` restores it).
* **NVRAM backup of the entry before it was made visible:** `generated\Boot####-before-unhide-*.bin`.

## 11. Troubleshooting

| What you see | Meaning / what to do |
|---|---|
| `New-ProbeUsb.ps1`: drive is exFAT/NTFS | Reformat the stick as (Large) FAT32 with Rufus (section 7.3). |
| Firmware "Launch EFI Shell" just reboots | Same - the stick is not FAT32, or `shellx64.efi` is missing in its root. |
| Analysis: `No Max Payload Size mismatch` | Not this bug (or a "lucky" boot - probe once more). |
| Analysis: card behind a PCIe switch | Not supported by the scripts. Section 12 explains the manual way. |
| Shell does not appear at boot | Entry not first / hidden → BIOS Advanced → Boot Option #1; `Test-MpsFix.ps1` shows `HIDDEN`/`not first`. |
| `mpsfix: check failed - nothing written` | Something changed (device, bus numbers, BIOS). Compare `now.txt` with `ref.txt` on the EFI partition; re-run the probe + install. |
| Card works, ports fail: *interface mismatch 304 vs 302* | Bus and ETH driver from different packages - section 7.1. |
| `Test-MpsFix.ps1`: all OK but card still Code 43 | Make sure you used Restart (Fast Startup), check AER with WinMFT (section 3D) and open an issue. |
| Installer: BitLocker is ON | `Suspend-BitLocker -MountPoint C: -RebootCount 3`, then run again. |

## 12. Manual method (no scripts)

For experts or unusual setups. Find the card and its root port with `lspci -vv` in a Linux live system (or in the
UEFI Shell with `pci`). Note: bus/device/function of both, and the offset of the *Express* capability
(card: usually `0x60`; Device Control = capability + 8).

In the UEFI Shell (`mm` address format for `-pci` is `bbddffrr`, hex):
```
mm 08000000 -pci -w 4 -n        # card vendor/device, e.g. 0x100715B3
mm 08000068 -pci -w 2 -n        # card Device Control, e.g. 0x2000 = MPS 128 B
mm 001C0448 -pci -w 2 -n        # root port Device Control, e.g. 0x0020 = MPS 256 B
mm 08000068 2020 -pci -w 2 -n   # set card MPS to 256 B (bits 7:5 = 001), keep the other bits
exit                            # back to the firmware, then boot Windows Boot Manager
```
MPS field = bits 7:5 of Device Control: `000` = 128 B, `001` = 256 B, `010` = 512 B.
Never set the card higher than the root port. The example values are from the test system - yours will differ.

## 13. Tested hardware

| Component | Test system |
|---|---|
| Motherboard | ASRock **B760 Pro RS/D4**, BIOS 12.04 |
| CPU | Intel Core i7-14700KF |
| Slot | PCIE3 (chipset root port #5, link Gen3 x4); PCIE4 (chipset, x1) showed the same failure |
| OS | Windows 11 Pro 25H2 (build 26200) |
| Card | Mellanox ConnectX-3 Pro EN **MCX314A-BCCT** (2 × 40GbE QSFP), PCI 15B3:1007 |
| Firmware | 2.38.5000, 2.42.5000, 2.43.7028 - all affected; fix tested with 2.43.7028 |
| Driver | inbox 5.50.14695 and WinOF 5.50.53000 (5.50.14740) - both affected; fix tested with 5.50.14740 |
| BIOS settings | CSM enabled, network option ROM not launched, Secure Boot off |
| UEFI Shell | pbatard/UEFI-Shell 26H2 (EDK2 edk2-stable202608) |
| Measured | card DevCtl `0x2000` (128 B) under root port `00:1c.4` DevCtl `0x0020` (256 B) |
| Linux check | Ubuntu 26.04 live: `Max Payload Size set to 256 (was 128, max 512)`, card works |
| Result | card initializes on every boot, Ethernet link 40 Gbps, `Test-MpsFix.ps1` all OK |

Values from the test system: [`examples/asrock-b760-pro-rs-d4/`](examples/asrock-b760-pro-rs-d4).

## 14. FAQ

**Why not just fix the register from Windows?**
Tried: Windows restores its boot-time copy of the device's configuration whenever the device starts, so the
value went back to 128 B within ~0.2 s and the driver failed again. It has to be correct *before* Windows boots.

**Can the card firmware fix it?** No. MPS is programmed by the host (BIOS/OS); the firmware INI has no such setting.

**Why does it sometimes work without the fix?** On some boots the BIOS takes a different path (seen together with a
long POST and a UEFI error record) that apparently leaves the card at 256 B. Windows just inherits the result.

**Could I set the root port to 128 B instead?** That would also remove the mismatch and is what some BIOSes do.
This project mirrors Linux (raise the endpoint) because it only touches the Mellanox card.

**Other cards?** Any PCIe device can be hit by such a BIOS mismatch; ConnectX-3 is just strict about it. The scripts
only accept Mellanox devices, but the method (section 12) is generic.

**Does this damage anything?** It writes one volatile register at boot and adds a boot entry. Nothing is flashed.

## 15. Repository layout

```
1-CHECK.cmd             "Is my card affected?" (read-only)           -> windows\Check-MyCard.ps1
2-FIX.cmd               guided installation (run twice)             -> windows\Fix-Wizard.ps1
3-TEST.cmd              "Did it work?" after a restart (read-only)  -> windows\Test-MpsFix.ps1
UNINSTALL.cmd           remove the fix                               -> windows\Uninstall-MpsFix.ps1
windows/
  Check-MyCard.ps1      Windows-only diagnosis and verdict
  Fix-Wizard.ps1        the guided installation
  MpsFix.Common.ps1     shared helpers (UEFI variables, EFI partition, PCI locations)
  New-ProbeUsb.ps1      step 7.3 - read-only probe stick
  Install-MpsFix.ps1    steps 7.5/7.6 - analysis (-GenerateOnly) and installation
  Test-MpsFix.ps1       step 7.8 - read-only verification
  Uninstall-MpsFix.ps1  removal
linux/check-mps.sh      diagnosis from a Linux live USB
docs/technical-details.md       full analysis and evidence
docs/vendor-support-ticket.md   template to report the BIOS bug to your board vendor - the real fix is a BIOS fix,
                                the more people report it, the more likely vendors fix it
examples/asrock-b760-pro-rs-d4/ generated script and values of the test system
```

## 16. Credits, license, disclaimer

* Scripts and documentation: MIT License (see [LICENSE](LICENSE)).
* UEFI Shell: [TianoCore EDK2](https://github.com/tianocore/edk2) (BSD-2-Clause-Patent), binary builds by
  [pbatard/UEFI-Shell](https://github.com/pbatard/UEFI-Shell). Not redistributed here - downloaded and hash-checked.
* Mellanox, ConnectX, WinOF are trademarks of NVIDIA. ASRock is a trademark of ASRock Inc. This project is not
  affiliated with either.
* Provided "as is", without warranty. You are responsible for changes to your system.
