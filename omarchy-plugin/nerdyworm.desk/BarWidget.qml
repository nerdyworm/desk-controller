import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standing desk control. Talks to the Arduino desk controller through
// scripts/desk-bridge (desk.py pipe), which keeps the serial port open so
// every command is instant and the height can be polled cheaply.
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
    readonly property int nudgeMs: 400
    readonly property real presetMatchCm: 1.5
    readonly property string bridgeHelper: Quickshell.env("HOME") + "/.config/omarchy/plugins/nerdyworm.desk/scripts/desk-bridge"
    readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
    readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    readonly property bool haveHeight: connected && height_cm >= 0
    readonly property bool atSit: haveHeight && sitCm > 0 && Math.abs(height_cm - sitCm) <= presetMatchCm
    readonly property bool atStand: haveHeight && standCm > 0 && Math.abs(height_cm - standCm) <= presetMatchCm

    function fmt(v) {
        return v >= 0 ? Number(v).toFixed(1) : "--";
    }

    function barLabel() {
        if (!connected)
            return "⇅ ✕";

        if (!haveHeight)
            return "⇅ --";

        return "⇅ " + Number(height_cm).toFixed(0);
    }

    function stateLabel() {
        if (!connected)
            return "OFFLINE";

        if (targeting)
            return "MOVING";

        if (atSit)
            return "SIT";

        if (atStand)
            return "STAND";

        return "IDLE";
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
    }

    function open() {
        opened = true;
        if (!goTouched && haveHeight)
            goValue = Math.round(height_cm);

        send("status");
        send("h");
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
    Component.onCompleted: bridge.running = true

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
                "state": root.stateLabel()
            });
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

        function toggle() : string {
            root.toggle();
            return root.opened ? "open" : "closed";
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

    WidgetButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        text: root.barLabel()
        tooltipText: root.connected ? "Desk " + root.fmt(root.height_cm) + " cm · " + root.stateLabel() + "\nLeft: panel · Right: sit/stand · Middle: stop" : "Desk offline — " + (root.errorMessage || "no controller found")
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
        contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(520))

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

                    PanelSeparator {
                        foreground: root.foreground
                    }

                    PanelSectionHeader {
                        text: "PRESETS"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
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

                    PanelSectionHeader {
                        text: "MOVE"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
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
                            foreground: root.targeting ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground
                            fontFamily: root.fontFamily
                            tooltipText: "Stop and cancel target (X)"
                            onClicked: root.stop()
                        }

                    }

                    PanelSectionHeader {
                        text: "GO TO HEIGHT (CM)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
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
                        text: "SAVE CURRENT HEIGHT AS"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                    }

                    Row {
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
                        color: root.bar ? root.bar.urgent : Color.urgent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        width: parent.width
                        text: (root.connected ? root.portPath + " · " : "") + "S sit · T stand · U/D nudge · X stop · ↑↓ Enter go"
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
