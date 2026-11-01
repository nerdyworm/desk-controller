# Standing Desk bar widget (`nerdyworm.desk`)

Omarchy bar widget for the Arduino desk controller in `~/code/computer/desk`.

- Bar label shows the current height in cm. Left-click opens the panel,
  right-click toggles sit/stand, middle-click stops.
- Panel: Sit / Stand presets, Up / Down nudge, Stop, go-to-height, and
  "save current height as" sit or stand preset (persists to the Nano's EEPROM).
- Keys while the panel is open: S sit, T stand, U/D nudge, X stop,
  arrows change the go-to value, Enter goes.

The widget runs `scripts/desk-bridge` (= `desk.py pipe`) as a long-lived child
so the serial port stays open. Nothing else may use the port while the shell is
running; close the widget's connection first with `omarchy plugin disable
nerdyworm.desk` if you need `desk.py` or `prog.py` directly.

IPC (handy for Hyprland keybinds):

```
omarchy-shell nerdyworm.desk sit
omarchy-shell nerdyworm.desk stand
omarchy-shell nerdyworm.desk togglePreset
omarchy-shell nerdyworm.desk go 95
omarchy-shell nerdyworm.desk stop
omarchy-shell nerdyworm.desk status
```

Set `DESK_CLI` in the shell's environment if desk.py moves.
