# Template: support ticket for your motherboard vendor

A BIOS fix makes the whole workaround unnecessary. Send this to your board vendor (fill in the brackets,
attach the output of `linux/check-mps.sh`). Do not include serial numbers or MAC addresses - they are not needed.

---

**Subject:** BIOS leaves PCIe endpoint Max Payload Size at 128 B under a 256 B root port (Malformed TLP, NIC fails in Windows)

**Board / BIOS:** [e.g. ASRock B760 Pro RS/D4, BIOS 12.04]
**CPU / OS:** [e.g. Intel Core i7-14700KF, Windows 11 25H2]
**Device:** [e.g. Mellanox ConnectX-3 Pro MCX314A-BCCT, PCI 15B3:1007] in slot [e.g. PCIE3, chipset root port 00:1c.4]

Hello,

the BIOS programs the chipset PCIe root port [00:1c.4] with **Max_Payload_Size = 256 bytes** (Device Control
0x0020), but leaves the endpoint behind it at the power-on default of **128 bytes** (Device Control 0x2000).
All other devices in the system are set to 256 bytes.

When the endpoint performs its first DMA read, the root complex returns a 256-byte completion. The endpoint
correctly rejects it as a **Malformed TLP** (AER Uncorrectable Status 0x00040000, header log
`4a000040 00000100 08001000 00000000` = CplD, 256 bytes, completer 00:00.0, requester 08:00.0).
In Windows the adapter then fails with Code 43 ("MAP_FA command failed with error -5").

Linux confirms the BIOS state at boot:

```
pci 0000:08:00.0: Max Payload Size set to 256 (was 128, max 512)
```

Linux corrects the value and the adapter works; Windows uses the BIOS configuration as-is and fails.
Writing the endpoint's Device Control to 0x2020 before Windows starts (UEFI Shell `mm`) makes it work in Windows
too, which confirms the cause.

Per the PCI Express Base Specification, the Max_Payload_Size of all functions in a hierarchy must be programmed
consistently (the endpoint must not be lower than what the root port may send). Could you please
- program endpoint MPS to match the root port for devices in this slot (as is done for the other slots), or
- provide a BIOS setup option for "PCIe Max Payload Size" (128 B / 256 B / Auto)?

Thank you.
