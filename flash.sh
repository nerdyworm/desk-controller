#!/usr/bin/env bash
# Backs up whatever is currently on the Nano, then compiles and uploads the
# desk controller firmware. Usage: ./flash.sh [/dev/ttyUSB0]
set -euo pipefail
cd "$(dirname "$0")"

CLI="${ARDUINO_CLI:-$(command -v arduino-cli || echo "$HOME/.local/bin/arduino-cli")}"
PORT="${1:-$(ls /dev/ttyUSB* 2>/dev/null | head -1 || true)}"
if [[ -z "$PORT" ]]; then
  echo "No /dev/ttyUSB* found. Is the Nano plugged in with a DATA cable? (lsusb should show a CH340 / FTDI device)" >&2
  exit 1
fi
if [[ ! -w "$PORT" ]]; then
  echo "$PORT is not writable by $USER. Fix with:  sudo usermod -aG uucp $USER   (then log out and back in)" >&2
  echo "or for this session only:  sudo chmod a+rw $PORT" >&2
  exit 1
fi

AVRDUDE=$(ls "$HOME"/.arduino15/packages/arduino/tools/avrdude/*/bin/avrdude | head -1)
AVRCONF=$(ls "$HOME"/.arduino15/packages/arduino/tools/avrdude/*/etc/avrdude.conf | head -1)

# The Nano ships with either the old bootloader (57600 baud) or the new one
# (115200). Try both while reading back the old firmware as a backup.
mkdir -p backup
FQBN=""
for baud in 57600 115200; do
  out="backup/old_firmware_$(date +%Y%m%d_%H%M%S)_${baud}.hex"
  echo "== Trying bootloader at $baud baud (reading current flash to $out)"
  if "$AVRDUDE" -C "$AVRCONF" -q -p atmega328p -c arduino -P "$PORT" -b "$baud" -U "flash:r:$out:i"; then
    if [[ $baud == 57600 ]]; then FQBN="arduino:avr:nano:cpu=atmega328old"; else FQBN="arduino:avr:nano:cpu=atmega328"; fi
    echo "== Bootloader responds at $baud; backup saved to $out"
    break
  fi
  rm -f "$out"
done
if [[ -z "$FQBN" ]]; then
  echo "Bootloader did not respond at either baud rate. Try pressing the Nano's reset button right as this script starts, or swap the Nano." >&2
  exit 1
fi

echo "== Compiling"
"$CLI" compile --fqbn "$FQBN" firmware/desk_controller
echo "== Uploading"
"$CLI" upload --fqbn "$FQBN" -p "$PORT" firmware/desk_controller
echo "== Done. Try:  ./desk.py status"
