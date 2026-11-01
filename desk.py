#!/usr/bin/env python3
"""Host-side CLI for the desk controller. Stdlib only (no pyserial needed).

  ./desk.py status            ./desk.py sit         ./desk.py stand
  ./desk.py go 95             ./desk.py h           ./desk.py stop
  ./desk.py up 500            ./desk.py pulse 6 300 ./desk.py probe
  ./desk.py set up 5          ./desk.py save        ./desk.py help
  ./desk.py shell             interactive console
  ./desk.py pipe              bridge mode: stdin lines -> desk, desk lines -> stdout
                              (used by the Omarchy bar widget)

Set DESK_PORT to override port auto-detection (/dev/ttyUSB0 by default).
"""
import glob, os, select, sys, termios, time

BAUD = termios.B115200


def find_port():
    p = os.environ.get("DESK_PORT")
    if p:
        return p
    ports = sorted(glob.glob("/dev/ttyUSB*"))
    if not ports:
        sys.exit("No /dev/ttyUSB* found; set DESK_PORT or plug the Nano in with a data cable.")
    return ports[0]


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0
    oflag = 0
    cflag = (cflag & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.HUPCL)) | termios.CS8 | termios.CREAD | termios.CLOCAL
    # HUPCL cleared: DTR stays asserted after close, so reopening does not reset the Nano.
    lflag = 0
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, BAUD, BAUD, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_lines(fd, timeout, stop_prefixes=None, echo=True):
    """Read lines until a line starts with one of stop_prefixes or timeout elapses."""
    buf = b""
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        r, _, _ = select.select([fd], [], [], min(remaining, 0.5))
        if not r:
            continue
        chunk = os.read(fd, 256)
        if not chunk:
            continue
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            text = line.decode("ascii", "replace").strip()
            if not text:
                continue
            if echo:
                print(text, flush=True)
            if stop_prefixes and any(text.startswith(p) for p in stop_prefixes):
                return text


def wait_ready(fd):
    """If the open reset the board, a READY banner arrives within ~2 s. Otherwise fall through."""
    line = read_lines(fd, 2.5, ("READY",), echo=False)
    if line:
        read_lines(fd, 0.3, echo=False)  # swallow the CFG line
        return True
    return False


def send(fd, cmd, timeout):
    os.write(fd, (cmd + "\n").encode())
    first = cmd.split()[0] if cmd.split() else ""
    if first in ("sit", "stand", "go"):
        line = read_lines(fd, 1.0, ("OK", "ERR"))
        if line and line.startswith("OK"):
            read_lines(fd, timeout, ("DONE", "STOP"))
    elif first == "help":
        read_lines(fd, 1.5)
    else:
        read_lines(fd, timeout, ("OK", "ERR", "H ", "STATUS", "CFG", "DONE", "STOP"))


def shell(fd):
    print("desk shell: type commands, 'quit' to exit")
    while True:
        try:
            cmd = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if cmd in ("quit", "exit"):
            return
        if cmd:
            send(fd, cmd, 70)


def pipe():
    """Long-lived bridge for GUI front ends. Keeps the port open so every command is instant.

    stdout lines: PORT <path> once connected, then every line the desk prints (H, OK, DONE,
    STOP, ERR, STATUS, CFG, READY). OFFLINE <reason> and a non-zero exit if the port is gone.
    stdin: one desk command per line. EOF on stdin ends the bridge.
    """
    out = os.fdopen(sys.stdout.fileno(), "w", buffering=1)
    ports = [os.environ["DESK_PORT"]] if os.environ.get("DESK_PORT") else sorted(glob.glob("/dev/ttyUSB*"))
    if not ports:
        out.write("OFFLINE no /dev/ttyUSB* (is the desk plugged in?)\n")
        sys.exit(1)
    try:
        fd = open_port(ports[0])
    except OSError as e:
        out.write("OFFLINE %s: %s\n" % (ports[0], e.strerror or e))
        sys.exit(1)
    out.write("PORT %s\n" % ports[0])
    stdin_fd = sys.stdin.fileno()
    serial_buf = b""
    stdin_buf = b""
    try:
        while True:
            r, _, _ = select.select([fd, stdin_fd], [], [], 1.0)
            if fd in r:
                try:
                    chunk = os.read(fd, 256)
                except OSError as e:
                    out.write("OFFLINE port lost: %s\n" % (e.strerror or e))
                    sys.exit(2)
                if not chunk:
                    out.write("OFFLINE port closed\n")
                    sys.exit(2)
                serial_buf += chunk
                while b"\n" in serial_buf:
                    line, serial_buf = serial_buf.split(b"\n", 1)
                    text = line.decode("ascii", "replace").strip()
                    if text:
                        out.write(text + "\n")
            if stdin_fd in r:
                data = os.read(stdin_fd, 1024)
                if not data:
                    return
                stdin_buf += data
                while b"\n" in stdin_buf:
                    line, stdin_buf = stdin_buf.split(b"\n", 1)
                    cmd = line.strip()
                    if cmd:
                        os.write(fd, cmd + b"\n")
    finally:
        os.close(fd)


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return
    if args[0] == "pipe":
        pipe()
        return
    port = find_port()
    fd = open_port(port)
    try:
        wait_ready(fd)
        if args[0] == "shell":
            shell(fd)
        else:
            send(fd, " ".join(args), 70)
    except KeyboardInterrupt:
        os.write(fd, b"stop\n")
        print("\n(sent stop)")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
