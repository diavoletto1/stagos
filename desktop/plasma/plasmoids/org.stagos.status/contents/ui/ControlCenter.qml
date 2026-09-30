import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import "palette.js" as Pal

// The Control Center popup (Mac proportions, ~360 px wide): toggles, sliders, now playing, recon, Stagbot.
// State comes from plasmoidRoot.cc (`stag-ctl control`) and plasmoidRoot.bot (`stag-ctl stagbot status`).
Item {
    id: cc

    required property var plasmoidRoot
    readonly property var s: plasmoidRoot.cc || ({})
    readonly property var b: plasmoidRoot.bot || ({})
    property string askHint: ""
    readonly property var r: s.recon || ({})
    readonly property bool tsUp: !!(r.ts && r.ts.up)
    readonly property bool gpsFix: !!(r.gps && r.gps.mode >= 2)
    readonly property bool monOn: !!(r.capture && r.capture.mode === "monitor")
    readonly property bool cardPresent: !!(r.capture && (r.capture.mode === "monitor" || r.capture.mode === "managed"))
    readonly property bool kismetOn: !!(r.kismet && r.kismet.running)

    Layout.preferredWidth: 360
    Layout.minimumWidth: 360
    Layout.maximumWidth: 360
    Layout.preferredHeight: main.implicitHeight + 24
    Layout.minimumHeight: Layout.preferredHeight
    Layout.maximumHeight: Layout.preferredHeight

    function isOn(part) {
        return !!(s[part] && s[part].on);
    }
    // a part that failed (tool missing, no hardware) comes back as null or {"error": ...}
    function works(part) {
        return !!(s[part] && s[part].error === undefined);
    }

    ColumnLayout {
        id: main
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        // ---- toggles ----
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: 8
            rowSpacing: 8

            Tile {
                Layout.fillWidth: true
                title: "Wi-Fi"
                iconName: "network-wireless"
                checked: cc.isOn("wifi")
                available: cc.works("wifi")
                subtitle: !cc.works("wifi") ? "Unavailable" : !cc.isOn("wifi") ? "Off" : (cc.s.wifi.ssid || "Not connected")
                onToggled: cc.plasmoidRoot.act("wifi toggle", "wifi")
            }
            Tile {
                Layout.fillWidth: true
                title: "Bluetooth"
                iconName: "network-bluetooth"
                checked: cc.isOn("bt")
                available: cc.works("bt") && !!cc.s.bt.available
                subtitle: !cc.works("bt") || !cc.s.bt.available ? "Unavailable" : !cc.isOn("bt") ? "Off" : (cc.s.bt.connected > 0 ? cc.s.bt.connected + " connected" : "On")
                onToggled: cc.plasmoidRoot.act("bt toggle", "bt")
            }
            Tile {
                Layout.fillWidth: true
                title: "Do Not Disturb"
                iconName: "notifications-disabled"
                checked: cc.isOn("dnd")
                available: cc.works("dnd")
                subtitle: !cc.works("dnd") ? "Unavailable" : cc.isOn("dnd") ? "On" : "Off"
                onToggled: cc.plasmoidRoot.act("dnd toggle", "dnd")
            }
            Tile {
                Layout.fillWidth: true
                title: "Night Light"
                iconName: "redshift-status-on"
                checked: cc.isOn("night")
                available: cc.works("night")
                subtitle: !cc.works("night") ? "Unavailable" : !cc.isOn("night") ? "Off" : (cc.s.night.running && cc.s.night.temp > 0 ? "On  " + cc.s.night.temp + "K" : "On")
                onToggled: cc.plasmoidRoot.act("night toggle", "night")
            }
        }

        // ---- sliders ----
        Card {
            Layout.fillWidth: true
            heading: "Display and sound"

            RowLayout {
                Layout.fillWidth: true
                visible: !!(cc.s.bright && cc.s.bright.available)
                spacing: 8
                Kirigami.Icon {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    source: "brightness-high"
                    color: Pal.text
                    isMask: true
                }
                PC3.Slider {
                    id: bright
                    Layout.fillWidth: true
                    from: 1
                    to: 100
                    stepSize: 1
                    onMoved: brightTimer.restart()
                }
                PC3.Label {
                    Layout.preferredWidth: 30
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(bright.value)
                    font.family: Pal.mono
                    font.pixelSize: 11
                    color: Pal.dim
                }
            }
            RowLayout {
                Layout.fillWidth: true
                visible: !!(cc.s.vol && typeof cc.s.vol.volume === "number")
                spacing: 8
                Kirigami.Icon {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    source: cc.s.vol && cc.s.vol.muted ? "audio-volume-muted" : "audio-volume-high"
                    color: cc.s.vol && cc.s.vol.muted ? Pal.accent : Pal.text
                    isMask: true
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: cc.plasmoidRoot.act("vol mute toggle", "vol")
                    }
                }
                PC3.Slider {
                    id: vol
                    Layout.fillWidth: true
                    from: 0
                    to: 100
                    stepSize: 1
                    onMoved: volTimer.restart()
                }
                PC3.Label {
                    Layout.preferredWidth: 30
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(vol.value)
                    font.family: Pal.mono
                    font.pixelSize: 11
                    color: Pal.dim
                }
            }
        }

        // ---- now playing ----
        Card {
            Layout.fillWidth: true
            heading: "Now playing"

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    PC3.Label {
                        Layout.fillWidth: true
                        text: cc.s.media && cc.s.media.available ? (cc.s.media.title || "Unknown title") : "Nothing playing"
                        font.family: Pal.ui
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: Pal.text
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    PC3.Label {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: cc.s.media && cc.s.media.available ? (cc.s.media.artist || cc.s.media.player || "") : ""
                        font.family: Pal.ui
                        font.pixelSize: 11
                        color: Pal.dim
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                }
                HudButton {
                    iconName: "media-skip-backward"
                    enabled: !!(cc.s.media && cc.s.media.available)
                    onClicked: cc.plasmoidRoot.act("media prev", "media")
                }
                HudButton {
                    iconName: cc.s.media && cc.s.media.status === "Playing" ? "media-playback-pause" : "media-playback-start"
                    enabled: !!(cc.s.media && cc.s.media.available)
                    onClicked: cc.plasmoidRoot.act("media play-pause", "media")
                }
                HudButton {
                    iconName: "media-skip-forward"
                    enabled: !!(cc.s.media && cc.s.media.available)
                    onClicked: cc.plasmoidRoot.act("media next", "media")
                }
            }
        }

        // ---- recon ----
        Card {
            Layout.fillWidth: true
            heading: "Recon"

            RowLayout {
                Layout.fillWidth: true
                spacing: 12
                StatusText {
                    label: "TS"
                    value: cc.tsUp ? (cc.r.ts.ip || "up") : (cc.r.ts && cc.r.ts.installed === false ? "n/a" : "down")
                    good: cc.tsUp
                }
                StatusText {
                    label: "GPS"
                    value: cc.r.gps && cc.r.gps.installed === false ? "n/a" : (cc.gpsFix ? cc.r.gps.mode + "D" : "--")
                    good: cc.gpsFix
                }
                StatusText {
                    Layout.fillWidth: true
                    label: "CAP"
                    value: cc.r.capture && cc.r.capture.iface ? cc.r.capture.iface + " " + cc.r.capture.mode : "not set"
                    hot: cc.monOn
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                HudButton {
                    text: cc.kismetOn ? "Kismet: stop" : "Kismet: start"
                    hot: cc.kismetOn
                    onClicked: cc.plasmoidRoot.act(cc.kismetOn ? "recon kismet stop" : "recon kismet start", "recon")
                }
                HudButton {
                    visible: cc.kismetOn
                    iconName: "internet-web-browser"
                    onClicked: cc.plasmoidRoot.act("recon kismet open", "recon")
                }
                Item {
                    Layout.fillWidth: true
                }
                HudButton {
                    text: cc.monOn ? "Monitor: off" : "Monitor: on"
                    hot: cc.monOn
                    enabled: cc.cardPresent
                    onClicked: cc.plasmoidRoot.act(cc.monOn ? "recon mon off" : "recon mon on", "recon")
                }
            }
        }

        // ---- stagbot ----
        Card {
            Layout.fillWidth: true
            heading: "Stagbot"

            Flow {
                Layout.fillWidth: true
                spacing: 10
                visible: !!(cc.b.services && cc.b.services.length)
                Repeater {
                    model: cc.b.services || []
                    delegate: RowLayout {
                        id: svc
                        required property var modelData
                        spacing: 4
                        Rectangle {
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            radius: 3
                            color: svc.modelData.up ? Pal.text : Pal.accent
                        }
                        PC3.Label {
                            text: svc.modelData.name
                            font.family: Pal.mono
                            font.pixelSize: 11
                            color: svc.modelData.up ? Pal.text : Pal.accent
                            textFormat: Text.PlainText
                        }
                    }
                }
            }
            PC3.Label {
                visible: !(cc.b.services && cc.b.services.length)
                text: "No stag services configured"
                font.family: Pal.ui
                font.pixelSize: 11
                color: Pal.dim
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                PC3.TextField {
                    id: ask
                    Layout.fillWidth: true
                    placeholderText: "Ask Stagbot"
                    font.family: Pal.ui
                    onAccepted: askButton.clicked()
                }
                HudButton {
                    id: askButton
                    text: "Open"
                    onClicked: {
                        const t = ask.text.trim();
                        cc.plasmoidRoot.run("stag-ctl stagbot open" + (t !== "" ? " " + cc.plasmoidRoot.quote(t) : ""), (code, out) => {
                            const j = cc.plasmoidRoot.parse(out);
                            if (j && j.copied)
                                cc.askHint = "Question copied: paste it into the chat (Ctrl+V)";
                            else if (j && j.opened)
                                cc.askHint = "";
                            else
                                cc.askHint = j && j.error ? j.error : "Could not open the Stagbot chat";
                        });
                        ask.text = "";
                    }
                }
            }
            PC3.Label {
                Layout.fillWidth: true
                visible: cc.askHint !== ""
                text: cc.askHint
                wrapMode: Text.WordWrap
                font.family: Pal.ui
                font.pixelSize: 11
                color: Pal.dim
                textFormat: Text.PlainText
            }
        }
    }

    // sliders: follow the polled state unless the user is dragging; send changes after a short pause
    Connections {
        target: cc.plasmoidRoot
        function onCcChanged() {
            // parts that failed come back as {"error": ...}: only numbers move the sliders
            if (cc.s.vol && typeof cc.s.vol.volume === "number" && !vol.pressed && !volTimer.running)
                vol.value = cc.s.vol.volume;
            if (cc.s.bright && typeof cc.s.bright.percent === "number" && !bright.pressed && !brightTimer.running)
                bright.value = cc.s.bright.percent;
        }
    }
    Timer {
        id: volTimer
        interval: 120
        onTriggered: cc.plasmoidRoot.act("vol set " + Math.round(vol.value), "vol")
    }
    Timer {
        id: brightTimer
        interval: 120
        onTriggered: cc.plasmoidRoot.act("bright set " + Math.round(bright.value), "bright")
    }
}
