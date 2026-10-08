import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    title: "CodexBar · Side Dock"
    flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
    color: "transparent"

    // Docking & screen anchoring
    property bool isLeftDocked: desktop && desktop.settings && desktop.settings.sidebarSide === "left"
    property bool isPinned: desktop && desktop.settings && desktop.settings.sidebarPinned !== undefined ? desktop.settings.sidebarPinned : true
    property bool isCollapsed: desktop && desktop.settings && desktop.settings.sidebarCollapsed !== undefined ? desktop.settings.sidebarCollapsed : false

    // Opacity settings
    property real userOpacity: desktop && desktop.settings && desktop.settings.sidebarOpacity !== undefined ? Number(desktop.settings.sidebarOpacity) : 0.85
    property bool hoverBrighten: desktop && desktop.settings && desktop.settings.sidebarHoverBrighten !== undefined ? desktop.settings.sidebarHoverBrighten : true
    property bool showOpacityPanel: false

    // Provider filter
    property string selectedProviderFilter: "all"
    property color rootAccent: palette.highlight

    readonly property var visibleEntries: {
        if (!desktop || !desktop.entries) return [];
        if (selectedProviderFilter === "all") return desktop.entries;
        return desktop.entries.filter(function(e) {
            return e.provider === selectedProviderFilter;
        });
    }

    // Dimensions
    width: isCollapsed ? 36 : 240
    height: Math.min(680, Math.max(480, (Screen.desktopAvailableHeight || Screen.height || 900) - 80))

    Behavior on width {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }

    // Hover detection & dynamic opacity
    readonly property bool isHovered: hoverArea.hovered

    // Snap to screen edge
    function snapToDock() {
        var screenW = Screen.desktopAvailableWidth || Screen.width || 1920;
        var screenH = Screen.desktopAvailableHeight || Screen.height || 1080;
        var availX = Screen.desktopAvailableX || 0;
        var availY = Screen.desktopAvailableY || 0;

        if (isLeftDocked) {
            window.x = availX + 8;
        } else {
            window.x = availX + screenW - window.width - 8;
        }
        window.y = availY + Math.max(20, Math.round((screenH - window.height) / 2));
    }

    function toggleOrShow() {
        snapToDock();
        if (visible) {
            if (isCollapsed) {
                isCollapsed = false;
                if (desktop) desktop.saveSettings({sidebarCollapsed: false});
            }
            raise();
            requestActivate();
        } else {
            show();
            raise();
            requestActivate();
        }
    }

    function toggleCollapse() {
        isCollapsed = !isCollapsed;
        if (desktop) desktop.saveSettings({sidebarCollapsed: isCollapsed});
        snapToDock();
    }

    function toggleDockSide() {
        isLeftDocked = !isLeftDocked;
        if (desktop) desktop.saveSettings({sidebarSide: isLeftDocked ? "left" : "right"});
        snapToDock();
    }

    function setOpacity(val) {
        userOpacity = Math.max(0.20, Math.min(1.00, Math.round(val * 100) / 100));
        if (desktop) desktop.saveSettings({sidebarOpacity: userOpacity});
    }

    Component.onCompleted: snapToDock()
    onWidthChanged: snapToDock()

    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    Shortcut { sequence: "Ctrl+R"; onActivated: { if (desktop) { desktop.refresh(); desktop.refreshCosts(); } } }

    Timer {
        id: clock
        property double now: Date.now()
        interval: 30000
        running: window.visible
        repeat: true
        onTriggered: now = Date.now()
    }

    // Outer container
    Rectangle {
        id: bgCard
        anchors.fill: parent
        radius: isCollapsed ? 6 : 10
        color: palette.window
        border.color: palette.mid
        border.width: 1
        clip: true
        opacity: (hoverBrighten && isHovered) ? Math.min(1.0, Math.max(userOpacity + 0.15, 0.95)) : userOpacity

        Behavior on opacity {
            NumberAnimation { duration: 160 }
        }

        HoverHandler {
            id: hoverArea
        }

        // ==========================================
        // 1. COLLAPSED SLIM STRIP VIEW
        // ==========================================
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 6
            visible: isCollapsed

            Button {
                id: expandBtn
                text: window.isLeftDocked ? "▶" : "◀"
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignHCenter
                font.pixelSize: 11
                onClicked: window.toggleCollapse()
                ToolTip.visible: hovered
                ToolTip.text: "Expand Side Bar"
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.15)
            }

            // Quick provider status indicators
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                ColumnLayout {
                    width: parent.width
                    spacing: 8

                    Repeater {
                        model: desktop ? desktop.entries : []
                        Rectangle {
                            required property var modelData
                            Layout.preferredWidth: 26
                            Layout.preferredHeight: 26
                            Layout.alignment: Qt.AlignHCenter
                            radius: 13
                            color: {
                                var windows = modelData.windows || [];
                                for (var i = 0; i < windows.length; ++i) {
                                    var rem = windows[i].remaining;
                                    var used = 100 - rem;
                                    if (used >= 90) return "#ef4444";
                                    if (used >= 75) return "#f59e0b";
                                }
                                return palette.highlight;
                            }
                            opacity: 0.85

                            Image {
                                id: stripIcon
                                anchors.centerIn: parent
                                width: 16
                                height: 16
                                source: Usage.providerIcon(modelData.provider)
                                fillMode: Image.PreserveAspectFit
                                visible: status === Image.Ready
                            }

                            Label {
                                anchors.centerIn: parent
                                text: Usage.providerName(modelData.provider).charAt(0).toUpperCase()
                                font.bold: true
                                font.pixelSize: 11
                                color: "#ffffff"
                                visible: !stripIcon.visible
                            }

                            ToolTip.visible: stripHover.hovered
                            ToolTip.text: Usage.providerName(modelData.provider) + "\n" + (modelData.accountLabel || "")

                            HoverHandler { id: stripHover }

                            TapHandler {
                                onTapped: {
                                    window.selectedProviderFilter = modelData.provider;
                                    window.toggleCollapse();
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.15)
            }

            // Opacity indicator chip
            Label {
                text: Math.round(window.userOpacity * 100) + "%"
                font.pixelSize: 9
                font.bold: true
                opacity: 0.6
                Layout.alignment: Qt.AlignHCenter
            }
        }

        // ==========================================
        // 2. EXPANDED FULL SIDE BAR VIEW
        // ==========================================
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6
            visible: !isCollapsed

            // --- Window Top Bar (Drag, Controls, Opacity) ---
            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                DragHandler {
                    target: null
                    onActiveChanged: if (active) window.startSystemMove()
                }

                Label {
                    text: "CodexBar"
                    font.bold: true
                    font.pixelSize: 13
                    Layout.fillWidth: true
                }

                // Dock Side Switch (Left / Right)
                Button {
                    text: window.isLeftDocked ? "⇥" : "⇤"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    font.pixelSize: 11
                    padding: 0
                    onClicked: window.toggleDockSide()
                    ToolTip.visible: hovered
                    ToolTip.text: window.isLeftDocked ? "Dock to Right side" : "Dock to Left side"
                }

                // Opacity Adjuster Button
                Button {
                    id: opacityBtn
                    text: "◐ " + Math.round(window.userOpacity * 100) + "%"
                    Layout.preferredHeight: 24
                    font.pixelSize: 10
                    font.bold: true
                    padding: 4
                    highlighted: window.showOpacityPanel
                    onClicked: window.showOpacityPanel = !window.showOpacityPanel
                    ToolTip.visible: hovered && !window.showOpacityPanel
                    ToolTip.text: "Adjust Bar Opacity (Currently " + Math.round(window.userOpacity * 100) + "%)"
                }

                // Pin Button
                Button {
                    text: window.isPinned ? "📌" : "📍"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    font.pixelSize: 11
                    padding: 0
                    highlighted: window.isPinned
                    onClicked: {
                        window.isPinned = !window.isPinned;
                        if (desktop) desktop.saveSettings({sidebarPinned: window.isPinned});
                    }
                    ToolTip.visible: hovered
                    ToolTip.text: window.isPinned ? "Always on top: Pinned" : "Always on top: Unpinned"
                }

                // Collapse Button
                Button {
                    text: window.isLeftDocked ? "◀" : "▶"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    font.pixelSize: 11
                    padding: 0
                    onClicked: window.toggleCollapse()
                    ToolTip.visible: hovered
                    ToolTip.text: "Collapse to edge strip"
                }

                // Close Button
                Button {
                    text: "✕"
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    font.pixelSize: 11
                    padding: 0
                    onClicked: window.hide()
                    ToolTip.visible: hovered
                    ToolTip.text: "Close side bar"
                }
            }

            // --- Interactive Opacity Drawer (Shown when toggled) ---
            Rectangle {
                id: opacityDrawer
                visible: window.showOpacityPanel
                Layout.fillWidth: true
                radius: 6
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.08)
                border.color: palette.highlight
                border.width: 1
                implicitHeight: opacityCol.implicitHeight + 12

                ColumnLayout {
                    id: opacityCol
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            text: "Bar Opacity: " + Math.round(window.userOpacity * 100) + "%"
                            font.bold: true
                            font.pixelSize: 11
                            Layout.fillWidth: true
                        }
                        Button {
                            text: "Done"
                            font.pixelSize: 10
                            Layout.preferredHeight: 20
                            onClicked: window.showOpacityPanel = false
                        }
                    }

                    Slider {
                        Layout.fillWidth: true
                        from: 0.20
                        to: 1.00
                        stepSize: 0.05
                        value: window.userOpacity
                        onMoved: window.setOpacity(value)
                    }

                    // Opacity Presets Row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        Repeater {
                            model: [
                                { label: "25%", val: 0.25, name: "Ghost" },
                                { label: "50%", val: 0.50, name: "Glass" },
                                { label: "75%", val: 0.75, name: "Subtle" },
                                { label: "90%", val: 0.90, name: "Clear" },
                                { label: "100%", val: 1.00, name: "Solid" }
                            ]
                            Button {
                                required property var modelData
                                text: modelData.label
                                font.pixelSize: 9
                                font.bold: Math.abs(window.userOpacity - modelData.val) < 0.03
                                Layout.fillWidth: true
                                Layout.preferredHeight: 22
                                highlighted: Math.abs(window.userOpacity - modelData.val) < 0.03
                                onClicked: window.setOpacity(modelData.val)
                                ToolTip.visible: hovered
                                ToolTip.text: modelData.name + " (" + modelData.label + ")"
                            }
                        }
                    }

                    CheckBox {
                        text: "Brighten on hover"
                        font.pixelSize: 10
                        checked: window.hoverBrighten
                        Layout.fillWidth: true
                        onToggled: {
                            window.hoverBrighten = checked;
                            if (desktop) desktop.saveSettings({sidebarHoverBrighten: checked});
                        }
                    }
                }
            }

            // --- Provider Quick Filter Chips ---
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                contentHeight: 28
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: ScrollBar.AlwaysOff

                RowLayout {
                    spacing: 4

                    Button {
                        text: "All"
                        font.pixelSize: 10
                        font.bold: window.selectedProviderFilter === "all"
                        highlighted: window.selectedProviderFilter === "all"
                        Layout.preferredHeight: 24
                        onClicked: window.selectedProviderFilter = "all"
                    }

                    Repeater {
                        model: desktop ? desktop.uniqueProviders : []
                        Button {
                            required property string modelData
                            text: Usage.providerName(modelData)
                            font.pixelSize: 10
                            font.bold: window.selectedProviderFilter === modelData
                            highlighted: window.selectedProviderFilter === modelData
                            Layout.preferredHeight: 24
                            onClicked: window.selectedProviderFilter = modelData
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.15)
            }

            // --- Scrollable Quota Cards ---
            ScrollView {
                id: mainScroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: availableWidth

                ColumnLayout {
                    width: mainScroll.availableWidth
                    spacing: 10

                    Repeater {
                        model: window.visibleEntries

                        ColumnLayout {
                            id: entryCardDelegate
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            spacing: 6

                            // Distinctive Account Divider
                            Rectangle {
                                visible: index > 0
                                Layout.fillWidth: true
                                height: 2
                                radius: 1
                                color: {
                                    var prev = window.visibleEntries[index - 1];
                                    if (prev && prev.provider === modelData.provider) {
                                        return palette.highlight;
                                    }
                                    return Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.22);
                                }
                                opacity: 0.6
                                Layout.topMargin: 4
                                Layout.bottomMargin: 4
                            }

                            // Card Container
                            Rectangle {
                                Layout.fillWidth: true
                                radius: 6
                                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.04)
                                border.color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.12)
                                border.width: 1
                                implicitHeight: cardCol.implicitHeight + 12

                                ColumnLayout {
                                    id: cardCol
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    spacing: 5

                                    // Provider Header Row
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 4

                                        Image {
                                            id: provIcon
                                            source: Usage.providerIcon(modelData.provider)
                                            sourceSize: Qt.size(16, 16)
                                            Layout.preferredWidth: 16
                                            Layout.preferredHeight: 16
                                            fillMode: Image.PreserveAspectFit
                                            visible: status === Image.Ready
                                        }

                                        Rectangle {
                                            Layout.preferredWidth: 16
                                            Layout.preferredHeight: 16
                                            radius: 3
                                            color: window.rootAccent
                                            visible: !provIcon.visible
                                            Label {
                                                anchors.centerIn: parent
                                                text: Usage.providerName(modelData.provider).charAt(0).toUpperCase()
                                                font.bold: true
                                                font.pixelSize: 9
                                                color: "#ffffff"
                                            }
                                        }

                                        Label {
                                            text: Usage.providerName(modelData.provider)
                                            font.bold: true
                                            font.pixelSize: 12
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }

                                        Label {
                                            text: modelData.plan || ""
                                            font.pixelSize: 10
                                            opacity: 0.65
                                            visible: text !== ""
                                            elide: Text.ElideRight
                                        }
                                    }

                                    // Account Row (with badge when multi-account)
                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: (modelData.accountLabel || "") !== ""
                                        spacing: 4

                                        Rectangle {
                                            visible: desktop && desktop.providerAccountCount(modelData.provider) > 1
                                            color: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.15)
                                            radius: 3
                                            border.color: palette.highlight
                                            border.width: 1
                                            Layout.preferredHeight: 18
                                            implicitWidth: acctBadge.implicitWidth + 8
                                            Label {
                                                id: acctBadge
                                                anchors.centerIn: parent
                                                text: "Acc " + modelData.accountNumber
                                                font.pixelSize: 9
                                                font.bold: true
                                                color: palette.highlight
                                            }
                                        }

                                        Label {
                                            text: modelData.accountLabel || ""
                                            font.pixelSize: 11
                                            color: palette.highlight
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                        }

                                        Button {
                                            property bool isRefreshing: desktop && desktop.isAccountRefreshing(modelData.provider, 1)
                                            text: isRefreshing ? "…" : "↻"
                                            visible: modelData.accountNumber === 1 && desktop && desktop.providerAccountCount(modelData.provider) > 1
                                            font.pixelSize: 10
                                            Layout.preferredWidth: 20
                                            Layout.preferredHeight: 20
                                            padding: 0
                                            enabled: desktop && !desktop.busy && !isRefreshing
                                            onClicked: desktop.refreshAccount(modelData.provider, 1)
                                            ToolTip.visible: hovered
                                            ToolTip.text: "Refresh top account"
                                        }
                                    }

                                    // Quota Windows List
                                    Repeater {
                                        model: {
                                            if (modelData.provider !== "antigravity") return modelData.windows || [];
                                            var list = (modelData.windows || []).slice();
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
                                            spacing: 3

                                            // Factory Standard section header
                                            Label {
                                                visible: entryCardDelegate.modelData.provider === "factory" && index === 0 && (entryCardDelegate.modelData.windows || []).some(function(w) { return (w.label || "").toLowerCase().indexOf("core") !== -1; })
                                                text: "Standard"
                                                font.pixelSize: 9
                                                font.bold: true
                                                opacity: 0.6
                                                color: palette.text
                                            }

                                            // Factory Core section divider
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
                                                visible: {
                                                    if (!entryCardDelegate.modelData || entryCardDelegate.modelData.provider !== "factory") return false;
                                                    var isCore = (modelData.label || "").toLowerCase().indexOf("core") !== -1;
                                                    if (!isCore) return false;
                                                    var windows = entryCardDelegate.modelData.windows || [];
                                                    return (index === 0 || (windows[index - 1] && (windows[index - 1].label || "").toLowerCase().indexOf("core") === -1));
                                                }
                                                Layout.topMargin: 4
                                                Layout.bottomMargin: 2

                                                Rectangle {
                                                    Layout.fillWidth: true
                                                    height: 1
                                                    color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.18)
                                                }

                                                Label {
                                                    text: "Core"
                                                    font.pixelSize: 9
                                                    font.bold: true
                                                    opacity: 0.6
                                                    color: palette.text
                                                }
                                            }

                                            // Metric row
                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 3

                                                Button {
                                                    id: sideStarBtn
                                                    property bool isStarred: desktop && desktop.isStarredModel(entryCardDelegate.modelData.provider, modelData.label, modelData.key)
                                                    text: isStarred ? "★" : "☆"
                                                    Layout.preferredWidth: 16
                                                    Layout.preferredHeight: 16
                                                    padding: 0
                                                    contentItem: Text {
                                                        text: sideStarBtn.text
                                                        font.pixelSize: 10
                                                        color: sideStarBtn.isStarred ? "#f59e0b" : Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.35)
                                                        horizontalAlignment: Text.AlignHCenter
                                                        verticalAlignment: Text.AlignVCenter
                                                    }
                                                    background: Rectangle { color: "transparent" }
                                                    onClicked: {
                                                        if (desktop) desktop.setStarredModel(entryCardDelegate.modelData.provider, modelData.label, modelData.key);
                                                    }
                                                    ToolTip.visible: hovered
                                                    ToolTip.text: isStarred ? "Starred model (on status bar)" : "Star this model"
                                                }

                                                Label {
                                                    text: modelData.label
                                                    font.pixelSize: 11
                                                    font.bold: sideStarBtn.isStarred
                                                    Layout.fillWidth: true
                                                    elide: Text.ElideRight
                                                }

                                                Label {
                                                    text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + (desktop.settings.quotaDisplay === "used" ? "used" : "left")
                                                    font.bold: true
                                                    font.pixelSize: 10
                                                    color: sideStarBtn.isStarred ? "#f59e0b" : palette.text
                                                }
                                            }

                                            // Progress bar
                                            ProgressBar {
                                                Layout.fillWidth: true
                                                implicitHeight: 6
                                                from: 0
                                                to: 100
                                                value: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay)
                                                palette.highlight: Usage.progressBarColor(modelData.remaining, window.rootAccent, desktop.settings.warningColors)
                                            }

                                            // Reset text
                                            Label {
                                                text: Usage.resetText(modelData.resetsAt, clock.now, desktop.settings.resetDisplay)
                                                opacity: 0.6
                                                font.pixelSize: 9
                                                Layout.fillWidth: true
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // --- Footer ---
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.12)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4

                Label {
                    text: desktop && desktop.updated ? "Updated " + desktop.updated : ""
                    font.pixelSize: 9
                    opacity: 0.6
                    Layout.fillWidth: true
                }

                Button {
                    text: desktop && desktop.busy ? "Refreshing…" : "↻ Refresh"
                    font.pixelSize: 10
                    Layout.preferredHeight: 22
                    enabled: desktop && !desktop.busy
                    onClicked: { if (desktop) { desktop.refresh(); desktop.refreshCosts(); } }
                }

                Button {
                    text: "Dashboard…"
                    font.pixelSize: 10
                    Layout.preferredHeight: 22
                    onClicked: { if (desktop) desktop.showWindow("usage"); }
                }
            }
        }
    }
}
