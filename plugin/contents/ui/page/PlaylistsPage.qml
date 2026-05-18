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
        // Use wpListModel's unfiltered source via titleOf() — the public
        // `model` ListModel only holds items passing the active filter
        // chips on the Wallpapers tab, so a playlist item the user filtered
        // out would otherwise show as a raw workshopid here.
        if (root.wpListModel && typeof root.wpListModel.titleOf === "function") {
            const t = root.wpListModel.titleOf(workshopId);
            if (t && t !== workshopId) return t;
        } else if (root.wpListModel && root.wpListModel.model) {
            // Fallback for fakes/tests that don't implement titleOf.
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

                // Column headers — kept in sync with the delegate's column
                // widths so labels line up.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Label {
                        Layout.preferredWidth: 28
                        text: ""
                    }
                    Label {
                        Layout.fillWidth: true
                        text: "Wallpaper"
                        font.bold: true
                        color: Kirigami.Theme.disabledTextColor
                    }
                    // Spacer matching the 3 action buttons (36×3 + spacing)
                    Item { Layout.preferredWidth: 36 * 3 + 8 }
                }

                ListView {
                    id: lvItems
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2

                    // Smooth animation when items reorder.
                    moveDisplaced: Transition { NumberAnimation { properties: "y"; duration: 150 } }
                    move:          Transition { NumberAnimation { properties: "y"; duration: 150 } }

                    model: root.manager
                         ? root.manager.itemsModel(root._selectedId)
                         : null

                    // Standard QML reorder pattern (Qt docs example):
                    // — outer MouseArea is the drag handle (covers the row's
                    //   leftmost gutter); inner Rectangle is the drag payload
                    //   centered via anchors so width/height stay stable when
                    //   ParentChange re-anchors during drag.
                    // — onPressAndHold engages the drag (not onPressed), so
                    //   click-to-press a child Button still works.
                    // — DropArea is on the MouseArea (delegate root), with
                    //   margins so a release inside the dragged item's own
                    //   bounds doesn't fire as a drop on itself.
                    // Outer Item is positioned by ListView. Only the small
                    // drag handle (left gutter) engages drag — the rest of
                    // the row passes through to child Buttons/SpinBox so
                    // clicks on those work normally. ListView scrolling
                    // remains the default gesture when the user drags
                    // outside the handle.
                    delegate: Item {
                        id: itemDelegate
                        width: lvItems.width
                        height: 48
                        property int itemIndex: index

                        Rectangle {
                            id: content
                            width: itemDelegate.width
                            height: itemDelegate.height
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 3
                            color: dragArea.drag.active
                                ? Kirigami.Theme.activeBackgroundColor
                                : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                             : "transparent")
                            opacity: dragArea.drag.active ? 0.85 : 1.0
                            border.width: dragArea.drag.active ? 1 : 0
                            border.color: Kirigami.Theme.highlightColor

                            Drag.active: dragArea.drag.active
                            Drag.source: itemDelegate
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2
                            Drag.keys: ["wek-playlist-item"]

                            states: State {
                                when: dragArea.drag.active
                                ParentChange { target: content; parent: lvItems }
                                AnchorChanges {
                                    target: content
                                    anchors.horizontalCenter: undefined
                                    anchors.verticalCenter: undefined
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 4
                                spacing: 4

                                // Drag area covers the full name column —
                                // ⋮⋮ glyph + title. Press-drag anywhere on
                                // the name engages reorder. Action buttons
                                // stay outside so their clicks work.
                                MouseArea {
                                    id: dragArea
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    cursorShape: dragArea.drag.active
                                        ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                    drag.target: content
                                    drag.axis: Drag.YAxis
                                    drag.minimumY: -10000
                                    drag.maximumY: 10000
                                    onReleased: content.Drag.drop()

                                    RowLayout {
                                        anchors.fill: parent
                                        spacing: 4
                                        Label {
                                            Layout.preferredWidth: 24
                                            text: "⋮⋮"
                                            color: Kirigami.Theme.disabledTextColor
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            text: root._resolveItemTitle(workshopId)
                                            elide: Text.ElideRight
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                    }
                                }

                                Button {
                                    Layout.preferredHeight: 36
                                    Layout.preferredWidth: 36
                                    text: "↑"
                                    enabled: index > 0
                                    onClicked: {
                                        if (root.manager)
                                            root.manager.moveItem(root._selectedId, index, index - 1);
                                    }
                                }
                                Button {
                                    Layout.preferredHeight: 36
                                    Layout.preferredWidth: 36
                                    text: "↓"
                                    enabled: lvItems.count > 0 && index < lvItems.count - 1
                                    onClicked: {
                                        if (root.manager)
                                            root.manager.moveItem(root._selectedId, index, index + 1);
                                    }
                                }
                                Button {
                                    Layout.preferredHeight: 36
                                    Layout.preferredWidth: 36
                                    text: "×"
                                    onClicked: {
                                        if (root.manager)
                                            root.manager.removeItem(root._selectedId, index);
                                    }
                                }
                            }
                        }

                        // Reorder fires on `onDropped` (release), not on
                        // `onEntered` (hover) — hover-based reorder fires
                        // moveItem repeatedly as the dragged hotspot crosses
                        // each delegate, making the drag feel like an
                        // instant-snap with no real drag distance.
                        DropArea {
                            anchors { fill: parent; margins: 4 }
                            keys: ["wek-playlist-item"]
                            onDropped: function(drop) {
                                const fromIdx = drop.source.itemIndex;
                                const toIdx   = itemDelegate.itemIndex;
                                if (fromIdx !== toIdx && root.manager)
                                    root.manager.moveItem(root._selectedId, fromIdx, toIdx);
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
