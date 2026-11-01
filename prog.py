#!/usr/bin/env python3
"""Minimal STK500v1 programmer for the Nano bootloader, stdlib only.

Keeps sending the sync request continuously for --wait seconds so a manual
reset tap anywhere in that window gets caught. On sync it backs up the
current flash, writes the hex, verifies, and exits.

  ./prog.py --baud 57600 --wait 75 build/desk_controller.ino.hex
"""
import argparse, os, select, sys, termios, time

BAUDS = {57600: termios.B57600, 115200: termios.B115200, 19200: termios.B19200}
PAGE = 128
FLASH = 32768


def open_port(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = (a[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)) | termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = BAUDS[baud]
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_exact(fd, n, timeout):
    buf = b""
    end = time.monotonic() + timeout
    while len(buf) < n:
        rem = end - time.monotonic()
        if rem <= 0:
            return buf
        r, _, _ = select.select([fd], [], [], rem)
        if r:
            try:
                buf += os.read(fd, n - len(buf))
            except BlockingIOError:
                pass
    return buf


def drain(fd):
    try:
        while os.read(fd, 4096):
            pass
    except BlockingIOError:
        pass


def cmd(fd, payload, resp_len, timeout=1.0):
    os.write(fd, payload)
    r = read_exact(fd, resp_len, timeout)
    if len(r) != resp_len or r[0] != 0x14 or r[-1] != 0x10:
        raise RuntimeError(f"bad response to {payload[:1]!r}: {r!r}")
    return r[1:-1]


def wait_sync(fd, wait):
    """Spam sync; also note gaps in incoming garbage (a gap = the board reset)."""
    end = time.monotonic() + wait
    last_rx = None
    gaps = 0
    t0 = time.monotonic()
    while time.monotonic() < end:
        # One request per 250 ms: the bootloader only has a 3-byte receive
        # buffer and ignores serial for ~300 ms while it blinks its LED, so
        # spamming faster than this overruns it and misaligns the next command.
        os.write(fd, b"0 ")
        data = b""
        until = time.monotonic() + 0.25
        while time.monotonic() < until:
            r, _, _ = select.select([fd], [], [], until - time.monotonic())
            if not r:
                continue
            try:
                data += os.read(fd, 256)
            except BlockingIOError:
                continue
            now = time.monotonic()
            if last_rx and now - last_rx > 0.8:
                gaps += 1
                print(f"  (board went quiet for {now - last_rx:.1f}s at t={now - t0:.0f}s - reset seen)", flush=True)
            last_rx = now
            if b"\x14\x10" in data:
                return True, gaps
    return False, gaps


def parse_hex(path):
    img = bytearray(b"\xff" * FLASH)
    hi = 0
    top = 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(":"):
            continue
        b = bytes.fromhex(line[1:])
        n, addr, typ = b[0], (b[1] << 8) | b[2], b[3]
        if typ == 0:
            a = (hi << 16) + addr
            img[a:a + n] = b[4:4 + n]
            top = max(top, a + n)
        elif typ == 1:
            break
        elif typ == 4:
            hi = (b[4] << 8) | b[5]
    return bytes(img[:top])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hexfile", nargs="?")
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=57600)
    ap.add_argument("--wait", type=float, default=60)
    ap.add_argument("--backup", default="backup")
    args = ap.parse_args()

    fd = open_port(args.port, args.baud)
    print(f"Listening on {args.port} at {args.baud} for {args.wait:.0f}s. Tap the Nano's reset button now.", flush=True)
    deadline = time.monotonic() + args.wait
    sig = None
    while sig is None and time.monotonic() < deadline:
        ok, gaps = wait_sync(fd, deadline - time.monotonic())
        if not ok:
            print(f"NO SYNC. Resets observed: {gaps}. " + ("Board reset but bootloader never answered at this baud." if gaps else "No reset observed at all (button not pressed, or reset line not working)."))
            sys.exit(1)
        print("SYNC OK - STOP PRESSING RESET, hands off now.", flush=True)
        for attempt in range(8):
            time.sleep(0.05)
            drain(fd)
            try:
                os.write(fd, b"0 ")
                r1 = read_exact(fd, 2, 0.3)
                if r1 != b"\x14\x10":
                    raise RuntimeError(f"sync reply {r1!r}")
                os.write(fd, b"u ")
                r2 = read_exact(fd, 5, 0.5)
                if len(r2) != 5 or r2[0] != 0x14 or r2[-1] != 0x10:
                    raise RuntimeError(f"sig reply {r2!r}")
                sig = r2[1:-1]
                break
            except RuntimeError as e:
                print(f"  resync attempt {attempt + 1}: {e}", flush=True)
        if sig is None:
            print("  lost the bootloader; listening again - tap reset once more, then hands off.", flush=True)
    if sig is None:
        print("Gave up.")
        sys.exit(1)
    print(f"Signature {sig.hex()} " + ("(ATmega328P)" if sig == b"\x1e\x95\x0f" else "(unexpected!)"), flush=True)
    cmd(fd, b"P ", 2)  # enter programming mode

    def load_addr(byte_addr):
        w = byte_addr >> 1
        cmd(fd, bytes([0x55, w & 0xFF, (w >> 8) & 0xFF, 0x20]), 2)

    # backup
    os.makedirs(args.backup, exist_ok=True)
    bk = os.path.join(args.backup, time.strftime("old_firmware_%Y%m%d_%H%M%S.bin"))
    print("Reading current flash for backup...", flush=True)
    old = bytearray()
    for a in range(0, FLASH, PAGE):
        load_addr(a)
        old += cmd(fd, bytes([0x74, PAGE >> 8, PAGE & 0xFF, ord("F"), 0x20]), PAGE + 2, 2.0)
    open(bk, "wb").write(old)
    print(f"Backup saved: {bk} ({len(old)} bytes)", flush=True)

    if not args.hexfile:
        cmd(fd, b"Q ", 2)
        print("No hex given; leaving bootloader.")
        return

    img = parse_hex(args.hexfile)
    print(f"Writing {len(img)} bytes from {args.hexfile}...", flush=True)
    for a in range(0, len(img), PAGE):
        page = img[a:a + PAGE].ljust(PAGE, b"\xff")
        load_addr(a)
        cmd(fd, bytes([0x64, PAGE >> 8, PAGE & 0xFF, ord("F")]) + page + b"\x20", 2, 2.0)
    print("Verifying...", flush=True)
    for a in range(0, len(img), PAGE):
        load_addr(a)
        got = cmd(fd, bytes([0x74, PAGE >> 8, PAGE & 0xFF, ord("F"), 0x20]), PAGE + 2, 2.0)
        exp = img[a:a + PAGE].ljust(PAGE, b"\xff")
        if got != exp:
            print(f"VERIFY FAILED at 0x{a:04x}")
            sys.exit(2)
    cmd(fd, b"Q ", 2)
    print("FLASHED AND VERIFIED. Board is rebooting into the new firmware.")


if __name__ == "__main__":
    main()
