import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    title: "CodexBar · Mini Quota"
    width: 390
    height: 480
    minimumWidth: 360
    minimumHeight: 400
    maximumWidth: 460
    flags: Qt.Dialog | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
    color: "transparent"

    property string selectedProviderFilter: "all"
    // Compositors may deliver focus late or never; only dismiss after the window has really been active.
    property bool hasBeenActive: false
    property int currentAccountIndex: 0
    readonly property color rootAccent: palette.highlight

    readonly property var currentAccountsList: {
        if (!desktop || !desktop.entries) return [];
        if (selectedProviderFilter === "all" || selectedProviderFilter === "") {
            return desktop.entries;
        }
        return desktop.entries.filter(function(e) {
            return e.provider === selectedProviderFilter;
        });
    }

    readonly property var currentEntry: {
        var list = currentAccountsList;
        if (!list || list.length === 0) return null;
        var idx = Math.max(0, Math.min(currentAccountIndex, list.length - 1));
        return list[idx];
    }

    readonly property bool isTopAccount: {
        if (!currentEntry) return false;
        if (currentEntry.accountNumber !== undefined && currentEntry.accountNumber !== null) {
            return currentEntry.accountNumber === 1;
        }
        return currentAccountIndex === 0;
    }

    readonly property string currentAccountLabel: {
        if (!currentEntry) return "No Account";
        if (currentEntry.accountLabel && currentEntry.accountLabel !== "") {
            return currentEntry.accountLabel;
        }
        if (currentEntry.accountNumber) {
            return "Account " + currentEntry.accountNumber;
        }
        return Usage.providerName(currentEntry.provider) + " Account";
    }

    readonly property string currentAccountCounter: {
        var list = currentAccountsList;
        if (!list || list.length <= 1) return "";
        var idx = Math.max(0, Math.min(currentAccountIndex, list.length - 1));
        return (idx + 1) + " of " + list.length;
    }

    function nextAccount() {
        var list = currentAccountsList;
        if (!list || list.length <= 1) return;
        currentAccountIndex = (currentAccountIndex + 1) % list.length;
    }

    function previousAccount() {
        var list = currentAccountsList;
        if (!list || list.length <= 1) return;
        currentAccountIndex = (currentAccountIndex - 1 + list.length) % list.length;
    }

    function selectProvider(prov) {
        selectedProviderFilter = prov;
        currentAccountIndex = 0;
    }

    function positionNearCursor() {
        var cx = desktop ? desktop.cursorX() : 0;
        var cy = desktop ? desktop.cursorY() : 0;
        var screenW = Screen.desktopAvailableWidth || Screen.width || 1920;
        var screenH = Screen.desktopAvailableHeight || Screen.height || 1080;

        if (cx > 0 || cy > 0) {
            var targetX = Math.min(Math.max(16, cx - width / 2), screenW - width - 16);
            var targetY = cy < screenH / 2 ? Math.min(cy + 16, screenH - height - 16) : Math.max(16, cy - height - 16);
            window.x = targetX;
            window.y = targetY;
        }

        // Ensure top account is selected on open
        if (desktop && desktop.entries && desktop.entries.length > 0) {
            var top = desktop.entries[0];
            if (top && top.provider) {
                selectedProviderFilter = top.provider;
            }
        }
        currentAccountIndex = 0;

        window.show();
        window.raise();
        window.requestActivate();
    }

    onActiveChanged: {
        if (active) hasBeenActive = true;
        else if (hasBeenActive && visible) hide();
    }
    onVisibleChanged: if (!visible) hasBeenActive = false

    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    Shortcut { sequence: "Left"; onActivated: window.previousAccount() }
    Shortcut { sequence: "Right"; onActivated: window.nextAccount() }
    Shortcut { sequence: "Ctrl+R"; onActivated: { desktop.refresh(); desktop.refreshCosts(); } }

    Timer {
        id: clock
        property double now: Date.now()
        interval: 30000
        running: window.visible
        repeat: true
        onTriggered: now = Date.now()
    }

    Rectangle {
        id: cardBg
        anchors.fill: parent
        radius: 12
        color: palette.window
        border.color: palette.mid
        border.width: 1
        opacity: desktop && desktop.settings && desktop.settings.miniOpacity !== undefined ? Number(desktop.settings.miniOpacity) : 0.90

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            // Top Window Bar (CodexBar title + Close button)
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                DragHandler {
                    target: null
                    onActiveChanged: if (active) window.startSystemMove()
                }

                Image {
                    source: ":/icon.svg"
                    sourceSize: Qt.size(20, 20)
                    Layout.preferredWidth: 20
                    Layout.preferredHeight: 20
                    fillMode: Image.PreserveAspectFit
                }

                Label {
                    text: "CodexBar"
                    font.bold: true
                    font.pixelSize: 13
                    opacity: 0.85
                }

                Label {
                    text: "· Quota Details"
                    font.pixelSize: 12
                    opacity: 0.6
                    Layout.fillWidth: true
                }

                ToolButton {
                    text: "✕"
                    font.pixelSize: 12
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    onClicked: window.hide()
                    ToolTip.visible: hovered
                    ToolTip.text: "Close (Esc)"
                }
            }

            // Hero Account Navigation Card
            Frame {
                id: accountNavCard
                Layout.fillWidth: true
                padding: 10
                background: Rectangle {
                    color: palette.base
                    radius: 8
                    border.color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.12)
                    border.width: 1
                }

                ColumnLayout {
                    width: parent.width
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        // Back Arrow
                        Button {
                            id: prevBtn
                            text: "◀"
                            font.pixelSize: 14
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            enabled: window.currentAccountsList.length > 1
                            onClicked: window.previousAccount()
                            ToolTip.visible: hovered
                            ToolTip.text: "Previous Account (Left arrow)"
                        }

                        // Center Account Header
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Image {
                                source: currentEntry ? Usage.providerIcon(currentEntry.provider) : ""
                                sourceSize: Qt.size(28, 28)
                                Layout.preferredWidth: 28
                                Layout.preferredHeight: 28
                                fillMode: Image.PreserveAspectFit
                                visible: source !== ""
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Label {
                                        text: currentEntry ? Usage.providerName(currentEntry.provider) : "Provider"
                                        font.bold: true
                                        font.pixelSize: 15
                                    }

                                    // Top Account Badge
                                    Rectangle {
                                        visible: window.isTopAccount
                                        radius: 4
                                        color: "#22c55e"
                                        implicitWidth: topBadgeText.implicitWidth + 8
                                        implicitHeight: 18

                                        Label {
                                            id: topBadgeText
                                            text: "TOP"
                                            font.bold: true
                                            font.pixelSize: 10
                                            color: "#ffffff"
                                            anchors.centerIn: parent
                                        }
                                    }

                                    Item { Layout.fillWidth: true }

                                    Label {
                                        text: window.currentAccountCounter
                                        visible: text !== ""
                                        font.pixelSize: 12
                                        opacity: 0.7
                                    }

                                    Button {
                                        id: miniAccRefreshBtn
                                        property bool isRefreshing: currentEntry ? desktop.isAccountRefreshing(currentEntry.provider, currentEntry.accountNumber || 1) : false
                                        text: isRefreshing ? "…" : "↻"
                                        visible: currentEntry && window.currentAccountsList.length > 1
                                        enabled: !desktop.busy && !isRefreshing
                                        Layout.preferredWidth: 26
                                        Layout.preferredHeight: 22
                                        padding: 0
                                        contentItem: Text {
                                            text: miniAccRefreshBtn.text
                                            font.pixelSize: 13
                                            font.bold: true
                                            color: window.rootAccent
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: miniAccRefreshBtn.hovered ? Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.08) : "transparent"
                                            radius: 4
                                        }
                                        ToolTip.visible: hovered
                                        ToolTip.text: window.isTopAccount ? "Refresh Top Account" : "Refresh this account"
                                        onClicked: {
                                            desktop.refreshAccount(currentEntry.provider, currentEntry.accountNumber || 1);
                                        }
                                    }
                                }

                                Label {
                                    text: window.currentAccountLabel
                                    font.bold: true
                                    font.pixelSize: 12
                                    color: window.rootAccent
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                }
                            }
                        }

                        // Forward Arrow
                        Button {
                            id: nextBtn
                            text: "▶"
                            font.pixelSize: 14
                            Layout.preferredWidth: 34
                            Layout.preferredHeight: 34
                            enabled: window.currentAccountsList.length > 1
                            onClicked: window.nextAccount()
                            ToolTip.visible: hovered
                            ToolTip.text: "Next Account (Right arrow)"
                        }
                    }

                    // "Set as Top Account" button if viewed account is not currently top
                    Button {
                        text: "★ Set as Top Account"
                        visible: !window.isTopAccount && currentEntry && currentEntry.accountNumber > 1
                        font.pixelSize: 11
                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        onClicked: {
                            desktop.setTopAccount(currentEntry.provider, currentEntry.accountNumber - 1);
                        }
                    }

                    // Dedicated Refresh Control for the top account
                    Button {
                        id: refreshTopBtn
                        property bool isRefreshing: currentEntry ? desktop.isAccountRefreshing(currentEntry.provider, 1) : false
                        text: isRefreshing ? "↻ Refreshing Top Account…" : "↻ Refresh Top Account"
                        visible: window.isTopAccount && currentEntry && window.currentAccountsList.length > 1
                        font.pixelSize: 11
                        font.bold: true
                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        enabled: !desktop.busy && !isRefreshing
                        onClicked: {
                            desktop.refreshAccount(currentEntry.provider, 1);
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: "Refresh only this top account without scrolling down or fetching all accounts"
                    }
                }
            }

            // Distinctive divider between account section and quota details
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.16)
                Layout.topMargin: 2
                Layout.bottomMargin: 2
            }

            // Quota Details (Scrollable progress bars)
            ScrollView {
                id: quotaScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: quotaScroll.availableWidth
                    spacing: 10

                    // Account Plan & Status
                    RowLayout {
                        Layout.fillWidth: true
                        visible: currentEntry && ((currentEntry.plan || "") !== "" || (currentEntry.status || "") !== "")
                        spacing: 6

                        Label {
                            text: currentEntry && currentEntry.plan ? currentEntry.plan : ""
                            font.pixelSize: 11
                            opacity: 0.65
                            visible: text !== ""
                        }

                        Label {
                            text: "·"
                            font.pixelSize: 11
                            opacity: 0.5
                            visible: currentEntry && currentEntry.plan && currentEntry.status
                        }

                        Label {
                            text: currentEntry && currentEntry.status ? currentEntry.status : ""
                            font.pixelSize: 11
                            opacity: 0.65
                            visible: text !== ""
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                        }
                    }

                    // Account Error
                    Rectangle {
                        visible: currentEntry && currentEntry.error && currentEntry.error !== ""
                        Layout.fillWidth: true
                        radius: 6
                        color: Qt.rgba(0.9, 0.2, 0.2, 0.15)
                        border.color: "#ef4444"
                        border.width: 1
                        implicitHeight: errLabel.implicitHeight + 12

                        Label {
                            id: errLabel
                            anchors.fill: parent
                            anchors.margins: 6
                            text: currentEntry ? currentEntry.error : ""
                            color: "#ef4444"
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }

                    // Quota Windows (canonical order for Antigravity)
                    Repeater {
                        model: {
                            if (!currentEntry) return [];
                            if (currentEntry.provider !== "antigravity") return currentEntry.windows || [];
                            var list = (currentEntry.windows || []).slice();
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
                            spacing: 4

                            // Standard header for Factory if Core windows exist
                            Label {
                                visible: currentEntry && currentEntry.provider === "factory" && index === 0 && (currentEntry.windows || []).some(function(w) { return (w.label || "").toLowerCase().indexOf("core") !== -1; })
                                text: "Standard"
                                font.pixelSize: 10
                                font.bold: true
                                opacity: 0.6
                                color: palette.text
                                textFormat: Text.PlainText
                            }

                            // Subtle, clear divider separating Standard and Core sections for Factory
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                visible: {
                                    if (!currentEntry || currentEntry.provider !== "factory") return false;
                                    var isCore = (modelData.label || "").toLowerCase().indexOf("core") !== -1;
                                    if (!isCore) return false;
                                    var windows = currentEntry.windows || [];
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
                                    font.pixelSize: 10
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
                                    id: starBtn
                                    property bool isStarred: currentEntry && desktop.isStarredModel(currentEntry.provider, modelData.label, modelData.key)
                                    text: isStarred ? "★" : "☆"
                                    Layout.preferredWidth: 22
                                    Layout.preferredHeight: 22
                                    padding: 0
                                    contentItem: Text {
                                        text: starBtn.text
                                        font.pixelSize: 13
                                        color: starBtn.isStarred ? "#f59e0b" : Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.35)
                                        horizontalAlignment: Text.AlignHCenter
                                        verticalAlignment: Text.AlignVCenter
                                    }
                                    background: Rectangle {
                                        color: starBtn.hovered ? Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.08) : "transparent"
                                        radius: 4
                                    }
                                    ToolTip.visible: hovered
                                    ToolTip.text: isStarred ? "Starred model (displayed in top bar)" : "Star this model for top bar"
                                    onClicked: {
                                        if (currentEntry) desktop.setStarredModel(currentEntry.provider, modelData.label, modelData.key);
                                    }
                                }

                                Label {
                                    text: modelData.label
                                    font.pixelSize: 12
                                    font.bold: starBtn.isStarred
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    textFormat: Text.PlainText
                                }

                                Label {
                                    text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + (desktop.settings.quotaDisplay === "used" ? "used" : "left")
                                    font.bold: true
                                    font.pixelSize: 12
                                    color: starBtn.isStarred ? "#f59e0b" : palette.text
                                }
                            }

                            ProgressBar {
                                Layout.fillWidth: true
                                implicitHeight: 7
                                from: 0
                                to: 100
                                value: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay)
                                palette.highlight: Usage.progressBarColor(modelData.remaining, window.rootAccent, desktop.settings.warningColors)
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                Label {
                                    text: Usage.resetText(modelData.resetsAt, clock.now, desktop.settings.resetDisplay)
                                    opacity: 0.65
                                    font.pixelSize: 10
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                }

                                Label {
                                    text: modelData.pace || ""
                                    visible: desktop.settings.showPace && text !== ""
                                    Layout.fillWidth: true
                                    wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignRight
                                    opacity: 0.7
                                    font.pixelSize: 10
                                }
                            }
                        }
                    }

                    // Credits label if available
                    Label {
                        text: "Credits: " + (currentEntry ? currentEntry.credits : "")
                        visible: currentEntry && currentEntry.credits !== null && currentEntry.credits !== undefined
                        font.pixelSize: 11
                        font.bold: true
                    }

                    // Details sections (e.g. Promotions, Credits, etc.)
                    Repeater {
                        model: (currentEntry && currentEntry.details) ? currentEntry.details : []

                        ColumnLayout {
                            required property var modelData
                            Layout.fillWidth: true
                            spacing: 2

                            Label {
                                text: modelData.title
                                visible: text !== ""
                                font.bold: true
                                font.pixelSize: 10
                                opacity: 0.8
                            }

                            Repeater {
                                model: modelData.rows

                                Label {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    text: modelData.label + ": " + modelData.value + (modelData.secondaryValue ? " · " + modelData.secondaryValue : "")
                                    textFormat: Text.PlainText
                                    wrapMode: Text.Wrap
                                    font.pixelSize: 10
                                }
                            }
                        }
                    }

                    // Empty quota placeholder
                    Label {
                        visible: currentEntry && (!currentEntry.windows || currentEntry.windows.length === 0) && (!currentEntry.error || currentEntry.error === "")
                        text: "No quota details available for this account."
                        opacity: 0.6
                        font.italic: true
                        font.pixelSize: 11
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            // Quick Provider Switcher Strip (Horizontal Scroll)
            ScrollView {
                id: provScroll
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff
                clip: true

                RowLayout {
                    spacing: 4

                    Repeater {
                        model: desktop ? desktop.uniqueProviders : []

                        Button {
                            required property var modelData
                            property bool isSelected: window.selectedProviderFilter === modelData
                            text: Usage.providerName(modelData)
                            icon.source: Usage.providerIcon(modelData)
                            icon.width: 14
                            icon.height: 14
                            icon.color: "transparent"
                            font.pixelSize: 10
                            font.bold: isSelected
                            Layout.preferredHeight: 26
                            flat: !isSelected
                            onClicked: window.selectProvider(modelData)
                        }
                    }

                    Button {
                        property bool isSelected: window.selectedProviderFilter === "all"
                        text: "All (" + (desktop && desktop.entries ? desktop.entries.length : 0) + ")"
                        font.pixelSize: 10
                        font.bold: isSelected
                        Layout.preferredHeight: 26
                        flat: !isSelected
                        onClicked: window.selectProvider("all")
                    }
                }
            }

            // Bottom Action Row
            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Button {
                    text: "Usage & Spend…"
                    font.pixelSize: 11
                    Layout.preferredHeight: 28
                    onClicked: {
                        window.hide();
                        desktop.showWindow("usage");
                    }
                }

                Button {
                    text: "Settings…"
                    font.pixelSize: 11
                    Layout.preferredHeight: 28
                    onClicked: {
                        window.hide();
                        desktop.showWindow("settings");
                    }
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: desktop && desktop.busy ? "Refreshing…" : "Refresh"
                    font.pixelSize: 11
                    Layout.preferredHeight: 28
                    enabled: desktop && !desktop.busy
                    onClicked: {
                        desktop.refresh();
                        desktop.refreshCosts();
                    }
                }

                Button {
                    text: "Quit"
                    font.pixelSize: 11
                    Layout.preferredHeight: 28
                    onClicked: Qt.quit()
                }
            }
        }
    }
}
