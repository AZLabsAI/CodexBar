import QtQuick

QtObject {
    id: root
    property Dashboard dashboard: Dashboard {}
    property SettingsWindow preferences: SettingsWindow {}
    property MiniWindow miniWindow: MiniWindow {}
    property SideDockWindow sideDock: SideDockWindow {}
    property Connections routing: Connections {
        target: desktop
        function onWindowRequested(page) {
            if (page === "settings") {
                root.preferences.show();
                root.preferences.raise();
                root.preferences.requestActivate();
            } else if (page === "mini") {
                root.miniWindow.positionNearCursor();
            } else if (page === "sidebar" || page === "dock") {
                root.sideDock.toggleOrShow();
            } else {
                root.dashboard.selectedTab = page === "spending" ? 1 : 0;
                root.dashboard.show();
                root.dashboard.raise();
                root.dashboard.requestActivate();
            }
        }
    }
}
