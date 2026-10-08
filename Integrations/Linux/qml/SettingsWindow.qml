import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    title: "Settings"
    width: 720; height: 740
    minimumWidth: 540; minimumHeight: 520
    property string feedback: ""
    property int section: 0
    property var providerOrder: []
    property string currentAccent: "violet"

    function moveProvider(index, offset) {
        var order = providerOrder.slice();
        var item = order.splice(index, 1)[0]; order.splice(index + offset, 0, item);
        providerOrder = order;
    }
    onClosing: function(event) { event.accepted = false; hide(); }
    onVisibleChanged: if (visible) load()

    function load() {
        var s = desktop.settings;
        provider.editText = s.provider; source.currentIndex = source.model.indexOf(s.source);
        account.value = s.accountIndex; allAccounts.checked = s.allAccounts;
        identity.checked = s.showIdentity; costs.checked = s.showCosts; status.checked = s.showStatus;
        notices.checked = s.notifications; threshold.value = s.notifyThreshold; interval.value = s.refreshSeconds;
        alarmEnabled.checked = s.alarmEnabled !== undefined ? s.alarmEnabled : true;
        alarmSound.checked = s.alarmSound !== undefined ? s.alarmSound : true;
        providerOrder = s.providerOrder.slice();
        quota.currentIndex = quota.model.indexOf(s.quotaDisplay);
        reset.currentIndex = reset.model.indexOf(s.resetDisplay);
        trayStyle.currentIndex = trayStyle.model.indexOf(s.trayStyle);
        theme.checked = s.followOmarchyTheme; pace.checked = s.showPace; warnings.checked = s.warningColors;
        refreshOnOpen.checked = s.refreshOnOpen;
        tray.checked = s.showTray; executable.text = s.executable;

        // Appearance settings
        var tMode = s.themeMode || "dark";
        for (var i = 0; i < themeModeCombo.model.length; ++i) {
            if (themeModeCombo.model[i].value === tMode) {
                themeModeCombo.currentIndex = i;
                break;
            }
        }
        currentAccent = s.accentColor || "violet";
        customAccentInput.text = currentAccent.startsWith("#") ? currentAccent : "";
        windowOpacitySlider.value = s.windowOpacity !== undefined ? Number(s.windowOpacity) : 0.95;
        miniOpacitySlider.value = s.miniOpacity !== undefined ? Number(s.miniOpacity) : 0.90;
        dockOpacitySlider.value = s.sidebarOpacity !== undefined ? Number(s.sidebarOpacity) : 0.85;
        dockHoverBrighten.checked = s.sidebarHoverBrighten !== undefined ? s.sidebarHoverBrighten : true;

        feedback = "";
    }

    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    header: ToolBar {
        Label { anchors.left: parent.left; anchors.leftMargin: 24; anchors.verticalCenter: parent.verticalCenter; text: "Settings"; font.pixelSize: 22; font.bold: true }
        implicitHeight: 64
    }

    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            currentIndex: window.section
            TabButton { text: "General"; onClicked: window.section = 0 }
            TabButton { text: "Appearance"; onClicked: window.section = 1 }
            TabButton { text: "Providers"; onClicked: window.section = 2 }
            TabButton { text: "Advanced"; onClicked: window.section = 3 }
        }

        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth; clip: true

            ColumnLayout {
                width: scroll.availableWidth; spacing: 20

                // ==========================================
                // SECTION 0: GENERAL
                // ==========================================
                GroupBox {
                    title: "Updates"; Layout.fillWidth: true; visible: window.section === 0
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Refresh every (seconds)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                            SpinBox { id: interval; from: 60; to: 3600; stepSize: 60; editable: true }
                        }
                        Option { id: refreshOnOpen; text: "Refresh when opening usage" }
                        Option { id: notices; text: "Notify about low quota, resets, and outages" }
                        RowLayout {
                            Layout.fillWidth: true; enabled: notices.checked
                            Label { text: "Remaining quota threshold (%)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                            SpinBox { id: threshold; from: 1; to: 99; editable: true }
                        }
                        Option { id: status; text: "Service status" }
                    }
                }

                GroupBox {
                    title: "Quota Reset Alarms"; Layout.fillWidth: true; visible: window.section === 0
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Option { id: alarmEnabled; text: "Automatically set alarm when quota runs out" }
                        Option { id: alarmSound; text: "Persistent sound notification until dismissed" }
                        Label {
                            text: "Plays an audible alarm continuously when a depleted quota returns until explicitly dismissed."
                            Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65; font.pixelSize: 11
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label {
                                text: (desktop && desktop.alarms && desktop.alarms.length > 0) ?
                                    ("Active alarms: " + desktop.alarms.length) : "No active alarms"
                                font.pixelSize: 11
                                opacity: 0.8
                                Layout.fillWidth: true
                            }
                            Button {
                                text: "🔔 Test Alarm Sound"
                                font.pixelSize: 11
                                onClicked: desktop.testAlarm()
                            }
                        }
                    }
                }

                GroupBox {
                    title: "Desktop"; Layout.fillWidth: true; visible: window.section === 0
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Button {
                            text: desktop.launchAtLogin ? "Disable start at login" : "Enable start at login"
                            onClicked: desktop.setLaunchAtLogin(!desktop.launchAtLogin)
                        }
                        Option { id: tray; text: "Tray icon" }
                        Label { text: "Optional with the Omarchy widget. CodexBar is also available in the application launcher."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Tray style"; Layout.fillWidth: true }
                            ComboBox { id: trayStyle; model: ["meters", "icon"] }
                        }
                        Option { id: costs; text: "Local spending" }
                    }
                }

                GroupBox {
                    title: "Display Preferences"; Layout.fillWidth: true; visible: window.section === 0
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Quota"; Layout.fillWidth: true }
                            ComboBox { id: quota; model: ["remaining", "used"] }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Reset time"; Layout.fillWidth: true }
                            ComboBox { id: reset; model: ["countdown", "absolute", "both"] }
                        }
                        Option { id: pace; text: "Show pace" }
                        Option { id: warnings; text: "Highlight low quota" }
                    }
                }

                // ==========================================
                // SECTION 1: APPEARANCE
                // ==========================================
                GroupBox {
                    title: "Theme Mode"
                    Layout.fillWidth: true
                    visible: window.section === 1

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        Label {
                            text: "Select your preferred color scheme:"
                            opacity: 0.7
                            font.pixelSize: 12
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            ComboBox {
                                id: themeModeCombo
                                Layout.fillWidth: true
                                model: [
                                    { text: "Dark Mode 🌙", value: "dark", desc: "Deep carbon palette (#121316) for low-light focus" },
                                    { text: "Light Mode ☀️", value: "light", desc: "Clean daylight palette (#f8fafc) with crisp contrast" },
                                    { text: "System Default 💻", value: "system", desc: "Automatically match system desktop luminance" }
                                ]
                                textRole: "text"
                                valueRole: "value"
                            }
                        }

                        Label {
                            text: themeModeCombo.model[themeModeCombo.currentIndex] ? themeModeCombo.model[themeModeCombo.currentIndex].desc : ""
                            opacity: 0.65
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }

                        Option {
                            id: theme
                            text: "Follow Omarchy desktop theme colors (when available)"
                        }
                    }
                }

                GroupBox {
                    title: "Accent Colors"
                    Layout.fillWidth: true
                    visible: window.section === 1

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 12

                        Label {
                            text: "Select a curated accent or specify a custom hex code:"
                            opacity: 0.7
                            font.pixelSize: 12
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Repeater {
                                model: [
                                    { name: "violet", hex: "#8b5cf6", title: "Violet" },
                                    { name: "blue", hex: "#3b82f6", title: "Blue" },
                                    { name: "cyan", hex: "#06b6d4", title: "Cyan" },
                                    { name: "emerald", hex: "#10b981", title: "Emerald" },
                                    { name: "orange", hex: "#f97316", title: "Orange" },
                                    { name: "rose", hex: "#f43f5e", title: "Rose" },
                                    { name: "amber", hex: "#f59e0b", title: "Amber" }
                                ]

                                Rectangle {
                                    id: swatch
                                    required property var modelData
                                    width: 34; height: 34
                                    radius: 17
                                    color: modelData.hex
                                    border.color: (window.currentAccent === modelData.name || window.currentAccent.toLowerCase() === modelData.hex.toLowerCase()) ? palette.text : Qt.rgba(palette.text.r, palette.text.g, palette.text.b, 0.25)
                                    border.width: (window.currentAccent === modelData.name || window.currentAccent.toLowerCase() === modelData.hex.toLowerCase()) ? 3 : 1

                                    Text {
                                        anchors.centerIn: parent
                                        text: "✓"
                                        font.pixelSize: 14
                                        font.bold: true
                                        color: "#ffffff"
                                        visible: (window.currentAccent === swatch.modelData.name || window.currentAccent.toLowerCase() === swatch.modelData.hex.toLowerCase())
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            window.currentAccent = swatch.modelData.name;
                                            customAccentInput.text = "";
                                        }
                                    }

                                    ToolTip.visible: swatchHover.hovered
                                    ToolTip.text: modelData.title + " (" + modelData.hex + ")"
                                    HoverHandler { id: swatchHover }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Label {
                                text: "Custom Hex:"
                                font.pixelSize: 12
                            }

                            TextField {
                                id: customAccentInput
                                Layout.preferredWidth: 140
                                placeholderText: "#8b5cf6"
                                selectByMouse: true
                                validator: RegularExpressionValidator { regularExpression: /^#?[0-9a-fA-F]{6}$/ }
                                onTextChanged: {
                                    var txt = text.trim();
                                    if (txt.length === 6 && !txt.startsWith("#")) txt = "#" + txt;
                                    if (txt.length === 7 && txt.startsWith("#")) {
                                        window.currentAccent = txt;
                                    }
                                }
                            }

                            Rectangle {
                                width: 28; height: 28; radius: 6
                                color: {
                                    var txt = customAccentInput.text.trim();
                                    if (txt.length === 6 && !txt.startsWith("#")) txt = "#" + txt;
                                    return (txt.startsWith("#") && txt.length === 7) ? txt : "transparent";
                                }
                                border.color: palette.mid
                                border.width: 1
                                visible: customAccentInput.text.trim() !== ""
                            }

                            Label {
                                text: "Type any valid 6-digit hex code"
                                opacity: 0.6
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                        }
                    }
                }

                GroupBox {
                    title: "Surfaces & Transparencies"
                    Layout.fillWidth: true
                    visible: window.section === 1

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 14

                        Label {
                            text: "Adjust surface opacity and window background translucency:"
                            opacity: 0.7
                            font.pixelSize: 12
                        }

                        // 1. Dashboard Window Opacity
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    text: "Main Dashboard Opacity: " + Math.round(windowOpacitySlider.value * 100) + "%"
                                    font.bold: true
                                    Layout.fillWidth: true
                                }
                                RowLayout {
                                    spacing: 4
                                    Button {
                                        text: "Solid (100%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: windowOpacitySlider.value = 1.00
                                    }
                                    Button {
                                        text: "Glass (95%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: windowOpacitySlider.value = 0.95
                                    }
                                    Button {
                                        text: "Acrylic (85%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: windowOpacitySlider.value = 0.85
                                    }
                                }
                            }

                            Slider {
                                id: windowOpacitySlider
                                Layout.fillWidth: true
                                from: 0.20; to: 1.00; stepSize: 0.05
                            }
                        }

                        // 2. Mini Window Opacity
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    text: "Mini Quota Bar Opacity: " + Math.round(miniOpacitySlider.value * 100) + "%"
                                    font.bold: true
                                    Layout.fillWidth: true
                                }
                                RowLayout {
                                    spacing: 4
                                    Button {
                                        text: "Solid (100%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: miniOpacitySlider.value = 1.00
                                    }
                                    Button {
                                        text: "Glass (90%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: miniOpacitySlider.value = 0.90
                                    }
                                    Button {
                                        text: "Acrylic (75%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: miniOpacitySlider.value = 0.75
                                    }
                                }
                            }

                            Slider {
                                id: miniOpacitySlider
                                Layout.fillWidth: true
                                from: 0.20; to: 1.00; stepSize: 0.05
                            }
                        }

                        // 3. Side Dock Bar Opacity
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    text: "Side Dock Bar Opacity: " + Math.round(dockOpacitySlider.value * 100) + "%"
                                    font.bold: true
                                    Layout.fillWidth: true
                                }
                                RowLayout {
                                    spacing: 4
                                    Button {
                                        text: "Solid (100%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: dockOpacitySlider.value = 1.00
                                    }
                                    Button {
                                        text: "Dock (85%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: dockOpacitySlider.value = 0.85
                                    }
                                    Button {
                                        text: "Subtle (65%)"
                                        font.pixelSize: 10
                                        Layout.preferredHeight: 24
                                        onClicked: dockOpacitySlider.value = 0.65
                                    }
                                }
                            }

                            Slider {
                                id: dockOpacitySlider
                                Layout.fillWidth: true
                                from: 0.20; to: 1.00; stepSize: 0.05
                            }
                        }

                        Option {
                            id: dockHoverBrighten
                            text: "Brighten side dock on mouse hover"
                        }
                    }
                }

                // ==========================================
                // SECTION 2: PROVIDERS
                // ==========================================
                GroupBox {
                    title: "Provider"; Layout.fillWidth: true; visible: window.section === 2
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Label { text: "Provider" }
                        ComboBox {
                            id: provider; Layout.fillWidth: true; editable: true
                            model: ["codex", "claude", "both", "enabled", "cursor", "gemini", "copilot", "antigravity", "custom", "all"]
                            validator: RegularExpressionValidator { regularExpression: /^[a-z0-9-]{1,80}$/ }
                        }
                        ColumnLayout {
                            visible: provider.editText === "custom"
                            Layout.fillWidth: true
                            RowLayout {
                                Layout.fillWidth: true
                                ComboBox { id: available; model: desktop.providers; textRole: "displayName"; Layout.fillWidth: true }
                                Button {
                                    text: "Add"
                                    enabled: available.currentIndex >= 0
                                    onClicked: {
                                        var id = desktop.providers[available.currentIndex].provider;
                                        if (window.providerOrder.indexOf(id) < 0) window.providerOrder = window.providerOrder.concat([id]);
                                    }
                                }
                            }
                            Repeater {
                                model: window.providerOrder
                                RowLayout {
                                    required property string modelData
                                    required property int index
                                    Layout.fillWidth: true
                                    Label { text: Usage.providerName(modelData); Layout.fillWidth: true; wrapMode: Text.Wrap }
                                    Button { text: "↑"; Accessible.name: "Move " + modelData + " up"; enabled: index > 0; onClicked: window.moveProvider(index, -1) }
                                    Button { text: "↓"; Accessible.name: "Move " + modelData + " down"; enabled: index < window.providerOrder.length - 1; onClicked: window.moveProvider(index, 1) }
                                    Button { text: "Remove"; onClicked: { var order = window.providerOrder.slice(); order.splice(index, 1); window.providerOrder = order; } }
                                }
                            }
                        }
                        Label { text: "Choose custom to select and order providers, or enabled to follow your CLI configuration."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Source"; Layout.fillWidth: true }
                            ComboBox { id: source; model: ["auto", "oauth", "cli", "api", "web"] }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: "Account (0 = default)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                            SpinBox { enabled: !allAccounts.checked && ["custom", "both", "all", "enabled"].indexOf(provider.editText) < 0; id: account; from: 0; to: 999; editable: true }
                        }
                        Option { id: allAccounts; text: "All accounts" }
                        Option { id: identity; text: "Show account identity" }
                        RowLayout {
                            Layout.fillWidth: true
                            ComboBox { id: loginProvider; model: ["codex", "claude"]; Layout.fillWidth: true }
                            Button { text: "Sign in…"; onClicked: { if (desktop.accountAction(loginProvider.currentText, "login")) window.feedback = "Finish signing in in the terminal, then refresh usage."; } }
                            Button { text: "Sign out…"; onClicked: signOut.open() }
                        }
                        Label { text: "Sign-in opens your provider CLI in a terminal. Account selection above only changes displayed usage."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                    }
                }

                // ==========================================
                // SECTION 3: ADVANCED
                // ==========================================
                GroupBox {
                    title: "CLI"; Layout.fillWidth: true; visible: window.section === 3
                    ColumnLayout {
                        anchors.fill: parent; spacing: 10
                        Label { text: "Executable" }
                        TextField { id: executable; Layout.fillWidth: true; selectByMouse: true; placeholderText: "codexbar" }
                    }
                }
            }
        }

        Label { text: desktop.configError || window.feedback; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap }

        RowLayout {
            Layout.fillWidth: true
            Label { text: "Closing windows keeps CodexBar running."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65; font.pixelSize: 12 }
            Button { text: "Cancel"; onClicked: window.hide() }
            Button {
                text: "Save"; highlighted: true
                onClicked: {
                    var resolvedAccent = window.currentAccent;
                    var customTxt = customAccentInput.text.trim();
                    if (customTxt.length === 6 && !customTxt.startsWith("#")) customTxt = "#" + customTxt;
                    if (customTxt.startsWith("#") && customTxt.length === 7) resolvedAccent = customTxt;

                    if (desktop.saveSettings({
                        provider: provider.editText.trim(),
                        source: source.currentText,
                        accountIndex: account.value,
                        allAccounts: allAccounts.checked,
                        showIdentity: identity.checked,
                        showCosts: costs.checked,
                        showStatus: status.checked,
                        notifications: notices.checked,
                        notifyThreshold: threshold.value,
                        refreshSeconds: interval.value,
                        providerOrder: window.providerOrder,
                        quotaDisplay: quota.currentText,
                        resetDisplay: reset.currentText,
                        followOmarchyTheme: theme.checked,
                        showPace: pace.checked,
                        warningColors: warnings.checked,
                        trayStyle: trayStyle.currentText,
                        refreshOnOpen: refreshOnOpen.checked,
                        showTray: tray.checked,
                        executable: executable.text.trim(),
                        themeMode: themeModeCombo.model[themeModeCombo.currentIndex].value,
                        accentColor: resolvedAccent,
                        windowOpacity: Math.round(windowOpacitySlider.value * 100) / 100,
                        miniOpacity: Math.round(miniOpacitySlider.value * 100) / 100,
                        sidebarOpacity: Math.round(dockOpacitySlider.value * 100) / 100,
                        sidebarHoverBrighten: dockHoverBrighten.checked,
                        alarmEnabled: alarmEnabled.checked,
                        alarmSound: alarmSound.checked
                    })) {
                        window.feedback = "Settings saved successfully";
                    }
                }
            }
        }
    }

    Dialog {
        id: signOut
        title: "Sign out of " + loginProvider.currentText + "?"
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Cancel | Dialog.Ok
        Label { text: "This signs out the provider CLI on this machine."; wrapMode: Text.Wrap; width: Math.min(window.width - 80, 350) }
        onAccepted: desktop.accountAction(loginProvider.currentText, "logout")
    }

    component Option: CheckBox {
        Layout.fillWidth: true
        contentItem: Text {
            text: parent.text
            font: parent.font
            color: parent.palette.windowText
            leftPadding: parent.indicator.width + parent.spacing
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.Wrap
        }
    }
}
