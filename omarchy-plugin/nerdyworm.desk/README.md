# Standing Desk bar widget (`nerdyworm.desk`)

Omarchy bar widget for the Arduino desk controller in `~/code/computer/desk`.

The bar label shows the height and the standing time for today, for example `⇅ 74 · 1h20/2h`. A left click opens the panel. A right click moves to the other preset. A middle click stops the desk.

The panel has two tabs. The Desk tab has the Sit and Stand buttons, the standing time for today with a goal bar, and the time at the computer. The Settings tab has the up and down nudges, go-to-height, and the preset save buttons. It also has the tracking and reminder settings.

Keys while the panel is open: S sit, T stand, X stop, Z snooze, arrows change the go-to value, Enter goes.

## Tracking

The widget infers the posture from the height. A height above the midpoint of the two presets counts as standing.

The posture is "away" when you are not at the desk, and away time is not counted. Three signals set away: no keyboard or mouse input for `awayAfterMinutes`, every monitor off or disconnected, or a locked session. The script `scripts/desk-presence` reads the screen and lock state once a minute. Sleep is not a signal. The machine can stay awake all night and the log stays correct.

`scripts/desk-track` writes each posture change to `~/.local/share/desk-controller/posture.jsonl` and computes the totals. Run `scripts/desk-track summary` to see the totals as JSON. The file is plain text, one record per line.

## Time at the computer

Every state except away counts as time at the computer: sit, stand, and unknown (the desk is offline but you are there). The Desk tab shows the total for today, the time of the first activity, a bar for each of the last 7 days, and the 7-day total and average. Run `scripts/desk-track report` for a table of the last 7 days, or `scripts/desk-track report 30` for 30 days.

## Reminders

While you sit for longer than `sitReminderMinutes` inside the work hours, the widget sends a desktop notification. Click the notification to move the desk to the stand preset. If you ignore it, the widget sends it again after `remindRepeatMinutes`. Do-not-disturb hides the notification.

## Settings

The Settings tab writes these keys to the widget entry in `~/.config/omarchy/shell.json`. You can also edit them by hand.

| Key | Default | Meaning |
|-----|---------|---------|
| `goalMinutes` | 120 | Daily standing goal |
| `sitReminderMinutes` | 45 | Remind after this long sitting |
| `remindRepeatMinutes` | 15 | Repeat while you still sit |
| `awayAfterMinutes` | 5 | Idle time before "away" |
| `workHours` | `"08:00-18:00"` | Reminder window |
| `workDays` | `[1,2,3,4,5]` | Reminder days, 0 is Sunday |
| `reminders` | `true` | Reminders on or off |

## Serial port

The widget runs `scripts/desk-bridge` (`desk.py pipe`) as a long-lived child, so the serial port stays open. Nothing else can use the port while the shell runs. Before you use `desk.py` or `prog.py` directly, run `omarchy plugin disable nerdyworm.desk`.

If `desk.py` moves, set `DESK_CLI` for the shell.

## IPC

```
omarchy-shell nerdyworm.desk sit
omarchy-shell nerdyworm.desk stand
omarchy-shell nerdyworm.desk togglePreset
omarchy-shell nerdyworm.desk go 95
omarchy-shell nerdyworm.desk stop
omarchy-shell nerdyworm.desk status
omarchy-shell nerdyworm.desk today
omarchy-shell nerdyworm.desk snooze 30
omarchy-shell nerdyworm.desk remind
omarchy-shell nerdyworm.desk showTab settings
```
