// Plain-video wallpaper picker. Mirrors WallpaperPage's role for the WE
// tab, but consumes a VideoListModel and emits commitWallpaper rather than
// writing wallpaper config directly (config.qml owns the cfg_* aliases).
import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5
import QtQuick.Dialogs

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.6 as Kirigami

import ".."
import "../components"

Item {
    id: root

    // ── Inputs ───────────────────────────────────────────────────────────────
    property string cfg_VideoFolderPath: ""
    property string activeWorkshopId: ""
    property string cachePath: ""
    property var pyext: null
    property var playlistManager: null

    // ── Outputs ──────────────────────────────────────────────────────────────
    signal commitWallpaper(var item)
    signal folderPathChosen(string path)

    AddToPlaylistMenu {
        id: addToPlaylistMenu
        manager: root.playlistManager
    }

    // ── Test surface (read-only) ─────────────────────────────────────────────
    readonly property bool emptyStateVisible: !cfg_VideoFolderPath
    readonly property bool gridVisible: Boolean(cfg_VideoFolderPath)
    readonly property alias videoListModel: vlm

    // Triggered by the WallpaperGrid delegate; also callable from tests.
    function _commitItem(item) {
        if (item) root.commitWallpaper(item);
    }

    VideoListModel {
        id: vlm
        folderPath: root.cfg_VideoFolderPath
        cachePath: root.cachePath
        pyext: root.pyext
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units ? Kirigami.Units.smallSpacing : 4

        // Header
        RowLayout {
            Layout.fillWidth: true
            visible: root.gridVisible
            Label {
                text: root.cfg_VideoFolderPath
                Layout.fillWidth: true
                elide: Text.ElideMiddle
                // Tooltip with the full path — elide hides long paths
                // entirely otherwise.
                ToolTip.text: root.cfg_VideoFolderPath
                ToolTip.visible: ma.containsMouse && ma.parent.width < ma.parent.implicitWidth
                ToolTip.delay: 500
                MouseArea {
                    id: ma
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }
            }
            Label {
                text: vlm.model.count > 0
                    ? i18ncp("@info video count badge, %1=count", "(%1 video)", "(%1 videos)", vlm.model.count)
                    : ""
                color: Kirigami.Theme.disabledTextColor
                visible: ! vlm.scanning && text !== ""
            }
            BusyIndicator {
                running: vlm.scanning
                visible: running
                implicitWidth: 20
                implicitHeight: 20
            }
            Button {
                text: i18nc("@action:button change video folder", "Change folder…")
                onClicked: folderDialog.open()
            }
            Button {
                text: i18nc("@action:button rescan video folder", "Rescan")
                enabled: ! vlm.scanning
                onClicked: vlm.refresh()
            }
        }

        // Empty state
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.emptyStateVisible
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 12
                Label {
                    text: i18nc("@info video page empty state", "No video folder selected")
                    Layout.alignment: Qt.AlignHCenter
                    font.pixelSize: 20
                }
                Button {
                    text: i18nc("@action:button choose video folder", "Choose folder…")
                    Layout.alignment: Qt.AlignHCenter
                    onClicked: folderDialog.open()
                }
            }
        }

        // Grid
        WallpaperGrid {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.gridVisible

            activeWorkshopId: root.activeWorkshopId
            iconSize: 48
            animatedPreviewActive: false
            showFavorites: false
            showWorkshopLink: false
            customConf: null
            autoCommitOnIndexResolve: false
            accessibleName: "Plain videos"

            onItemClicked: (item, idx) => root._commitItem(item)
            onItemRightClicked: (item, idx, x, y) => {
                if (!root.playlistManager) return;
                addToPlaylistMenu.item = item;
                addToPlaylistMenu.popup();
            }

            Component.onCompleted: {
                vlm.model.countChanged.connect(function() {
                    grid.view.model = vlm.model;
                });
                grid.view.model = vlm.model;
            }
        }
    }

    FolderDialog {
        id: folderDialog
        title: "Select video folder"
        onAccepted: {
            const path = selectedFolder.toString().replace(/^file:\/\//, "");
            root.cfg_VideoFolderPath = path;
            root.folderPathChosen(path);
        }
    }
}
