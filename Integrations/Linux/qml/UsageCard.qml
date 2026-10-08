import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

Frame {
    id: root
    required property var entry
    property color accent: palette.highlight
    padding: 14
    Layout.fillWidth: true
    implicitHeight: content.implicitHeight + topPadding + bottomPadding
    background: Rectangle {
        color: palette.base
        radius: 10
        border.color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.12)
        border.width: 1
    }
    ColumnLayout {
        id: content
        width: parent.width
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Image {
                id: providerIcon
                source: Usage.providerIcon(root.entry.provider)
                sourceSize: Qt.size(24, 24)
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                visible: source !== "" && status === Image.Ready
                fillMode: Image.PreserveAspectFit
            }
            Label { text: Usage.providerName(root.entry.provider); font.bold: true; font.pixelSize: 18; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Rectangle {
                visible: (root.entry.plan || "") !== ""
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
                border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                border.width: 1
                radius: 10
                implicitHeight: 22
                implicitWidth: planText.implicitWidth + 14
                Label {
                    id: planText
                    anchors.centerIn: parent
                    text: root.entry.plan || ""
                    font.pixelSize: 11
                    font.bold: true
                    color: root.accent
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            visible: (root.entry.accountLabel || "") !== "" || root.entry.isDraining === true || desktop.providerAccountCount(root.entry.provider) > 1 || (root.entry.bankedResets && root.entry.bankedResets.available)
            spacing: 8
            Rectangle {
                visible: desktop.providerAccountCount(root.entry.provider) > 1
                color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
                radius: 4
                border.color: root.accent
                border.width: 1
                Layout.preferredHeight: 24
                implicitWidth: acctNumLabel.implicitWidth + 12
                Label {
                    id: acctNumLabel
                    anchors.centerIn: parent
                    text: "Account " + root.entry.accountNumber + " of " + desktop.providerAccountCount(root.entry.provider)
                    font.pixelSize: 11
                    font.bold: true
                    color: root.accent
                }
            }
            Rectangle {
                visible: root.entry.isDraining === true
                color: Qt.rgba(0.96, 0.62, 0.04, 0.2)
                radius: 4
                border.color: "#f59e0b"
                border.width: 1
                Layout.preferredHeight: 24
                implicitWidth: drainingBadgeLabel.implicitWidth + 12
                Label {
                    id: drainingBadgeLabel
                    anchors.centerIn: parent
                    text: "⚡ Draining"
                    font.pixelSize: 11
                    font.bold: true
                    color: "#f59e0b"
                }
            }
            Rectangle {
                visible: root.entry.bankedResets && root.entry.bankedResets.available === true
                color: Qt.rgba(0.06, 0.72, 0.51, 0.18)
                radius: 4
                border.color: "#10b981"
                border.width: 1
                Layout.preferredHeight: 24
                implicitWidth: bankedBadgeLabel.implicitWidth + 14
                Label {
                    id: bankedBadgeLabel
                    anchors.centerIn: parent
                    text: "⚡ " + (root.entry.bankedResets ? root.entry.bankedResets.text : "") + " Banked"
                    font.pixelSize: 11
                    font.bold: true
                    color: "#10b981"
                }
                ToolTip.visible: bankedBadgeArea.containsMouse
                ToolTip.text: root.entry.bankedResets ? ("Banked rate limit resets: " + root.entry.bankedResets.summary) : ""
                MouseArea {
                    id: bankedBadgeArea
                    anchors.fill: parent
                    hoverEnabled: true
                }
            }
            Label {
                text: root.entry.accountLabel || ""
                font.bold: true
                font.pixelSize: 14
                color: root.accent
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
            Button {
                text: "★ Set as Top"
                visible: root.entry.accountNumber > 1
                font.pixelSize: 11
                Layout.preferredHeight: 26
                onClicked: desktop.setTopAccount(root.entry.provider, root.entry.accountNumber - 1)
            }
            Button {
                id: cardRefreshTopBtn
                property bool isRefreshing: desktop.isAccountRefreshing(root.entry.provider, 1)
                text: isRefreshing ? "↻ Refreshing…" : "↻ Refresh Top"
                visible: root.entry.accountNumber === 1 && desktop.providerAccountCount(root.entry.provider) > 1
                font.pixelSize: 11
                Layout.preferredHeight: 26
                enabled: !desktop.busy && !isRefreshing
                onClicked: desktop.refreshAccount(root.entry.provider, 1)
                ToolTip.visible: hovered
                ToolTip.text: "Refresh only this top account without fetching all accounts"
            }
        }
        Rectangle {
            Layout.fillWidth: true
            height: 1
            color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.14)
            visible: (root.entry.accountLabel || "") !== ""
            Layout.topMargin: 2
            Layout.bottomMargin: 2
        }
        Label { text: root.entry.status || ""; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.7 }
        Label { text: root.entry.error || ""; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap }
        Repeater {
            model: {
                if (root.entry.provider !== "antigravity") return root.entry.windows;
                var list = (root.entry.windows || []).slice();
                var order = function(w) {
                    var l = (w.label || "").toLowerCase();
                    if (l.indexOf("gemini") !== -1) return (l.indexOf("5-hour") !== -1 || l.indexOf("5 hour") !== -1) ? 1 : 2;
                    return (l.indexOf("5-hour") !== -1 || l.indexOf("5 hour") !== -1) ? 3 : 4;
                };
                return list.sort(function(a, b) { return order(a) - order(b); });
            }
            ColumnLayout {
                required property var modelData
                required property int index
                Layout.fillWidth: true
                spacing: 6

                // Standard header for Factory if Core windows exist
                Label {
                    visible: root.entry && root.entry.provider === "factory" && index === 0 && (root.entry.windows || []).some(function(w) { return (w.label || "").toLowerCase().indexOf("core") !== -1; })
                    text: "Standard"
                    font.pixelSize: 11
                    font.bold: true
                    opacity: 0.6
                    color: palette.text
                    textFormat: Text.PlainText
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                }

                // Subtle, clear divider separating Standard and Core sections for Factory
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: {
                        if (!root.entry || root.entry.provider !== "factory") return false;
                        var isCore = (modelData.label || "").toLowerCase().indexOf("core") !== -1;
                        if (!isCore) return false;
                        var windows = root.entry.windows || [];
                        return (index === 0 || (windows[index - 1] && (windows[index - 1].label || "").toLowerCase().indexOf("core") === -1));
                    }
                    Layout.topMargin: 8
                    Layout.bottomMargin: 4

                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.20)
                    }

                    Label {
                        text: "Core"
                        font.pixelSize: 11
                        font.bold: true
                        opacity: 0.6
                        color: palette.text
                        textFormat: Text.PlainText
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Button {
                        id: cardStarBtn
                        property bool isStarred: root.entry && desktop.isStarredModel(root.entry.provider, modelData.label, modelData.key)
                        text: isStarred ? "★" : "☆"
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        padding: 0
                        contentItem: Text {
                            text: cardStarBtn.text
                            font.pixelSize: 13
                            color: cardStarBtn.isStarred ? "#f59e0b" : Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.35)
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: cardStarBtn.hovered ? Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.08) : "transparent"
                            radius: 4
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: isStarred ? "Starred model (displayed in top bar)" : "Star this model for top bar"
                        onClicked: {
                            if (root.entry) desktop.setStarredModel(root.entry.provider, modelData.label, modelData.key);
                        }
                    }
                    Label { text: modelData.label; font.bold: cardStarBtn.isStarred; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    Label { text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + (desktop.settings.quotaDisplay === "used" ? "used" : "left"); font.bold: true; color: cardStarBtn.isStarred ? "#f59e0b" : palette.text }
                }
                ProgressBar { Layout.fillWidth: true; from: 0; to: 100; value: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay); palette.highlight: Usage.progressBarColor(modelData.remaining, root.accent, desktop.settings.warningColors) }
                Label { text: Usage.resetText(modelData.resetsAt, clock.now, desktop.settings.resetDisplay); opacity: 0.65; Layout.fillWidth: true; wrapMode: Text.Wrap }
                Label { text: modelData.pace || ""; visible: desktop.settings.showPace && text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.7 }
            }
        }

        // Dedicated Banked Resets Card Block
        Rectangle {
            id: bankedResetsCard
            visible: root.entry.bankedResets && root.entry.bankedResets.available === true
            Layout.fillWidth: true
            radius: 8
            color: Qt.rgba(0.06, 0.72, 0.51, 0.10)
            border.color: Qt.rgba(0.06, 0.72, 0.51, 0.35)
            border.width: 1
            implicitHeight: bankedResetsContent.implicitHeight + 16

            RowLayout {
                id: bankedResetsContent
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                Label {
                    text: "⚡"
                    font.pixelSize: 14
                }

                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true

                    RowLayout {
                        spacing: 6
                        Label {
                            text: "Banked Resets:"
                            font.bold: true
                            font.pixelSize: 12
                            color: palette.text
                        }
                        Label {
                            text: root.entry.bankedResets ? root.entry.bankedResets.text : ""
                            font.bold: true
                            font.pixelSize: 12
                            color: "#10b981"
                        }
                    }

                    Label {
                        text: (root.entry.bankedResets && root.entry.bankedResets.expiryText) ? root.entry.bankedResets.expiryText : ""
                        font.pixelSize: 11
                        opacity: 0.75
                        color: palette.text
                        visible: text !== ""
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Label { text: "Credits: " + root.entry.credits; visible: root.entry.credits !== null && root.entry.credits !== undefined }
        Repeater {
            model: root.entry.details || []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                Label { text: modelData.title; visible: text !== ""; font.bold: true }
                Repeater {
                    model: {
                        var rows = modelData.rows || [];
                        if (root.entry.bankedResets && root.entry.bankedResets.available) {
                            return rows.filter(function(r) {
                                var l = (r.label || "").toLowerCase();
                                return l.indexOf("limit reset") === -1 && l.indexOf("reset credit") === -1 && l.indexOf("banked reset") === -1;
                            });
                        }
                        return rows;
                    }
                    Label {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.label + ": " + modelData.value + (modelData.secondaryValue ? " · " + modelData.secondaryValue : "")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }
                UsageChart { Layout.fillWidth: true; chart: modelData.chart; accent: root.accent }
            }
        }
    }
    Timer { id: clock; property double now: Date.now(); interval: 30000; running: root.visible; repeat: true; onTriggered: now = Date.now() }
}
