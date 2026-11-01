import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Standing desk control and sit/stand tracking.
//
// Desk commands go through scripts/desk-bridge (desk.py pipe), which keeps
// the serial port open so every command is instant and the height can be
// polled cheaply.
//
// Posture is inferred from the height: above the midpoint of the sit and
// stand presets counts as standing. Changes are logged by scripts/desk-track,
// which also computes today's totals. The posture is "away", and nothing is
// counted, while there has been no input for awayAfterMinutes, while the
// screen is off, or while the session is locked (scripts/desk-presence).
//
// Settings (optional keys on this widget's entry in shell.json):
//   goalMinutes          daily standing goal              (default 120)
//   sitReminderMinutes   remind after this long sitting   (default 45)
//   remindRepeatMinutes  repeat while still sitting       (default 15)
//   awayAfterMinutes     idle time before "away"          (default 5)
//   workHours            "HH:MM-HH:MM" reminder window    (default "08:00-18:00")
//   workDays             JS weekday numbers, 0 = Sunday   (default [1,2,3,4,5])
//   reminders            true/false                       (default true)
BarWidget {
    id: root

    property bool connected: false
    property string portPath: ""
    property real height_cm: -1          // crossbar-to-floor distance; -1 = unknown
    property bool targeting: false       // controller is driving toward targetCm
    property real targetCm: 0
    property real sitCm: 0
    property real standCm: 0
    property string errorMessage: ""
    property string notice: ""
    property int goValue: 0
    property bool goTouched: false
    property bool opened: false
    property bool popoutSwitchClosing: false
    property string tab: "desk"            // desk | settings
    readonly property int nudgeMs: 400
    readonly property real presetMatchCm: 1.5
    readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/nerdyworm.desk"
    readonly property string bridgeHelper: pluginDir + "/scripts/desk-bridge"
    readonly property string trackerHelper: pluginDir + "/scripts/desk-track"
    readonly property string presenceHelper: pluginDir + "/scripts/desk-presence"
    readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
    readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
    readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    readonly property bool haveHeight: connected && height_cm >= 0
    readonly property bool atSit: haveHeight && sitCm > 0 && Math.abs(height_cm - sitCm) <= presetMatchCm
    readonly property bool atStand: haveHeight && standCm > 0 && Math.abs(height_cm - standCm) <= presetMatchCm

    // Posture tracking
    property string posture: "unknown"   // sit | stand | away | unknown
    property int standTodaySec: 0
    property int sitTodaySec: 0
    property int postureSinceSec: 0      // time in the current posture
    property bool screenOff: false       // every monitor is DPMS off or gone
    property bool locked: false          // session lock is up
    property var historyDays: []
    property real snoozeUntil: 0         // unix seconds
    property var trackerQueue: []
    readonly property int goalMinutes: setting("goalMinutes", 120)
    readonly property int sitReminderMinutes: setting("sitReminderMinutes", 45)
    readonly property int remindRepeatMinutes: setting("remindRepeatMinutes", 15)
    readonly property int awayAfterMinutes: setting("awayAfterMinutes", 5)
    readonly property string workHours: setting("workHours", "08:00-18:00")
    readonly property var workDays: setting("workDays", [1, 2, 3, 4, 5])
    readonly property bool remindersEnabled: setting("reminders", true)
    readonly property bool goalMet: standTodaySec >= goalMinutes * 60
    readonly property real goalFraction: goalMinutes > 0 ? Math.min(1, standTodaySec / (goalMinutes * 60)) : 0

    function fmt(v) {
        return v >= 0 ? Number(v).toFixed(1) : "--";
    }

    // 4500 -> "1h15", 1500 -> "25m"
    function fmtDur(sec) {
        var s = Math.max(0, Math.floor(sec));
        var h = Math.floor(s / 3600);
        var m = Math.floor((s % 3600) / 60);
        if (h > 0)
            return h + "h" + (m < 10 ? "0" + m : m);

        return m + "m";
    }

    // 120 -> "2h", 90 -> "1h30"
    function fmtGoal() {
        var h = Math.floor(goalMinutes / 60);
        var m = goalMinutes % 60;
        if (h > 0 && m === 0)
            return h + "h";

        return fmtDur(goalMinutes * 60);
    }

    function barLabel() {
        if (!connected)
            return "⇅ ✕";

        var h = haveHeight ? Number(height_cm).toFixed(0) : "--";
        var s = goalMet ? fmtDur(standTodaySec) + " ✓" : fmtDur(standTodaySec) + "/" + fmtGoal();
        return "⇅ " + h + " · " + s;
    }

    function stateLabel() {
        if (!connected)
            return "OFFLINE";

        if (targeting)
            return "MOVING";

        if (posture === "sit")
            return "SITTING";

        if (posture === "stand")
            return "STANDING";

        if (posture === "away")
            return "AWAY";

        return "IDLE";
    }

    function postureLine() {
        if (posture === "sit")
            return "Sitting for " + fmtDur(postureSinceSec);

        if (posture === "stand")
            return "Standing for " + fmtDur(postureSinceSec);

        if (posture === "away") {
            var why = locked ? "locked" : (screenOff ? "screen off" : "idle");
            return "Away for " + fmtDur(postureSinceSec) + " (" + why + ")";
        }

        if (connected && (sitCm <= 0 || standCm <= 0))
            return "Set both presets to track posture";

        return "Posture unknown";
    }

    function workWindowLabel() {
        var days = Array.isArray(workDays) ? workDays : [];
        var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        var d = "";
        if (days.length === 0 || days.length === 7)
            d = "every day";
        else if (days.join(",") === "1,2,3,4,5")
            d = "Mon–Fri";
        else
            d = days.map(function(i) {
            return names[i] || "?";
        }).join(" ");
        return workHours + " " + d;
    }

    function send(cmd) {
        if (!bridge.running || !connected) {
            errorMessage = "Desk is offline";
            return false;
        }
        bridge.write(cmd + "\n");
        return true;
    }

    function goTo(cm) {
        var v = Number(cm);
        if (!(v >= 40 && v <= 200)) {
            errorMessage = "Height must be 40–200 cm";
            return;
        }
        notice = "";
        errorMessage = "";
        send("go " + v.toFixed(1));
    }

    function sit() {
        notice = "";
        errorMessage = "";
        send("sit");
    }

    function stand() {
        notice = "";
        errorMessage = "";
        send("stand");
    }

    function stop() {
        send("stop");
    }

    function nudge(dir) {
        if (targeting)
            return;

        notice = "";
        errorMessage = "";
        send(dir + " " + nudgeMs);
        refreshTimer.restart();
    }

    function togglePreset() {
        if (!haveHeight)
            return;

        // Head for whichever preset is farther away.
        if (Math.abs(height_cm - sitCm) < Math.abs(height_cm - standCm))
            stand();
        else
            sit();
    }

    function savePresetHere(key) {
        if (!haveHeight)
            return;

        var v = Number(height_cm).toFixed(1);
        if (send("set " + key + " " + v)) {
            send("save");
            send("status");
            notice = key.charAt(0).toUpperCase() + key.slice(1) + " preset saved at " + v + " cm";
        }
    }

    function parseStatus(line) {
        var re = /(\w+)=([^\s]+)/g;
        var m;
        while ((m = re.exec(line)) !== null) {
            var key = m[1];
            var val = m[2];
            if (key === "height") {
                var h = parseFloat(val);
                if (h >= 0)
                    height_cm = h;

            } else if (key === "target") {
                targeting = val !== "none";
                if (targeting)
                    targetCm = parseFloat(val);

            } else if (key === "sit") {
                sitCm = parseFloat(val);
            } else if (key === "stand") {
                standCm = parseFloat(val);
            }
        }
    }

    function handleLine(raw) {
        var text = String(raw || "").trim();
        if (text === "")
            return;

        var parts = text.split(/\s+/);
        var head = parts[0];
        var rest = text.slice(head.length).trim();
        if (head === "PORT") {
            connected = true;
            portPath = rest;
            errorMessage = "";
            send("status");
            send("h");
        } else if (head === "OFFLINE") {
            connected = false;
            errorMessage = rest;
        } else if (head === "READY") {
            send("status");
        } else if (head === "H") {
            var h = parseFloat(parts[1]);
            if (h >= 0)
                height_cm = h;

        } else if (head === "OK") {
            if (parts[1] === "goto") {
                targeting = true;
                targetCm = parseFloat(parts[2]);
            } else if (parts[1] === "stopped") {
                targeting = false;
            }
        } else if (head === "DONE") {
            targeting = false;
            var d = parseFloat(parts[1]);
            if (d >= 0)
                height_cm = d;

            if (text.indexOf("gave up") >= 0)
                notice = "Stopped at " + fmt(d) + " cm (could not get closer)";

        } else if (head === "STOP") {
            targeting = false;
            errorMessage = "Move stopped: " + rest;
        } else if (head === "ERR") {
            errorMessage = rest;
        } else if (head === "STATUS") {
            parseStatus(rest);
        } else if (head === "CFG") {
            parseStatus(rest);
        }
        updatePosture();
    }

    // ---- posture tracking ----

    function computePosture() {
        if (idleMonitor.isIdle || screenOff || locked)
            return "away";

        if (!haveHeight || sitCm <= 0 || standCm <= 0 || standCm <= sitCm)
            return "unknown";

        var mid = (sitCm + standCm) / 2;
        // 1 cm of hysteresis around the midpoint so sensor noise cannot flip
        // the posture when the desk is parked near the middle.
        if (height_cm >= mid + 1)
            return "stand";

        if (height_cm <= mid - 1)
            return "sit";

        if (posture === "sit" || posture === "stand")
            return posture;

        return height_cm >= mid ? "stand" : "sit";
    }

    function updatePosture() {
        var p = computePosture();
        if (p === posture)
            return;

        posture = p;
        var args = ["record", p];
        if (haveHeight)
            args.push(Number(height_cm).toFixed(1));

        runTracker(args);
    }

    function runTracker(args) {
        var q = trackerQueue;
        q.push(args);
        trackerQueue = q;
        drainTracker();
    }

    function drainTracker() {
        if (tracker.running || trackerQueue.length === 0)
            return;

        var q = trackerQueue;
        var args = q.shift();
        trackerQueue = q;
        tracker.command = [trackerHelper].concat(args);
        tracker.running = true;
    }

    function handlePresenceLine(line) {
        var text = String(line || "").trim();
        if (text === "" || text.charAt(0) !== "{")
            return;

        var data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            return;
        }
        screenOff = data.screen !== "on";
        locked = !!data.locked;
        updatePosture();
    }

    function checkPresence() {
        if (!presence.running)
            presence.running = true;

    }

    function handleTrackerLine(line) {
        var text = String(line || "").trim();
        if (text === "" || text.charAt(0) !== "{")
            return;

        var data;
        try {
            data = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (data.today) {
            standTodaySec = data.today.stand || 0;
            sitTodaySec = data.today.sit || 0;
        }
        if (data.current)
            postureSinceSec = data.current.seconds || 0;

        if (data.days)
            historyDays = data.days;

        checkReminder();
    }

    function inWorkHours() {
        var d = new Date();
        var days = Array.isArray(workDays) ? workDays : [];
        if (days.length > 0 && days.indexOf(d.getDay()) < 0)
            return false;

        var m = String(workHours).match(/^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$/);
        if (!m)
            return true;

        var mins = d.getHours() * 60 + d.getMinutes();
        var start = parseInt(m[1]) * 60 + parseInt(m[2]);
        var end = parseInt(m[3]) * 60 + parseInt(m[4]);
        if (start <= end)
            return mins >= start && mins < end;

        return mins >= start || mins < end;
    }

    function checkReminder() {
        if (!remindersEnabled || posture !== "sit" || !connected || targeting)
            return;

        if (!inWorkHours())
            return;

        if (Date.now() / 1000 < snoozeUntil)
            return;

        if (postureSinceSec < sitReminderMinutes * 60)
            return;

        if (notifier.running)
            return;

        remind();
    }

    function remind() {
        snoozeUntil = Date.now() / 1000 + remindRepeatMinutes * 60;
        var body = "Sitting for " + fmtDur(postureSinceSec) + ". Standing today " + fmtDur(standTodaySec) + " of " + fmtGoal() + ". Click to stand.";
        notifier.command = ["notify-send", "-a", "Standing Desk", "-u", "normal", "-A", "default=Stand up", "Time to stand", body];
        notifier.running = true;
    }

    function snooze(minutes) {
        var m = Number(minutes);
        if (!(m > 0))
            m = 30;

        snoozeUntil = Date.now() / 1000 + m * 60;
        notice = "Reminders snoozed for " + fmtDur(m * 60);
    }

    // Persist one key on this widget's shell.json entry. Applied locally
    // first so the panel reacts on the click; the file write comes back
    // through the bar as the same value.
    function saveSetting(name, value) {
        var entry = {
            "id": root.moduleName
        };
        for (var key in root.settings) {
            if (key !== "id")
                entry[key] = root.settings[key];

        }
        entry[name] = value;
        root.settings = entry;
        if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
            root.bar.shell.updateEntryInline(root.moduleName, entry);

    }

    function setReminders(on) {
        saveSetting("reminders", !!on);
    }

    function todayJson() {
        return JSON.stringify({
            "posture": posture,
            "postureSeconds": postureSinceSec,
            "standToday": standTodaySec,
            "sitToday": sitTodaySec,
            "goalMinutes": goalMinutes,
            "goalMet": goalMet,
            "days": historyDays
        });
    }

    // ---- panel ----

    function open() {
        opened = true;
        if (!goTouched && haveHeight)
            goValue = Math.round(height_cm);

        send("status");
        send("h");
        runTracker(["summary"]);
    }

    function close() {
        opened = false;
    }

    function toggle() {
        opened ? close() : open();
    }

    function closeForPopoutSwitch() {
        popoutSwitchClosing = true;
        close();
        Qt.callLater(function() {
            popoutSwitchClosing = false;
        });
    }

    function switchPanel(direction) {
        if (bar && typeof bar.switchPanelFrom === "function")
            return bar.switchPanelFrom(root, direction);

        return false;
    }

    moduleName: "nerdyworm.desk"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    onConnectedChanged: updatePosture()
    Component.onCompleted: {
        bridge.running = true;
        checkPresence();
        runTracker(["summary"]);
    }

    IpcHandler {
        function status() : string {
            return JSON.stringify({
                "connected": root.connected,
                "port": root.portPath,
                "height": root.height_cm,
                "moving": root.targeting,
                "target": root.targetCm,
                "sit": root.sitCm,
                "stand": root.standCm,
                "state": root.stateLabel(),
                "posture": root.posture,
                "screenOff": root.screenOff,
                "locked": root.locked,
                "standToday": root.standTodaySec,
                "goalMinutes": root.goalMinutes
            });
        }

        function today() : string {
            return root.todayJson();
        }

        function sit() : string {
            root.sit();
            return "queued";
        }

        function stand() : string {
            root.stand();
            return "queued";
        }

        function togglePreset() : string {
            root.togglePreset();
            return "queued";
        }

        function go(cm: string) : string {
            root.goTo(parseFloat(cm));
            return root.errorMessage !== "" ? root.errorMessage : "queued";
        }

        function stop() : string {
            root.stop();
            return "queued";
        }

        function up() : string {
            root.nudge("up");
            return "queued";
        }

        function down() : string {
            root.nudge("down");
            return "queued";
        }

        function snooze(minutes: string) : string {
            root.snooze(parseFloat(minutes));
            return root.notice;
        }

        function remind() : string {
            root.remind();
            return "sent";
        }

        function toggle() : string {
            root.toggle();
            return root.opened ? "open" : "closed";
        }

        function showTab(name: string) : string {
            root.tab = name === "settings" ? "settings" : "desk";
            return root.tab;
        }

        target: "nerdyworm.desk"
    }

    Process {
        id: bridge

        command: [root.bridgeHelper]
        stdinEnabled: true
        onExited: function(exitCode) {
            root.connected = false;
            root.targeting = false;
            if (root.errorMessage === "")
                root.errorMessage = "Desk bridge exited (code " + exitCode + ")";

            reconnectTimer.restart();
        }

        stdout: SplitParser {
            onRead: function(line) {
                root.handleLine(line);
            }
        }

        stderr: SplitParser {
            onRead: function(line) {
                var t = String(line || "").trim();
                if (t !== "")
                    root.errorMessage = t;

            }
        }

    }

    // Posture log. One call at a time; runTracker() queues the rest.
    Process {
        id: tracker

        onExited: root.drainTracker()

        stdout: SplitParser {
            onRead: function(line) {
                root.handleTrackerLine(line);
            }
        }

        stderr: SplitParser {
            onRead: function(line) {
                var t = String(line || "").trim();
                if (t !== "")
                    console.warn("desk-track: " + t);

            }
        }

    }

    // Screen and lock state, polled once a minute.
    Process {
        id: presence

        command: [root.presenceHelper]

        stdout: SplitParser {
            onRead: function(line) {
                root.handlePresenceLine(line);
            }
        }

    }

    // notify-send blocks until the toast is closed; "default" on stdout means
    // the user clicked it.
    Process {
        id: notifier

        stdout: SplitParser {
            onRead: function(line) {
                if (String(line || "").trim() === "default")
                    root.stand();

            }
        }

    }

    IdleMonitor {
        id: idleMonitor

        enabled: true
        timeout: Math.max(60, root.awayAfterMinutes * 60)
        respectInhibitors: false
        onIsIdleChanged: root.updatePosture()
    }

    Timer {
        id: reconnectTimer

        interval: 5000
        onTriggered: {
            if (!bridge.running)
                bridge.running = true;

        }
    }

    // Height poll: quick while the panel is open or the desk is moving, slow otherwise.
    Timer {
        id: pollTimer

        interval: root.opened || root.targeting ? 2000 : 15000
        running: root.connected
        repeat: true
        onTriggered: root.send("h")
    }

    // One-shot read shortly after a nudge pulse finishes.
    Timer {
        id: refreshTimer

        interval: root.nudgeMs + 700
        onTriggered: root.send("h")
    }

    // Totals refresh and reminder check. Also the heartbeat for desk-track.
    Timer {
        id: trackTimer

        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            root.checkPresence();
            root.runTracker(["summary"]);
        }
    }

    WidgetButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        text: root.barLabel()
        tooltipText: root.connected ? "Desk " + root.fmt(root.height_cm) + " cm · " + root.stateLabel() + "\nStanding today " + root.fmtDur(root.standTodaySec) + " of " + root.fmtGoal() + "\nLeft: panel · Right: sit/stand · Middle: stop" : "Desk offline — " + (root.errorMessage || "no controller found")
        active: root.targeting
        dimmed: !root.connected
        onPressed: function(mouseButton) {
            if (mouseButton === Qt.RightButton)
                root.togglePreset();
            else if (mouseButton === Qt.MiddleButton)
                root.stop();
            else
                root.toggle();
        }
    }

    KeyboardPanel {
        id: panel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(300))
        contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent
            onMoveRequested: function(dx, dy) {
                if (dy !== 0) {
                    root.goTouched = true;
                    root.goValue = Math.max(40, Math.min(200, root.goValue - dy));
                }
            }
            onActivateRequested: root.goTo(root.goValue)
            onCloseRequested: root.close()
            onTabRequested: function(direction) {
                root.switchPanel(direction);
            }
            onTextKey: function(value) {
                var k = String(value).toLowerCase();
                if (k === "s")
                    root.sit();
                else if (k === "t")
                    root.stand();
                else if (k === "x" || k === " ")
                    root.stop();
                else if (k === "u")
                    root.nudge("up");
                else if (k === "d")
                    root.nudge("down");
                else if (k === "r")
                    root.send("h");
                else if (k === "z")
                    root.snooze(30);
            }

            ScrollView {
                id: scrollArea

                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                Column {
                    id: panelColumn

                    width: scrollArea.availableWidth
                    spacing: Style.space(10)

                    PanelHero {
                        title: "Desk"
                        meta: {
                            if (!root.connected)
                                return "Controller not connected";

                            if (root.targeting)
                                return root.fmt(root.height_cm) + " cm → " + root.fmt(root.targetCm) + " cm";

                            return root.fmt(root.height_cm) + " cm";
                        }
                        detail: root.stateLabel()
                        foreground: root.foreground
                        fontFamily: root.fontFamily

                        iconComponent: Component {
                            Text {
                                text: "⇅"
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.display
                                font.bold: true
                            }

                        }

                    }

                    ButtonGroup {
                        options: [{
                            "value": "desk",
                            "label": "Desk"
                        }, {
                            "value": "settings",
                            "label": "Settings"
                        }]
                        value: root.tab
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onChanged: function(v) {
                            root.tab = v;
                        }
                    }

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    // ---------------- Desk tab ----------------

                    Row {
                        visible: root.tab === "desk"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Sit · " + root.fmt(root.sitCm)
                            iconText: root.atSit ? "✓" : ""
                            selected: root.atSit
                            enabled: root.connected
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Go to sitting height (S)"
                            onClicked: root.sit()
                        }

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Stand · " + root.fmt(root.standCm)
                            iconText: root.atStand ? "✓" : ""
                            selected: root.atStand
                            enabled: root.connected
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Go to standing height (T)"
                            onClicked: root.stand()
                        }

                    }

                    Button {
                        visible: root.tab === "desk" && root.targeting
                        width: panelColumn.width
                        text: "■ Stop"
                        active: true
                        bordered: true
                        foreground: root.urgent
                        fontFamily: root.fontFamily
                        tooltipText: "Stop and cancel target (X)"
                        onClicked: root.stop()
                    }

                    PanelSectionHeader {
                        visible: root.tab === "desk"
                        text: "STANDING TODAY"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
                        visible: root.tab === "desk"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        Text {
                            text: root.fmtDur(root.standTodaySec)
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: root.goalMet ? "goal met ✓" : "of " + root.fmtGoal() + " goal"
                            color: Qt.darker(root.foreground, 1.3)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            anchors.verticalCenter: parent.verticalCenter
                        }

                    }

                    // Goal progress bar
                    Item {
                        visible: root.tab === "desk"
                        width: panelColumn.width
                        height: Style.space(8)

                        Rectangle {
                            anchors.fill: parent
                            radius: height / 2
                            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
                        }

                        Rectangle {
                            width: Math.max(parent.height, parent.width * root.goalFraction)
                            height: parent.height
                            radius: height / 2
                            color: root.foreground
                            visible: root.standTodaySec > 0

                            Behavior on width {
                                NumberAnimation {
                                    duration: 300
                                }

                            }

                        }

                    }

                    Text {
                        visible: root.tab === "desk"
                        width: parent.width
                        text: root.postureLine() + " · sat " + root.fmtDur(root.sitTodaySec) + " today"
                        color: Qt.darker(root.foreground, 1.3)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.tab === "desk" && root.remindersEnabled && root.snoozeUntil > Date.now() / 1000
                        width: parent.width
                        text: "Reminders snoozed"
                        color: Qt.darker(root.foreground, 1.3)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                    }

                    // ---------------- Settings tab ----------------

                    PanelSectionHeader {
                        visible: root.tab === "settings"
                        text: "MOVE"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        Button {
                            width: (parent.width - parent.spacing * 2) / 3
                            text: "▲ Up"
                            enabled: root.connected && !root.targeting
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Nudge up (U)"
                            onClicked: root.nudge("up")
                        }

                        Button {
                            width: (parent.width - parent.spacing * 2) / 3
                            text: "▼ Down"
                            enabled: root.connected && !root.targeting
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Nudge down (D)"
                            onClicked: root.nudge("down")
                        }

                        Button {
                            width: (parent.width - parent.spacing * 2) / 3
                            text: "■ Stop"
                            active: root.targeting
                            enabled: root.connected
                            bordered: true
                            foreground: root.targeting ? root.urgent : root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Stop and cancel target (X)"
                            onClicked: root.stop()
                        }

                    }

                    PanelSectionHeader {
                        visible: root.tab === "settings"
                        text: "GO TO HEIGHT (CM)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        NumberField {
                            id: goField

                            width: parent.width - goButton.width - parent.spacing
                            from: 40
                            to: 200
                            value: root.goValue
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onModified: function(v) {
                                root.goTouched = true;
                                root.goValue = v;
                            }
                        }

                        Button {
                            id: goButton

                            text: "Go"
                            enabled: root.connected
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Move to this height (Enter)"
                            onClicked: root.goTo(root.goValue)
                        }

                    }

                    PanelSectionHeader {
                        visible: root.tab === "settings"
                        text: "SAVE CURRENT HEIGHT AS"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Sit preset"
                            enabled: root.haveHeight && !root.targeting
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.savePresetHere("sit")
                        }

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Stand preset"
                            enabled: root.haveHeight && !root.targeting
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.savePresetHere("stand")
                        }

                    }

                    PanelSectionHeader {
                        visible: root.tab === "settings"
                        text: "TRACKING"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        NumberField {
                            width: (parent.width - parent.spacing) / 2
                            fieldWidth: width
                            label: "Daily goal (min)"
                            from: 0
                            to: 720
                            stepSize: 15
                            value: root.goalMinutes
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onModified: function(v) {
                                root.saveSetting("goalMinutes", v);
                            }
                        }

                        NumberField {
                            width: (parent.width - parent.spacing) / 2
                            fieldWidth: width
                            label: "Away after (min)"
                            from: 1
                            to: 60
                            value: root.awayAfterMinutes
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onModified: function(v) {
                                root.saveSetting("awayAfterMinutes", v);
                            }
                        }

                    }

                    PanelSectionHeader {
                        visible: root.tab === "settings"
                        text: "REMINDERS"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Toggle {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        label: "Remind me to stand"
                        description: "Desktop notification while sitting. Click it to stand."
                        checked: root.remindersEnabled
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        onClicked: root.setReminders(!root.remindersEnabled)
                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        NumberField {
                            width: (parent.width - parent.spacing) / 2
                            fieldWidth: width
                            label: "After sitting (min)"
                            from: 5
                            to: 240
                            stepSize: 5
                            value: root.sitReminderMinutes
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onModified: function(v) {
                                root.saveSetting("sitReminderMinutes", v);
                            }
                        }

                        NumberField {
                            width: (parent.width - parent.spacing) / 2
                            fieldWidth: width
                            label: "Repeat every (min)"
                            from: 5
                            to: 120
                            stepSize: 5
                            value: root.remindRepeatMinutes
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onModified: function(v) {
                                root.saveSetting("remindRepeatMinutes", v);
                            }
                        }

                    }

                    Column {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(4)

                        Text {
                            text: "Hours"
                            color: Qt.darker(root.foreground, 1.4)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                        }

                        TextField {
                            id: hoursField

                            width: parent.width
                            text: root.workHours
                            placeholderText: "08:00-18:00"
                            foreground: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            onEditingFinished: {
                                var t = text.trim();
                                if (t === "" || /^\d{1,2}:\d{2}-\d{1,2}:\d{2}$/.test(t)) {
                                    if (t !== root.workHours)
                                        root.saveSetting("workHours", t);

                                } else {
                                    root.errorMessage = "Hours must look like 08:00-18:00";
                                    text = root.workHours;
                                }
                            }
                        }

                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(4)

                        Repeater {
                            model: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

                            Button {
                                required property string modelData
                                required property int index

                                width: (parent.width - parent.spacing * 6) / 7
                                text: modelData
                                selected: Array.isArray(root.workDays) && root.workDays.indexOf(index) >= 0
                                bordered: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                onClicked: {
                                    var days = Array.isArray(root.workDays) ? root.workDays.slice() : [];
                                    var at = days.indexOf(index);
                                    if (at >= 0)
                                        days.splice(at, 1);
                                    else
                                        days.push(index);
                                    days.sort();
                                    root.saveSetting("workDays", days);
                                }
                            }

                        }

                    }

                    Row {
                        visible: root.tab === "settings"
                        width: panelColumn.width
                        spacing: Style.space(8)

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Snooze 30 min"
                            enabled: root.remindersEnabled
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "No reminders for 30 minutes (Z)"
                            onClicked: root.snooze(30)
                        }

                        Button {
                            width: (parent.width - parent.spacing) / 2
                            text: "Snooze 2 h"
                            enabled: root.remindersEnabled
                            bordered: true
                            foreground: root.foreground
                            fontFamily: root.fontFamily
                            onClicked: root.snooze(120)
                        }

                    }

                    Text {
                        visible: root.notice !== ""
                        width: parent.width
                        text: root.notice
                        color: Qt.darker(root.foreground, 1.3)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        visible: root.errorMessage !== ""
                        width: parent.width
                        text: root.errorMessage
                        color: root.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        width: parent.width
                        text: (root.connected ? root.portPath + " · " : "") + "S sit · T stand · X stop · Z snooze"
                        color: Qt.darker(root.foreground, 1.5)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                }

            }

        }

    }

}
