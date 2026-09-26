// ~/.config/quickshell/powermenu/shell.qml
// Quickshell Power Menu für i3 (X11) mit pywal16-Farben
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
    id: root

    // ---- Einstellungen ----
    property string fontFamily: "JetBrainsMono Nerd Font"
    property real   bgOpacity:  0.85   // braucht picom für echte Transparenz

    // ---- pywal16 ----
    property var wal: ({})
    property string walBg: wal.special?.background ?? "#1e1e2e"
    property color bg:     walBg
    property color fg:     wal.special?.foreground ?? "#cdd6f4"
    property color accent: wal.colors?.color4 ?? "#89b4fa"
    property color danger: wal.colors?.color1 ?? "#f38ba8"
    property color muted:  wal.colors?.color8 ?? "#585b70"

    FileView {
        path: Quickshell.env("HOME") + "/.cache/wal/colors.json"
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.wal = JSON.parse(text()) } catch (e) { console.warn("wal:", e) }
        }
    }

    // ---- Aktionen ----
    property int selected: 0
    property int pending: -1   // Index, der auf Bestätigung wartet

    property var actions: [
        // Font-Awesome-Range der Nerd Fonts, als Escapes (kopiersicher)
        { icon: "\uf023", label: "Lock",     confirm: false,
          // kurze Pause, damit --blur nicht das Menü mit abfotografiert
          cmd: () => ["sh", "-c", "sleep 0.3; exec \"$HOME/.local/bin/lock\""] },
        { icon: "\uf08b", label: "Logout",   confirm: true,
          cmd: () => ["i3-msg", "exit"] },
        { icon: "\uf186", label: "Suspend",  confirm: false,
          cmd: () => ["systemctl", "suspend"] },
        { icon: "\uf021", label: "Reboot",   confirm: true,
          cmd: () => ["systemctl", "reboot"] },
        { icon: "\uf011", label: "Shutdown", confirm: true,
          cmd: () => ["systemctl", "poweroff"] }
    ]

    function activate(i) {
        const a = actions[i]
        if (a.confirm && pending !== i) { pending = i; selected = i; return }
        Quickshell.execDetached(a.cmd())
        Qt.quit()
    }

    function move(d) {
        selected = (selected + d + actions.length) % actions.length
        pending = -1
    }

    // ---- Fenster ----
    FloatingWindow {
        title: "qs-powermenu"          // i3 matcht darauf
        visible: true
        color: "transparent"
        implicitWidth: 900
        implicitHeight: 300

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, root.bgOpacity)

            // Klick ins Leere schließt
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }

            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: (e) => {
                    switch (e.key) {
                    case Qt.Key_Escape: case Qt.Key_Q:  Qt.quit(); break
                    case Qt.Key_Left:   case Qt.Key_H:  root.move(-1); break
                    case Qt.Key_Right:  case Qt.Key_L:  root.move(1); break
                    case Qt.Key_Return: case Qt.Key_Enter:
                    case Qt.Key_Space:  root.activate(root.selected); break
                    default:
                        const n = e.key - Qt.Key_1   // 1..5 als Direktwahl
                        if (n >= 0 && n < root.actions.length) root.activate(n)
                    }
                    e.accepted = true
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 28

                RowLayout {
                    spacing: 24
                    Layout.alignment: Qt.AlignHCenter

                    Repeater {
                        model: root.actions.length
                        delegate: Rectangle {
                            required property int index
                            readonly property var act: root.actions[index]
                            readonly property bool sel: root.selected === index
                            readonly property bool pend: root.pending === index
                            readonly property color hl: pend ? root.danger : root.accent

                            width: 140; height: 140; radius: 18
                            color: sel ? Qt.rgba(hl.r, hl.g, hl.b, 0.22)
                                       : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
                            border.width: 2
                            border.color: sel ? hl : Qt.rgba(root.muted.r, root.muted.g, root.muted.b, 0.5)
                            scale: sel ? 1.06 : 1.0
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Column {
                                anchors.centerIn: parent
                                spacing: 10
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: act.icon
                                    font.family: root.fontFamily
                                    font.pixelSize: 44
                                    color: sel ? hl : root.fg
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: act.label
                                    font.family: root.fontFamily
                                    font.pixelSize: 15
                                    color: root.fg
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: { if (root.selected !== index) { root.selected = index; root.pending = -1 } }
                                onClicked: root.activate(index)
                            }
                        }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.pending >= 0
                          ? root.actions[root.pending].label + "? Nochmal Enter/Klick zum Bestätigen"
                          : "←/→ · h/l · 1–5 · Enter · Esc"
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    color: root.pending >= 0 ? root.danger : root.muted
                }
            }
        }
    }
}
