#!/usr/bin/env bash
# READ-ONLY diagnosis from a Linux live USB (e.g. Ubuntu "Try Ubuntu"): does the BIOS leave the Mellanox card
# with a smaller PCIe Max Payload Size (MPS) than its root port? Linux fixes this automatically at boot and logs
#   pci 0000:08:00.0: Max Payload Size set to 256 (was 128, max 512)
# If you see such a line for your card, the Windows fix in this repository applies to you.
# Usage:  sudo bash check-mps.sh
set -u
if [ "$(id -u)" -ne 0 ]; then echo "Please run with sudo (dmesg and lspci -vv need root)."; exit 1; fi
command -v lspci >/dev/null 2>&1 || { echo "lspci not found (install pciutils)"; exit 1; }

klog() { dmesg 2>/dev/null || journalctl -k -b --no-pager 2>/dev/null; }

echo "== Kernel: Max Payload Size changes made by Linux at boot =="
klog | grep -i "max payload size" || echo "(none)"
echo
echo "== Kernel: mlx4 driver =="
klog | grep -iE "mlx4_core|mlx4_en" | head -n 20 || true
echo

found=0
for dev in $(lspci -D -d 15b3: | awk '{print $1}'); do
  found=1
  rp=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$dev")")")
  echo "== Card $dev =="
  lspci -s "$dev"
  lspci -vv -s "$dev" | grep -E "DevCap:|MaxPayload|LnkSta:" | sed 's/^/    /'
  echo "-- upstream port $rp"
  lspci -s "$rp"
  lspci -vv -s "$rp" | grep -E "MaxPayload|Root Port" | sed 's/^/    /'
  if klog | grep -i "$dev" | grep -qi "Max Payload Size set to"; then
    echo ">>> VERDICT: Linux had to change the MPS of $dev at boot -> the BIOS leaves an MPS mismatch."
    echo ">>>          The Windows Code 43 / MAP_FA -5 problem is explained by this; the Windows fix applies."
  else
    echo ">>> No MPS correction logged for $dev - this fix probably does NOT apply to your problem."
  fi
  echo
done
[ "$found" -eq 1 ] || echo "No Mellanox (15b3) PCI device found."
echo "Tip: save this output, e.g.  sudo bash check-mps.sh | tee mps-report.txt"
