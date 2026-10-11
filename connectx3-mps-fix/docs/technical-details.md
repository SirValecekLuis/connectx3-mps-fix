# Technical details: why the ConnectX-3 fails in Windows with Code 43 / `MAP_FA -5`

This is the full analysis behind the fix, with the evidence collected on the test system
(ASRock B760 Pro RS/D4, Mellanox ConnectX-3 Pro MCX314A-BCCT). Register values are real measurements.

## 1. Symptom in Windows

Device Manager: *Mellanox ConnectX-3 PRO VPI (MT04103) Network Adapter* - **Code 43**
(`CM_PROB_FAILED_POST_START`). The System event log shows, every failed boot, within ~0.15 s of the driver start:

| Source | ID | Text |
|---|---|---|
| mlx4_bus | 48 | `Execution of FW command failed. op 0xfff, status 0x1, errno -5, token 0xffff, in_modifier 0x100 ...` |
| mlx4_bus | 7 | `MAP_FA command failed with error -5. The adapter card is non-functional. Most likely a FW problem. Please burn the last FW and restart the mlx4_bus driver.` |
| mlx4_bus | 73 | `Driver startup failed because the hca could not be initialized.` |

`op 0xfff` is `MAP_FA` (map firmware area), `status 0x1` is the firmware's *internal error* ("such as a bus
error"), `-5` is `-EIO`. The text "Most likely a FW problem" is a generic driver message - re-flashing firmware
does **not** help (tested with 2.38.5000, 2.42.5000 and 2.43.7028).

## 2. What the card itself reports (PCIe AER)

Read with WinMFT (`win_mini_setpci -s mt4103_pciconf0 <offset>`) right after a failure:

| Register | Value | Meaning |
|---|---|---|
| Device Control (0x68) | `0x2000` | **Max Payload Size 128 B**, Max Read Request 512 B |
| Device Status (0x6A) | `0x000D` / `0x0005` | Fatal error detected (+ correctable / unsupported request) |
| AER Uncorrectable Status (0x158) | `0x00040000` | bit 18 = **Malformed TLP** |
| AER First Error Pointer | `18` | the Malformed TLP was the first error |
| AER Header Log | `4a000040 00000100 08001000 00000000` | the offending packet, decoded below |

Header log decoded:

* `0x4A` = **CplD** (completion with data), length `0x040` = 64 DW = **256 bytes**
* completer `00:00.0` (the host bridge), byte count `0x100` = 256
* requester `08:00.0` (the card), tag `0x10`, lower address `0`

So the root complex answered a DMA read of the card with a **256-byte** completion. The packet is otherwise
well-formed (length matches byte count, aligned, no TLP digest). The only PCIe rule it breaks is
*"payload larger than the receiver's Max_Payload_Size"* - the card was set to **128 B**.

Its root port (PCH Root Port #5, `00:1c.4`) has Device Control `0x0020` = **MPS 256 B**. Every other endpoint
in the PC (GPU, both NVMe drives, onboard 2.5GbE) is also at 256 B. Only the Mellanox card is left at the
power-on default of 128 B.

Why exactly `MAP_FA`? It is the first firmware command for which the card has to **read** host memory (DMA)
in bigger chunks. Earlier steps (e.g. `QUERY_FW`) only make the card *write* to memory, and the card never sends
packets larger than its own 128 B setting - so those work. The first 256-byte read completion kills it.

## 3. Proof that the BIOS leaves the mismatch

Booting **Ubuntu 26.04 live (kernel 7.0)** on the same PC, the kernel log shows:

```
pci 0000:08:00.0: Max Payload Size set to 256 (was 128, max 512)
mlx4_core 0000:08:00.0: ... 31.504 Gb/s available PCIe bandwidth, limited by 8.0 GT/s PCIe x4 link at 0000:00:1c.4
mlx4_en: enp8s0: Link Up
```

Linux's `pci_configure_mps()` (drivers/pci/probe.c, default `pcie_bus_config`) compares every device with its
upstream bridge at enumeration and fixes a smaller endpoint MPS. That line proves the BIOS hands over the
card with 128 B under a 256 B root port. In addition, `mlx4_core` saves and restores `PCI_EXP_DEVCTL` around its
own HCA reset (`mlx4_reset()`), so Linux never loses the corrected value. Result: the same card works in Linux
on the same PC, and on a Xeon server where BIOS sets card and root port both to 256 B.

Windows (pci.sys) does not reconcile MPS. It records the configuration it finds at boot and restores exactly
that whenever the device is started. The WinOF `mlx4_bus` driver does not touch MPS either.

## 4. Experiments on the test system

| Experiment | Result |
|---|---|
| Write MPS 256 into the card from Windows (WinMFT), then restart the device | Reverted to 128 within ~180 ms of the device start (no chip reset), MAP_FA failed again with the identical malformed 256 B completion |
| Same, but card disabled during boot, value read before the driver ever ran | Card already 128 at boot; 256 written; reverted to 128 on enable |
| CSM enabled + "Launch PXE OpROM Policy: Do not launch" (card's FlexBoot ROM not run at POST) | No fatal error at POST any more, but card **still 128 B** before Windows → the option ROM is not what sets 128 |
| Card moved from chipset slot PCIE4 (x1) to PCIE3 (x4) | Same failure |
| Ubuntu live USB | Linux fixes MPS → card works, 40 GbE link up |
| UEFI Shell `mm 08000068 2020 -pci -w 2` before Windows (this repository) | **Card works in Windows**, Windows keeps 256 B even across driver restarts |

## 5. Why it "sometimes worked"

Before the firmware/driver changes, the card initialized in roughly 1 of 5 boots. Those boots coincided 1:1 with
an unusually long POST (~28 s instead of ~12 s) and a UEFI BERT record (WHEA event 3), i.e. the BIOS took a
different (error/recovery) path - presumably one that left the card at 256 B. One more random success was seen
after entering BIOS setup. Because Windows just reuses whatever the BIOS left, the result looked random. This
part is an interpretation; the mechanism of the failure itself (sections 2-4) is measured.

## 6. Ruled out

| Hypothesis | Why not |
|---|---|
| Defective card | Works in Linux on the same PC and in another server; flash verify OK; AER shows a spec-correct reaction |
| Signal integrity / slot / link | No receiver, bad TLP, bad DLLP or replay errors; Gen3 equalization complete; same in x1 and x4 slot |
| Power / temperature | Card at 57 °C; failure is a deterministic malformed-TLP, not random |
| IOMMU / VBS / Hyper-V | The packet is rejected by the card's receiver before any remapping |
| Driver version | Inbox 5.50.14695 and WinOF 5.50.14740 fail identically |
| Firmware version | 2.38.5000, 2.42.5000 and 2.43.7028 fail identically |
| ASPM | Disabled on the link |

## 7. The workaround

Set the card's MPS field to the root port's value **before** Windows boots, so Windows records and keeps the
correct value. On the test board that is one 16-bit write: card `08:00.0`, register `0x68`, `0x2000` → `0x2020`.
The UEFI Shell (`mm` command) does it from a boot entry that runs before Windows Boot Manager and then chain-loads
it. A safety interlock compares three register values with the values recorded by a read-only probe and skips the
write if anything changed (other device at that address, different bus numbering, or a BIOS update that changed
the root port's MPS - writing 256 B into the card under a 128 B root port would create the *opposite* mismatch).

The proper fix belongs in the BIOS (program the endpoint's MPS to match the root port, as the PCIe spec expects
firmware to do). See [vendor-support-ticket.md](vendor-support-ticket.md).
