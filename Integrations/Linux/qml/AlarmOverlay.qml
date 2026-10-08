import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    visible: desktop && desktop.isAlarmRinging
    z: 9999

    property bool compact: false
    height: compact ? 54 : (parent ? parent.height : 300)
    readonly property var alarm: (desktop && desktop.ringingAlarm) ? desktop.ringingAlarm : ({})
    readonly property string providerName: (alarm && alarm.provider) ? alarm.provider.toUpperCase() : "CODEX"
    readonly property string accountName: (alarm && alarm.accountLabel) ? alarm.accountLabel : "Primary Account"
    readonly property string windowTitle: (alarm && alarm.windowLabel) ? alarm.windowLabel : "Session quota"
    readonly property int restoredQuota: (alarm && alarm.restoredRemaining !== undefined) ? alarm.restoredRemaining : 100

    color: compact ? Qt.rgba(0.04, 0.06, 0.10, 0.95) : Qt.rgba(0.04, 0.06, 0.10, 0.88)

    // Intercept clicks on background in full mode
    MouseArea {
        anchors.fill: parent
        enabled: !root.compact
        onClicked: {} // prevent click-through
    }

    // ==========================================
    // COMPACT MODE (for MiniWindow and SideDock)
    // ==========================================
    Rectangle {
        visible: root.compact
        anchors.fill: parent
        anchors.margins: 6
        radius: 8
        color: Qt.rgba(0.06, 0.72, 0.51, 0.15)
        border.color: "#10b981"
        border.width: 1.5

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 8

            // Ringing Bell Icon
            Label {
                text: "🔔"
                font.pixelSize: 16
                transformOrigin: Item.Center

                SequentialAnimation on rotation {
                    running: root.visible
                    loops: Animation.Infinite
                    PropertyAnimation { to: 14; duration: 90; easing.type: Easing.InOutQuad }
                    PropertyAnimation { to: -14; duration: 90; easing.type: Easing.InOutQuad }
                    PropertyAnimation { to: 10; duration: 80; easing.type: Easing.InOutQuad }
                    PropertyAnimation { to: -10; duration: 80; easing.type: Easing.InOutQuad }
                    PropertyAnimation { to: 0; duration: 80; easing.type: Easing.InOutQuad }
                    PauseAnimation { duration: 600 }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    spacing: 6
                    Label {
                        text: "QUOTA RESTORED"
                        font.bold: true
                        font.pixelSize: 11
                        color: "#10b981"
                    }
                    Label {
                        text: "• " + root.providerName
                        font.bold: true
                        font.pixelSize: 10
                        color: palette.text
                        opacity: 0.8
                    }
                }

                Label {
                    text: root.accountName + " (" + root.windowTitle + ": " + root.restoredQuota + "% available)"
                    font.pixelSize: 10
                    color: palette.text
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            Button {
                text: "Dismiss"
                font.bold: true
                font.pixelSize: 11
                Layout.preferredHeight: 26
                onClicked: desktop.dismissAlarm()

                background: Rectangle {
                    radius: 5
                    color: parent.down ? "#059669" : parent.hovered ? "#10b981" : "#059669"
                }
                contentItem: Text {
                    text: parent.text
                    font: parent.font
                    color: "white"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // ==========================================
    // FULL MODAL MODE (for Dashboard and Main)
    // ==========================================
    Rectangle {
        id: modalCard
        visible: !root.compact
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 520)
        implicitHeight: cardContent.implicitHeight + 48
        radius: 16
        color: "#0f172a"
        border.color: "#10b981"
        border.width: 2

        // Pulsing border glow
        Rectangle {
            anchors.fill: parent
            anchors.margins: -4
            radius: 20
            color: "transparent"
            border.color: "#10b981"
            border.width: 2
            opacity: 0.5
            z: -1

            SequentialAnimation on opacity {
                running: root.visible
                loops: Animation.Infinite
                PropertyAnimation { to: 0.85; duration: 800; easing.type: Easing.InOutSine }
                PropertyAnimation { to: 0.35; duration: 800; easing.type: Easing.InOutSine }
            }
        }

        ColumnLayout {
            id: cardContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            spacing: 16

            // Header Row: Bell + Title + Sound Equalizer
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // Animated Ringing Bell
                Rectangle {
                    width: 44; height: 44
                    radius: 22
                    color: Qt.rgba(0.06, 0.72, 0.51, 0.18)
                    border.color: "#10b981"
                    border.width: 1.5

                    Label {
                        anchors.centerIn: parent
                        text: "🔔"
                        font.pixelSize: 22
                        transformOrigin: Item.Center

                        SequentialAnimation on rotation {
                            running: root.visible
                            loops: Animation.Infinite
                            PropertyAnimation { to: 16; duration: 90; easing.type: Easing.InOutQuad }
                            PropertyAnimation { to: -16; duration: 90; easing.type: Easing.InOutQuad }
                            PropertyAnimation { to: 12; duration: 80; easing.type: Easing.InOutQuad }
                            PropertyAnimation { to: -12; duration: 80; easing.type: Easing.InOutQuad }
                            PropertyAnimation { to: 0; duration: 80; easing.type: Easing.InOutQuad }
                            PauseAnimation { duration: 600 }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    RowLayout {
                        spacing: 8
                        Rectangle {
                            radius: 4
                            color: "#10b981"
                            implicitWidth: 8; implicitHeight: 8
                            SequentialAnimation on opacity {
                                running: root.visible
                                loops: Animation.Infinite
                                PropertyAnimation { to: 0.3; duration: 500 }
                                PropertyAnimation { to: 1.0; duration: 500 }
                            }
                        }
                        Label {
                            text: "QUOTA RESET ALARM"
                            font.bold: true
                            font.pixelSize: 13
                            font.letterSpacing: 1.2
                            color: "#10b981"
                        }
                    }

                    Label {
                        text: "Your quota has returned and is ready to use!"
                        font.pixelSize: 12
                        color: "#94a3b8"
                    }
                }

                // Audio waveform equalizer animation
                Row {
                    spacing: 3
                    Layout.alignment: Qt.AlignVCenter

                    Repeater {
                        model: [14, 22, 10, 18]
                        Rectangle {
                            required property int modelData
                            required property int index
                            width: 3
                            height: modelData
                            radius: 1.5
                            color: "#10b981"

                            SequentialAnimation on height {
                                running: root.visible
                                loops: Animation.Infinite
                                PropertyAnimation { to: 6 + (index * 4); duration: 250 + (index * 60); easing.type: Easing.InOutSine }
                                PropertyAnimation { to: 24 - (index * 3); duration: 250 + (index * 60); easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
            }

            // Divider
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(1, 1, 1, 0.12)
            }

            // Detailed Information Block
            Rectangle {
                Layout.fillWidth: true
                radius: 10
                color: Qt.rgba(1, 1, 1, 0.04)
                border.color: Qt.rgba(1, 1, 1, 0.08)
                border.width: 1
                implicitHeight: infoGrid.implicitHeight + 20

                GridLayout {
                    id: infoGrid
                    anchors.fill: parent
                    anchors.margins: 12
                    columns: 2
                    rowSpacing: 10
                    columnSpacing: 14

                    Label {
                        text: "Account:"
                        font.bold: true
                        font.pixelSize: 12
                        color: "#94a3b8"
                        Layout.preferredWidth: 80
                    }
                    RowLayout {
                        spacing: 6
                        Label { text: "👤"; font.pixelSize: 12 }
                        Label {
                            text: root.accountName
                            font.bold: true
                            font.pixelSize: 13
                            color: "#f8fafc"
                            elide: Text.ElideRight
                        }
                    }

                    Label {
                        text: "Provider:"
                        font.bold: true
                        font.pixelSize: 12
                        color: "#94a3b8"
                    }
                    RowLayout {
                        spacing: 6
                        Rectangle {
                            radius: 4
                            color: Qt.rgba(0.06, 0.72, 0.51, 0.2)
                            border.color: "#10b981"
                            border.width: 1
                            implicitWidth: provBadge.implicitWidth + 10
                            implicitHeight: 20
                            Label {
                                id: provBadge
                                anchors.centerIn: parent
                                text: root.providerName
                                font.bold: true
                                font.pixelSize: 11
                                color: "#10b981"
                            }
                        }
                        Label {
                            text: "• " + root.windowTitle
                            font.pixelSize: 12
                            color: "#cbd5e1"
                        }
                    }

                    Label {
                        text: "Status:"
                        font.bold: true
                        font.pixelSize: 12
                        color: "#94a3b8"
                    }
                    RowLayout {
                        spacing: 6
                        Label {
                            text: root.restoredQuota + "% Available"
                            font.bold: true
                            font.pixelSize: 13
                            color: "#10b981"
                        }
                        Label {
                            text: "• Ready for requests"
                            font.pixelSize: 11
                            color: "#94a3b8"
                        }
                    }
                }
            }

            // Explanatory note
            Label {
                text: "🔊 Sound is playing continuously until dismissed."
                font.pixelSize: 11
                color: "#64748b"
                Layout.alignment: Qt.AlignHCenter
            }

            // Action Buttons
            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Button {
                    text: "⏱ Snooze 5m"
                    font.pixelSize: 12
                    Layout.preferredHeight: 40
                    Layout.preferredWidth: 120
                    onClicked: desktop.snoozeAlarm("", 5)

                    background: Rectangle {
                        radius: 8
                        color: parent.down ? Qt.rgba(1, 1, 1, 0.15) : parent.hovered ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
                        border.color: Qt.rgba(1, 1, 1, 0.2)
                        border.width: 1
                    }
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: "#cbd5e1"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                Button {
                    id: dismissBtn
                    text: "🔕 Dismiss Alarm"
                    font.bold: true
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    Layout.preferredHeight: 40
                    onClicked: desktop.dismissAlarm()

                    background: Rectangle {
                        radius: 8
                        color: dismissBtn.down ? "#047857" : dismissBtn.hovered ? "#059669" : "#10b981"
                        border.color: "#34d399"
                        border.width: 1

                        // Glow
                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: "transparent"
                            border.color: "#10b981"
                            border.width: 2
                            opacity: 0.4
                            visible: dismissBtn.hovered
                        }
                    }
                    contentItem: Text {
                        text: parent.text
                        font: parent.font
                        color: "#ffffff"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
