// Two-pane playlist editor. Left: playlist list (with Filtered Library
// pinned at top). Right: editor for the selected playlist. Drag-and-drop
// reorder is added in a follow-up task; up/down arrows ship now for
// keyboard accessibility.
import QtQuick
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5

import org.kde.kirigami 2.6 as Kirigami
import com.github.captsilver.wallpaperEngineKde

import ".."
import "../components"

Item {
    id: root

    // Inputs
    property var manager: null         // PlaylistManager
    property var wpListModel: null
    property var videoListModel: null
    property string cfg_ActivePlaylistId: ""

    // Test surface
    readonly property alias playlistsView: lvPlaylists
    readonly property alias itemsView: lvItems

    property string _selectedId: ""

    function _resolveItemTitle(workshopId) {
        if (root.wpListModel && root.wpListModel.model) {
            const m = root.wpListModel.model;
            for (let i = 0; i < m.count; ++i)
                if (m.get(i).workshopid === workshopId) return m.get(i).title || workshopId;
        }
        if (root.videoListModel && root.videoListModel.model) {
            const m = root.videoListModel.model;
            for (let i = 0; i < m.count; ++i)
                if (m.get(i).workshopid === workshopId) return m.get(i).title || workshopId;
        }
        return workshopId;
    }

    RowLayout {
        anchors.fill: parent
        spacing: Kirigami.Units ? Kirigami.Units.smallSpacing : 4

        // ── LEFT PANE ────────────────────────────────────────────────────────
        ColumnLayout {
            Layout.preferredWidth: 240
            Layout.fillHeight: true

            RowLayout {
                Layout.fillWidth: true
                Button {
                    text: "+"
                    onClicked: namePromptCreate.open()
                }
                Button {
                    text: "Rename"
                    enabled: root._selectedId !== "" && root._selectedId !== "__filtered_library__"
                    onClicked: namePromptRename.open()
                }
                Button {
                    text: "Delete"
                    enabled: root._selectedId !== "" && root._selectedId !== "__filtered_library__"
                    onClicked: {
                        if (root.manager) root.manager.deletePlaylist(root._selectedId);
                        root._selectedId = "";
                    }
                }
            }

            ListView {
                id: lvPlaylists
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                model: root.manager ? root.manager.playlistsModel : null
                header: Rectangle {
                    width: lvPlaylists.width
                    height: 32
                    color: root._selectedId === "__filtered_library__"
                           ? Kirigami.Theme.highlightColor
                           : "transparent"
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: "Filtered Library"
                        font.italic: true
                        verticalAlignment: Text.AlignVCenter
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root._selectedId = "__filtered_library__"
                    }
                }
                delegate: Rectangle {
                    width: lvPlaylists.width
                    height: 32
                    color: root._selectedId === id
                           ? Kirigami.Theme.highlightColor : "transparent"
                    Label {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        text: name + "  (" + itemCount + ")"
                        verticalAlignment: Text.AlignVCenter
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root._selectedId = id
                    }
                }
            }
        }

        // ── RIGHT PANE ───────────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Kirigami.Units ? Kirigami.Units.smallSpacing : 4

            // Empty state
            Label {
                visible: root._selectedId === ""
                text: "Select a playlist on the left, or create a new one."
                Layout.alignment: Qt.AlignCenter
            }

            // Filtered Library read-only explanation
            ColumnLayout {
                visible: root._selectedId === "__filtered_library__"
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "Filtered Library"
                    font.bold: true
                    font.pixelSize: 18
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: "Cycles through wallpapers passing the filter chips on the Wallpapers tab. "
                        + "Mode is shuffle. Interval is set by 'Randomize Timer' on the Settings tab."
                }
                Button {
                    text: root.cfg_ActivePlaylistId === "__filtered_library__"
                          ? "Deactivate" : "Activate"
                    onClicked: {
                        if (!root.manager) return;
                        if (root.cfg_ActivePlaylistId === "__filtered_library__")
                            root.manager.deactivate();
                        else root.manager.activate("__filtered_library__");
                    }
                }
            }

            // User-playlist editor
            ColumnLayout {
                id: editor
                visible: root._selectedId !== "" && root._selectedId !== "__filtered_library__"
                Layout.fillWidth: true
                Layout.fillHeight: true

                // Look up the selected playlist's properties from the
                // PlaylistsModel via QAbstractItemModel.data(index, role).
                // Role values match wekde::PlaylistsModel::Roles.
                property var _selectedPlaylist: {
                    if (!root.manager || root._selectedId === "") return null;
                    const list = root.manager.playlistsModel;
                    if (!list) return null;
                    for (let i = 0; i < list.rowCount(); ++i) {
                        const idx = list.index(i, 0);
                        if (list.data(idx, 257 /* IdRole */) === root._selectedId)
                            return {
                                id:           list.data(idx, 257),
                                name:         list.data(idx, 258),
                                mode:         list.data(idx, 259),
                                intervalMin:  list.data(idx, 260),
                                itemCount:    list.data(idx, 261),
                            };
                    }
                    return null;
                }

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "Mode:" }
                    ComboBox {
                        model: ["sequential", "shuffle"]
                        currentIndex: editor._selectedPlaylist
                                    && editor._selectedPlaylist.mode === "shuffle" ? 1 : 0
                        onActivated: function(idx) {
                            // 0 = Sequential, 1 = Shuffle
                            if (root.manager) root.manager.setMode(root._selectedId, idx);
                        }
                    }
                    Label { text: "Interval (min):" }
                    SpinBox {
                        from: 1; to: 1440
                        value: editor._selectedPlaylist
                             ? editor._selectedPlaylist.intervalMin : 15
                        onValueModified: {
                            if (root.manager) root.manager.setIntervalMin(root._selectedId, value);
                        }
                    }
                }

                ListView {
                    id: lvItems
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: root.manager
                         ? root.manager.itemsModel(root._selectedId)
                         : null
                    delegate: Rectangle {
                        id: itemDelegate
                        width: lvItems.width
                        height: 36
                        property bool dragActive: false
                        property int  itemIndex: index
                        opacity: dragActive ? 0.7 : 1.0
                        color: dragActive
                            ? Kirigami.Theme.activeBackgroundColor
                            : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                         : "transparent")

                        Drag.active: itemDelegate.dragActive
                        Drag.hotSpot.x: width / 2
                        Drag.hotSpot.y: height / 2
                        Drag.source: itemDelegate
                        Drag.keys: ["wek-playlist-item"]

                        DropArea {
                            anchors.fill: parent
                            keys: ["wek-playlist-item"]
                            onDropped: function(drop) {
                                const fromIdx = drop.source.itemIndex;
                                const toIdx   = itemDelegate.itemIndex;
                                if (fromIdx !== toIdx && root.manager)
                                    root.manager.moveItem(root._selectedId, fromIdx, toIdx);
                            }
                        }

                        Item {
                            id: dragHandle
                            anchors.left: parent.left
                            width: 16
                            height: parent.height
                            Label {
                                anchors.centerIn: parent
                                text: "⋮⋮"
                                color: Kirigami.Theme.disabledTextColor
                            }
                            MouseArea {
                                anchors.fill: parent
                                drag.target: itemDelegate
                                drag.axis: Drag.YAxis
                                onPressed: itemDelegate.dragActive = true
                                onReleased: {
                                    itemDelegate.dragActive = false;
                                    itemDelegate.Drag.drop();
                                }
                            }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 20  // leave room for the drag handle
                            anchors.margins: 4
                            Label {
                                Layout.fillWidth: true
                                text: root._resolveItemTitle(workshopId)
                                elide: Text.ElideRight
                            }
                            SpinBox {
                                from: 0; to: 1440
                                value: durationOverrideMin || 0
                                onValueModified: {
                                    if (root.manager)
                                        root.manager.setItemDuration(root._selectedId, index, value);
                                }
                            }
                            Button {
                                text: "↑"
                                enabled: index > 0
                                onClicked: {
                                    if (root.manager)
                                        root.manager.moveItem(root._selectedId, index, index - 1);
                                }
                            }
                            Button {
                                text: "↓"
                                enabled: lvItems.count > 0 && index < lvItems.count - 1
                                onClicked: {
                                    if (root.manager)
                                        root.manager.moveItem(root._selectedId, index, index + 1);
                                }
                            }
                            Button {
                                text: "×"
                                onClicked: {
                                    if (root.manager)
                                        root.manager.removeItem(root._selectedId, index);
                                }
                            }
                        }
                    }
                }

                Label {
                    visible: lvItems.count === 0
                    Layout.alignment: Qt.AlignHCenter
                    text: "No items. Right-click wallpapers in the Wallpapers/Videos tabs to add."
                }

                Button {
                    Layout.alignment: Qt.AlignHCenter
                    text: root.cfg_ActivePlaylistId === root._selectedId ? "Deactivate" : "Activate"
                    enabled: lvItems.count > 0 || root.cfg_ActivePlaylistId === root._selectedId
                    onClicked: {
                        if (!root.manager) return;
                        if (root.cfg_ActivePlaylistId === root._selectedId)
                            root.manager.deactivate();
                        else root.manager.activate(root._selectedId);
                    }
                }
            }
        }
    }

    // ── Dialogs ──────────────────────────────────────────────────────────────
    Dialog {
        id: namePromptCreate
        objectName: "namePromptCreate"
        title: "New playlist"
        modal: true
        anchors.centerIn: parent
        contentItem: TextField {
            id: createNameField
            placeholderText: "Playlist name"
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: {
            if (root.manager && createNameField.text.trim() !== "") {
                root._selectedId = root.manager.createPlaylist(createNameField.text.trim());
            }
            createNameField.text = "";
        }
    }
    Dialog {
        id: namePromptRename
        objectName: "namePromptRename"
        title: "Rename playlist"
        modal: true
        anchors.centerIn: parent
        contentItem: TextField {
            id: renameNameField
            placeholderText: "New name"
        }
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: {
            if (root.manager && renameNameField.text.trim() !== "")
                root.manager.renamePlaylist(root._selectedId, renameNameField.text.trim());
            renameNameField.text = "";
        }
    }
}
