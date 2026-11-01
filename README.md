# Standing desk controller

An Arduino Nano that raises and lowers a motorised standing desk to a
requested height, driven from a PC over USB serial, with an Omarchy bar
widget on top.

![Wiring schematic](docs/schematic.svg)

**How it works.** Two 5 V relay modules sit across the UP and DOWN buttons
of the desk's own hand controller, so the Nano "presses" the buttons. An
HC-SR04 ultrasonic sensor hangs from the desk crossbar and measures the
distance to the floor. The firmware runs a closed loop: engage a relay,
watch the height, release a little before the target so the desk coasts
onto it, then correct if needed.

## Hardware

| Part | Connection |
|------|------------|
| Arduino Nano (ATmega328P, CH340) | USB to the PC; its 5 V pin powers everything else |
| HC-SR04 | VCC → 5 V, GND → GND, TRIG → D3, ECHO → D2 |
| Relay 1 (UP) | VCC → 5 V, GND → GND, IN → D4, COM/NO across the UP button |
| Relay 2 (DOWN) | VCC → 5 V, GND → GND, IN → D5, COM/NO across the DOWN button |
| Electrolytic capacitor | Across 5 V and GND, for decoupling |

The relay contacts reach the hand controller through a 4-pin JST. Check
your controller's pinout with a multimeter first: each button is a pair of
lines that get shorted when pressed. Relay modules here are high-level
trigger (`activelow 0`); set `activelow 1` for low-level trigger boards.

The firmware's pin numbers are defaults. If your wiring differs, change
them over serial (`set trig 3`, `set echo 2`, ...) and `save`; there is also
a `scan` command that finds the sensor on any pin pair and a `pulse` command
to work out which pin drives which relay.

## Repository layout

- `firmware/desk_controller/desk_controller.ino` – the sketch
- `desk.py` – host CLI and interactive shell over USB serial, stdlib only
- `prog.py` – stdlib STK500v1 programmer for boards whose USB auto-reset is broken
- `flash.sh` – ordinary avrdude flasher for boards whose auto-reset works
- `omarchy-plugin/nerdyworm.desk/` – Omarchy bar widget
- `build/desk_controller.ino.hex` – compiled firmware
- `docs/schematic.svg` – wiring diagram

## Building and flashing

```
arduino-cli core install arduino:avr
arduino-cli compile --fqbn arduino:avr:nano:cpu=atmega328 --output-dir build firmware/desk_controller
./flash.sh            # avrdude; works when the board's DTR auto-reset works
```

Use `cpu=atmega328old` for a Nano with the old 57600 baud bootloader.

If avrdude reports "not in sync" at both baud rates, the board's auto-reset
is probably dead (mine is). `prog.py` gets around that by waiting for a
manual reset:

```
./prog.py --baud 115200 --wait 90 build/desk_controller.ino.hex
```

Tap the Nano's reset button once every two seconds while it waits. When
it prints `SYNC OK`, stop touching the board. It backs up the existing
flash to `backup/`, writes the new firmware, and verifies it.

On Linux your user needs access to the serial device, usually by being in
the `uucp` or `dialout` group.

## Serial protocol

115200 baud, one command per line. Replies start with `OK`, `ERR`, `H`,
`STATUS`, `CFG`, `DONE` or `STOP`. The board prints `READY` at boot.

```
h | height          read height (cm)
status | cfg        show state / configuration
sit | stand         go to preset
go <cm>             go to height
stop                release relays, cancel target
up [ms] | down [ms] pulse a relay (default 500, max 3000)
pulse <pin> [ms]    pulse any pin 2-12 (to find relay wiring)
probe               auto-detect trig/echo order
scan                find the sensor on any pin pair
set <key> <val>     trig echo up down activelow offset sit stand tol earlyup earlydown maxmove
save | load | defaults
```

During a move the board streams `H <cm>` lines and finishes with
`DONE <cm>` or `STOP <reason>`. Configuration lives in EEPROM with a
magic number, version and CRC, so a corrupt or missing config falls back
to defaults.

Heights are whatever the sensor sees, crossbar to floor by default. Set
`offset` to the difference between that and your desktop height if you
would rather think in desktop height.

## Host CLI

```
./desk.py stand
./desk.py sit
./desk.py go 95
./desk.py h
./desk.py stop          # Ctrl-C during a move also sends stop
./desk.py shell         # interactive console
./desk.py pipe          # long-lived bridge used by the bar widget
```

`desk.py` auto-detects `/dev/ttyUSB*`; set `DESK_PORT` to override. It
opens the port with HUPCL cleared so reconnecting does not reset the Nano.

## Calibration

```
./desk.py shell
> scan                  # confirm the sensor pins
> pulse 4 1500          # engage a relay for 1.5 s and watch which way the desk goes
> set sit 72
> set stand 110
> save
```

If moves stop short or overshoot, adjust `earlyup` / `earlydown`, the
distance in cm before the target at which the relay is released, and
`save`. The first leg of a move uses the margin; corrections do not.

## Omarchy bar widget

`omarchy-plugin/nerdyworm.desk/` is a bar widget for the
[Omarchy](https://omarchy.org) shell. Copy it to
`~/.config/omarchy/plugins/nerdyworm.desk/`, set `DESK_CLI` if `desk.py`
is not at `~/code/computer/desk/desk.py`, then:

```
omarchy-shell shell rescanPlugins
omarchy plugin enable nerdyworm.desk
```

The bar label shows the current height. Left-click opens a panel with
sit/stand presets, up/down nudges, stop, go-to-height, and "save current
height as" preset. Right-click toggles between presets, middle-click stops.
The widget keeps the serial port open through `desk.py pipe`, so disable
it (`omarchy plugin disable nerdyworm.desk`) before using `desk.py` or
`prog.py` directly.

Keybind-friendly IPC:

```
omarchy-shell nerdyworm.desk sit|stand|togglePreset|go <cm>|stop|status
```

## Safety built into the firmware

- Relays are driven to their inactive level before the pins become outputs, so nothing blips at boot.
- Both relays are never on at once: release, 20 ms gap, then engage.
- A move stops after `maxmove` ms (default 25 s), after five bad sensor reads, or on `stop`.
- Manual `up`/`down`/`pulse` are capped at 3 s.

## License

MIT
