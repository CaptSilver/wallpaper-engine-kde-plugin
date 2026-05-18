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
    property int    cfg_CurrentItemIndex: 0   // used to highlight the playing row

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
                    objectName: "btnNewPlaylist"
                    text: "+"
                    ToolTip.text: "New playlist"
                    ToolTip.visible: hovered
                    ToolTip.delay: 500
                    onClicked: namePromptCreate.open()
                }
                Button {
                    objectName: "btnDeletePlaylist"
                    text: "Delete"
                    ToolTip.text: "Delete the selected playlist"
                    ToolTip.visible: hovered
                    ToolTip.delay: 500
                    enabled: root._selectedId !== "" && root._selectedId !== "__filtered_library__"
                    // Confirm before deleting — a single mis-click should not
                    // wipe a curated playlist. Tip: rename inline by
                    // double-clicking the row instead.
                    onClicked: deleteConfirmPrompt.open()
                }
            }

            ListView {
                id: lvPlaylists
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 2
                // Keyboard reachable: Tab into the list, arrow keys move
                // between rows, Space selects. ListView defaults to
                // activeFocusOnTab=false, so the list is mouse-only without
                // this — bad for accessibility.
                activeFocusOnTab: true
                keyNavigationEnabled: true
                keyNavigationWraps: false
                model: root.manager ? root.manager.playlistsModel : null

                // Filtered Library always on top — bold + ▶ when active.
                header: Rectangle {
                    width: lvPlaylists.width
                    height: 32
                    color: root._selectedId === "__filtered_library__"
                           ? Kirigami.Theme.highlightColor
                           : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        spacing: 4
                        Label {
                            text: root.cfg_ActivePlaylistId === "__filtered_library__"
                                  ? "▶" : ""
                            color: Kirigami.Theme.positiveTextColor
                            Layout.preferredWidth: 12
                        }
                        Label {
                            Layout.fillWidth: true
                            text: "Filtered Library"
                            font.italic: true
                            font.bold: root.cfg_ActivePlaylistId === "__filtered_library__"
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root._selectedId = "__filtered_library__"
                    }
                }

                delegate: Rectangle {
                    id: plRow
                    width: lvPlaylists.width
                    height: 32
                    color: root._selectedId === id
                           ? Kirigami.Theme.highlightColor : "transparent"

                    // Local edit state for inline rename. We don't bind the
                    // TextField into the model — we commit via the manager
                    // on Enter / focusOut and let the model reset back to
                    // the saved name on Escape.
                    property bool _editing: false

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 4
                        spacing: 4
                        Label {
                            text: root.cfg_ActivePlaylistId === id ? "▶" : ""
                            color: Kirigami.Theme.positiveTextColor
                            Layout.preferredWidth: 12
                        }
                        Label {
                            id: plNameLabel
                            visible: ! plRow._editing
                            Layout.fillWidth: true
                            text: name + "  (" + itemCount + ")"
                            font.bold: root.cfg_ActivePlaylistId === id
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter
                        }
                        TextField {
                            id: plNameEdit
                            objectName: "plNameEdit_" + id
                            visible: plRow._editing
                            Layout.fillWidth: true
                            text: name
                            selectByMouse: true
                            onAccepted: {
                                if (root.manager && text.trim() !== "")
                                    root.manager.renamePlaylist(id, text.trim());
                                plRow._editing = false;
                            }
                            Keys.onEscapePressed: {
                                text = name;
                                plRow._editing = false;
                            }
                            onActiveFocusChanged: {
                                // Commit on focus loss if user clicked away.
                                if (! activeFocus && plRow._editing) {
                                    if (root.manager && text.trim() !== "" && text.trim() !== name)
                                        root.manager.renamePlaylist(id, text.trim());
                                    plRow._editing = false;
                                }
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        // Only the single-click path selects; double-click
                        // engages inline rename. acceptedButtons + lastPressed
                        // gating prevents the single-click from racing
                        // ahead of the double.
                        onClicked: {
                            if (! plRow._editing) root._selectedId = id;
                        }
                        onDoubleClicked: {
                            plRow._editing = true;
                            plNameEdit.forceActiveFocus();
                            plNameEdit.selectAll();
                        }
                    }
                }
            }

            // Empty-state hint when the user has zero custom playlists. The
            // Filtered Library header is always visible in lvPlaylists.header
            // but doesn't count toward .count.
            Label {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 4
                visible: lvPlaylists.count === 0
                color: Kirigami.Theme.disabledTextColor
                font.italic: true
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                text: "No custom playlists — click + to add one"
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
                    // Same accessibility hook as lvPlaylists — keyboard
                    // users can Tab into the queue and arrow through items.
                    activeFocusOnTab: true
                    keyNavigationEnabled: true
                    keyNavigationWraps: false

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
                        // Highlight the currently-playing row when this
                        // playlist is the active one — gives the user a
                        // visible "you are here" marker in the queue.
                        readonly property bool isPlayingRow:
                            root.cfg_ActivePlaylistId === root._selectedId
                            && index === root.cfg_CurrentItemIndex

                        Rectangle {
                            id: content
                            width: itemDelegate.width
                            height: itemDelegate.height
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            radius: 3
                            color: dragArea.drag.active
                                ? Kirigami.Theme.activeBackgroundColor
                                : (itemDelegate.isPlayingRow
                                    ? Kirigami.Theme.positiveBackgroundColor
                                    : (index % 2 ? Kirigami.Theme.alternateBackgroundColor
                                                 : "transparent"))
                            opacity: dragArea.drag.active ? 0.85 : 1.0
                            border.width: (dragArea.drag.active || itemDelegate.isPlayingRow) ? 1 : 0
                            border.color: itemDelegate.isPlayingRow
                                ? Kirigami.Theme.positiveTextColor
                                : Kirigami.Theme.highlightColor

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
                                        Kirigami.Icon {
                                            Layout.preferredWidth: 18
                                            Layout.preferredHeight: 18
                                            Layout.alignment: Qt.AlignVCenter
                                            // Falls back to ⋮⋮ glyph below if
                                            // the icon theme doesn't ship this name.
                                            source: "transform-move-vertical"
                                            color: Kirigami.Theme.disabledTextColor
                                            // Tooltip on the drag area is on the
                                            // MouseArea above (cursor + grab).
                                            fallback: "view-list-icons"
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
                                    ToolTip.text: "Move up"
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
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
                                    ToolTip.text: "Move down"
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
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
                                    ToolTip.text: "Remove from playlist"
                                    ToolTip.visible: hovered
                                    ToolTip.delay: 500
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
    // Confirmation before destructive Delete. Names the playlist so it's
    // obvious which one is about to vanish. Activated playlist deactivates
    // on the C++ side; the controller's onActivePlaylistIdChanged then
    // clears cfg_ActivePlaylistId via the dialog setter.
    Dialog {
        id: deleteConfirmPrompt
        objectName: "deleteConfirmPrompt"
        title: "Delete playlist"
        modal: true
        anchors.centerIn: parent
        property string _selectedName: {
            if (!root.manager || root._selectedId === "") return "";
            const list = root.manager.playlistsModel;
            if (!list) return "";
            for (let i = 0; i < list.rowCount(); ++i) {
                const idx = list.index(i, 0);
                if (list.data(idx, 257) === root._selectedId)
                    return list.data(idx, 258);
            }
            return "";
        }
        contentItem: Label {
            text: "Delete the playlist \"" + deleteConfirmPrompt._selectedName + "\"?"
            wrapMode: Text.WordWrap
        }
        standardButtons: Dialog.Yes | Dialog.No
        onAccepted: {
            if (root.manager) root.manager.deletePlaylist(root._selectedId);
            root._selectedId = "";
        }
    }
}
