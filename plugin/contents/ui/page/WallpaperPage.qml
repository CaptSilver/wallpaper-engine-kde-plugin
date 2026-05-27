import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Controls 2.3 as QQC
import QtQuick.Window 2.0 // for Screen
import QtQuick.Dialogs
import QtQuick.Layouts 1.5

import ".."
import "../components"

import "../js/utils.mjs" as Utils
import "../js/bbcode.mjs" as BBCode

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
// for kcm gridview
import org.kde.kcmutils as KCM
import org.kde.kirigami 2.6 as Kirigami
import org.kde.kquickcontrolsaddons 2.0

RowLayout {
    id: wallpaperPageRoot
    Layout.fillWidth: true

    // Наследуем тему от родителя
    Kirigami.Theme.inherit: true

    // Set by config.qml — used by AddToPlaylistMenu and the active-playlist banner.
    property var playlistManager: null
    property string cfg_ActivePlaylistId: ""
    property int    cfg_CurrentItemIndex: 0

    // ── Lifted config-read state (was duplicated across right_opts +
    // user_props_group, each issuing its own pyext.read_wallpaper_config
    // per selection change). One read per selection, shared. read_active_
    // bindings stays in user_props_group (user-props-specific).
    readonly property string activeWorkshopid:
        (right_content && right_content.wpmodel) ? (right_content.wpmodel.workshopid || "") : ""
    property var activeConfig: ({})
    onActiveWorkshopidChanged: {
        if (activeWorkshopid) {
            pyext.read_wallpaper_config(activeWorkshopid).then(res => {
                activeConfig = res || {};
            });
        } else {
            activeConfig = {};
        }
    }
    Component.onCompleted: activeWorkshopidChanged()

    AddToPlaylistMenu {
        id: addToPlaylistMenu
        manager: wallpaperPageRoot.playlistManager
    }

    // Reset confirmation dialogs live at page root — they're Popups, not
    // QQuickItems, so they can't sit inside OptionGroup's `content` list.
    Dialog {
        id: resetSceneOptsConfirm
        objectName: "resetSceneOptsConfirm"
        title: "Reset scene options"
        modal: true
        implicitWidth: Kirigami.Units.gridUnit * 20
        anchors.centerIn: Overlay.overlay
        contentItem: Label {
            text: "Reset all per-wallpaper scene options to defaults? This cannot be undone."
            wrapMode: Text.WordWrap
        }
        standardButtons: Dialog.Yes | Dialog.No
        onOpened: {
            const noBtn = standardButton(Dialog.No);
            if (noBtn) noBtn.forceActiveFocus();
        }
        onAccepted: { if (right_opts) right_opts.reset_config(); }
    }
    Dialog {
        id: resetUserPropsConfirm
        objectName: "resetUserPropsConfirm"
        title: "Reset wallpaper properties"
        modal: true
        implicitWidth: Kirigami.Units.gridUnit * 20
        anchors.centerIn: Overlay.overlay
        contentItem: Label {
            text: "Reset this wallpaper's user properties to defaults? Any tuning you've done will be lost."
            wrapMode: Text.WordWrap
        }
        standardButtons: Dialog.Yes | Dialog.No
        onOpened: {
            const noBtn = standardButton(Dialog.No);
            if (noBtn) noBtn.forceActiveFocus();
        }
        onAccepted: { if (user_props_group) user_props_group.resetUserProps(); }
    }

    function saveConfig() {
        right_opts.save_changes();
    }
    
    Control {
        id: left_content
        Layout.fillWidth: true
        Layout.fillHeight: true
        topPadding: 8
        leftPadding: Kirigami.Units.largeSpacing
        rightPadding: 0
        bottomPadding: 0

        contentItem: ColumnLayout {
            id: wpselsect
            anchors.left: parent.left
            anchors.right: parent.right

            RowLayout {
                id: infoRow
                Layout.alignment: Qt.AlignHCenter
                spacing: 5

                Label {
                    visible: cfg_WallpaperWorkShopId
                    text: `Shopid: ${cfg_WallpaperWorkShopId}  Type: ${Common.unpackWallpaperSource(cfg_WallpaperSource).type}`
                    //${cfg_WallpaperType}
                }

                Kirigami.ActionToolBar {
                    Layout.fillWidth: true
                    alignment: Qt.AlignRight
                    flat: false

                    ActionGroup {
                        id: group_sort
                        exclusive: true
                    }
                    Component {
                        id: comp_action_sort
                        Kirigami.Action {
                            ActionGroup.group: group_sort

                            property int act_value;
                            checkable: true
                            checked: {
                                checked = cfg_SortMode == act_value;
                            }
                            onTriggered: cfg_SortMode = act_value

                            Component.onCompleted: comp_action_sort.Component.destruction.connect(this.destroy)
                        }
                    }

                    actions: [
                        Kirigami.Action {
                            icon.name: "folder-symbolic"
                            text: 'Library'
                            tooltip: cfg_SteamLibraryPath ? cfg_SteamLibraryPath : 'Select steam library dir'
                            onTriggered: wpDialog.open()
                        },
                        Kirigami.Action {
                            id: action_cb_filter
                            text: 'Filter'
                            icon.name: "view-filter"
                            readonly property var model: Common.filterModel
                            readonly property var modelValues: Common.filterModel.getValueArray(cfg_FilterStr)
                            // Open the Popup instead of populating a Menu via
                            // `children:`. A Menu auto-closes on each
                            // MenuItem activation, which made multi-toggle
                            // painful: the user had to reopen the menu for
                            // every chip. The Popup stays open until
                            // click-outside or Escape.
                            onTriggered: filterPopup.open()
                        },
                        Kirigami.Action {
                            id: action_cb_sort
                            text: model[currentIndex].short
                            icon.name: "view-sort-descending-symbolic"
                            property int currentIndex: Common.modelIndexOfValue(model, cfg_SortMode)
                            readonly property var model: [
                                {
                                    text: "Sort By Workshop Id",
                                    short: "Id",
                                    value: Common.SortMode.Id
                                },
                                {
                                    text: "Sort Alphabetically By Name",
                                    short: "Alphabetical",
                                    value: Common.SortMode.Name
                                },
                                {
                                    text: "Show Newest Modified First",
                                    short: "Modified",
                                    value: Common.SortMode.Modified
                                }
                            ]
                            children: model.map((el, index) => comp_action_sort.createObject(null, {text: el.text, act_value: el.value}))
                        },
                        Kirigami.Action {
                            // Show a spinning busy variant while a scan is
                            // in flight — parity with the VideoPage Rescan
                            // button. Mid-scan re-clicks are blocked to
                            // avoid overlapping refreshes.
                            icon.name: wpListModel.scanning
                                ? "view-refresh"
                                : "view-refresh-symbolic"
                            text: wpListModel.scanning ? 'Refreshing…' : 'Refresh'
                            enabled: ! wpListModel.scanning
                            onTriggered: wpListModel.refresh()
                        },
                        Kirigami.Action {
                            icon.name: "list-add-symbolic"
                            text: 'Save filter as playlist…'
                            // Enable when filtered list is non-empty AND narrows
                            // the full library (otherwise duplicates "select all").
                            enabled: wallpaperPageRoot.playlistManager
                                  && wpListModel.model.count > 0
                                  && wpListModel.model.count < wpListModel.countNoFilter
                            onTriggered: saveFilterPrompt.open()
                        }
                    ]
                }
            }

            // Filter Popup — replaces the toolbar dropdown menu. Toggling
            // a CheckBox doesn't close the Popup, so users can flip multiple
            // chips in one trip. Click-outside / Escape / explicit Close
            // dismisses. Section labels (TYPE, AGE, GENRE, PLAYLIST) come
            // from filterModel rows with type === "_nocheck".
            Popup {
                id: filterPopup
                objectName: "filterPopup"
                modal: false
                focus: true
                // Anchor near the top-right where the toolbar button is.
                // Width adapts so the popup never overflows a narrow side-
                // panel layout (Plasma allows the wallpaper config dialog
                // to be quite slim on some setups). x is clamped so the
                // popup stays inside the parent.
                readonly property int _maxW: 280
                readonly property int _minW: 200
                readonly property int _avail: left_content
                    ? Math.max(0, left_content.width - 32) : _maxW
                width: Math.max(_minW, Math.min(_maxW, _avail))
                x: left_content
                    ? Math.max(8, left_content.width - width - 16) : 0
                y: infoRow ? infoRow.height + 8 : 48
                height: Math.min(
                    (left_content ? left_content.height : 600) - 80,
                    520)
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent
                                | Popup.CloseOnPressOutside

                contentItem: ColumnLayout {
                    spacing: 4
                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: "Filters"
                            font.bold: true
                        }
                        ToolButton {
                            text: "Reset"
                            ToolTip.text: "Reset to default filters"
                            ToolTip.visible: hovered
                            ToolTip.delay: 500
                            onClicked: {
                                // "" → getValueArray falls back to defaults.
                                cfg_FilterStr = "";
                            }
                        }
                        ToolButton {
                            text: "Close"
                            onClicked: filterPopup.close()
                        }
                    }
                    ScrollView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        ColumnLayout {
                            width: filterPopup.width - 24
                            spacing: 2
                            Repeater {
                                model: Common.filterModel
                                delegate: Item {
                                    Layout.fillWidth: true
                                    implicitHeight: model.type === "_nocheck"
                                        ? sectionLabel.implicitHeight + 8
                                        : chipBox.implicitHeight
                                    Label {
                                        id: sectionLabel
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        anchors.topMargin: 6
                                        visible: model.type === "_nocheck"
                                        text: model.text
                                        font.bold: true
                                        color: Kirigami.Theme.disabledTextColor
                                    }
                                    CheckBox {
                                        id: chipBox
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        visible: model.type !== "_nocheck"
                                        text: model.text
                                        checked: action_cb_filter.modelValues[index]
                                        onToggled: {
                                            const vals = action_cb_filter.modelValues;
                                            vals[index] = checked ? 1 : 0;
                                            cfg_FilterStr = Utils.intArrayToStr(vals);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Active-playlist banner
            Rectangle {
                Layout.fillWidth: true
                height: 32
                visible: wallpaperPageRoot.cfg_ActivePlaylistId !== ""
                color: Kirigami.Theme.activeBackgroundColor
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 4
                    Label {
                        Layout.fillWidth: true
                        verticalAlignment: Text.AlignVCenter
                        text: wallpaperPageRoot.cfg_ActivePlaylistId === "__filtered_library__"
                            ? "Filtered Library is active · Item " + (wallpaperPageRoot.cfg_CurrentItemIndex + 1)
                            : "Playlist is active · Item " + (wallpaperPageRoot.cfg_CurrentItemIndex + 1)
                    }
                    Button {
                        text: "Stop"
                        onClicked: {
                            if (wallpaperPageRoot.playlistManager)
                                wallpaperPageRoot.playlistManager.deactivate();
                        }
                    }
                }
            }

            Loader {
                id: picViewLoader
                Layout.fillWidth: true
                Layout.fillHeight: true
                
                // over wite the implicitWidth to 0
                Layout.preferredHeight: 0

                asynchronous: false
                sourceComponent: picViewCom
                visible: status == Loader.Ready

                Component.onCompleted: {
                    const refreshIndex = () => {
                        this.item.view.model = wpListModel.model; 
                        if(this.status == Loader.Ready) {
                            this.item.setCurIndex(wpListModel.model);
                        }
                    }
                    wpListModel.modelStartSync.connect(this.item.backtoBegin);
                    wpListModel.modelRefreshed.connect(refreshIndex.bind(this));
                }

                Kirigami.Heading {
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.WordWrap
                    visible: picViewLoader.item && picViewLoader.item.view.count === 0
                    level: 2
                    text: {
                        if(!pyext.ok) {
                            return `Python helper run failed: ${pyext.log}`;
                        }
                        if(!cfg_SteamLibraryPath)
                            return "Select your steam library through the folder selecting button above";
                        if(wpListModel.countNoFilter > 0)
                            return `Found ${wpListModel.countNoFilter} wallpapers, but none of them matched filters`;
                        return `There are no wallpapers in steam library`;
                    }
                    opacity: 0.5
                }
            }
            Component {
                id: picViewCom
                WallpaperGrid {
                    id: picViewGrid
                    anchors.fill: parent

                    activeWorkshopId: cfg_WallpaperWorkShopId
                    iconSize: root.iconSizes.large
                    animatedPreviewActive: cfg_AnimatedPreview
                    showFavorites: true
                    showWorkshopLink: true
                    customConf: root.customConf
                    autoCommitOnIndexResolve: !cfg_WallpaperSource

                    onItemClicked: (item, index) => {
                        cfg_WallpaperSource = Common.packWallpaperSource(item);
                        cfg_WallpaperWorkShopId = item.workshopid;
                    }
                    onItemRightClicked: (item, index, x, y) => {
                        if (!wallpaperPageRoot.playlistManager) return;
                        addToPlaylistMenu.item = item;
                        addToPlaylistMenu.popup();
                    }
                    onSaveCustomConfRequested: root.saveCustomConf()
                }
            }

            FolderDialog {
                id: wpDialog
                title: "Select steamlibrary folder"
                onAccepted: {
                    const path = Utils.trimCharR(wpDialog.selectedFolder.toString(), '/');
                    cfg_SteamLibraryPath = path;
                    return wpListModel.refresh();
                }
            }

            // "Save filter as playlist" prompt — snapshots every wallpaper
            // currently in wpListModel.model into a new sequential playlist.
            Dialog {
                id: saveFilterPrompt
                title: "Save filter as playlist"
                modal: true
                anchors.centerIn: parent
                contentItem: TextField {
                    id: saveFilterNameField
                    placeholderText: "Playlist name"
                }
                standardButtons: Dialog.Ok | Dialog.Cancel
                onAccepted: {
                    if (!wallpaperPageRoot.playlistManager) return;
                    if (saveFilterNameField.text.trim() === "") return;
                    const id = wallpaperPageRoot.playlistManager.createPlaylist(
                        saveFilterNameField.text.trim());
                    const m = wpListModel.model;
                    for (let i = 0; i < m.count; ++i)
                        wallpaperPageRoot.playlistManager.addItem(id, m.get(i).workshopid);
                    saveFilterNameField.text = "";
                }
            }
        }
    }

    Control {
        id: right_content
        Layout.preferredWidth: parent.width / 3
        Layout.fillHeight: true

        readonly property int image_size: 300
        readonly property int content_margin: 16
        // Source-tracking pair: _wpmodel_src is the bare model reference
        // (cheap identity-tracked binding); wpmodel is the converted JS
        // object the ~10 right-pane consumers read. Separating the source
        // from the converter keeps notify de-dup honest — identical
        // currentModel references collapse to a single eval instead of
        // running wpitemFromQtObject on every dependency flicker. wpmodel
        // stays writable (not `readonly`) — the qmltest harness pins it
        // directly to drive selection-change branches.
        readonly property var _wpmodel_src: picViewLoader.item ? picViewLoader.item.currentModel : null
        property var wpmodel: _wpmodel_src
            ? Common.wpitemFromQtObject(_wpmodel_src)
            : Common.wpitem_template

        visible: Layout.preferredWidth > image_size + content_margin*2 + right_content_scrollbar.width

        topPadding: 0
        leftPadding: 0
        rightPadding: 0
        bottomPadding: 0

        background: Rectangle {
            color: Kirigami.Theme.backgroundColor
        }

        contentItem: Flickable {
            anchors.fill: parent

            ScrollBar.vertical: ScrollBar { id: right_content_scrollbar }

            contentWidth: width - (right_content_scrollbar.visible ? right_content_scrollbar.width : 0)
            contentHeight: flick_content.implicitHeight

            clip: true
            boundsBehavior: Flickable.OvershootBounds

            ColumnLayout {
                id: flick_content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: right_content.content_margin
                anchors.rightMargin: anchors.leftMargin
                spacing: 8

                AnimatedImage { 
                    id: animated_image; 
                    Layout.topMargin: right_content.content_margin
                    Layout.preferredWidth: right_content.image_size
                    Layout.preferredHeight: Layout.preferredWidth
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop

                    source: Common.getWpModelPreviewSource(right_content.wpmodel)
                    sourceSize.width: right_content.image_size
                    fillMode: Image.PreserveAspectFit
                    cache: true
                    asynchronous: true
                    onStatusChanged: playing = (status == AnimatedImage.Ready)
                }

                Text {
                    Layout.alignment: Qt.AlignTop
                    Layout.minimumWidth: 0
                    Layout.fillWidth: true
                    Layout.minimumHeight: implicitHeight

                    text: right_content.wpmodel?.title ?? ""
                    color: Kirigami.Theme.textColor
                    font.bold: true
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                }

                // Pre-apply warning for unrenderable wallpaper types. The
                // grid badge surfaces these on the left; this surfaces them
                // again in the right pane so a keyboard-arrow-selecting user
                // gets the same hint before clicking Apply. Loader keeps the
                // Label out of the scene-graph entirely for renderable types
                // (consistent with WallpaperGrid.qml's badge Loader).
                Loader {
                    Layout.fillWidth: true
                    active: right_content.wpmodel
                         && (right_content.wpmodel.type === "application"
                          || right_content.wpmodel.type === "preset")
                    sourceComponent: Label {
                        text: right_content.wpmodel
                              && right_content.wpmodel.type === "application"
                            ? "Application wallpapers ship a native Windows .exe host and cannot be rendered by this plugin. Apply will fail."
                            : "Preset wallpapers reference another workshop entry; they are not standalone and cannot be rendered by this plugin. Apply will fail."
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                        width: parent ? parent.width : implicitWidth
                    }
                }

                RowLayout {
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    spacing: 8

                    Control {
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Kirigami.Theme.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                            text: right_content.wpmodel?.type ?? ""
                        }
                    }

                    Control {
                        id: control_dir_size
                        leftPadding: 8
                        topPadding: 4

                        rightPadding: leftPadding
                        bottomPadding: topPadding
                        visible: false

                        background: Rectangle {
                            color: Kirigami.Theme.positiveBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            id: dirSizeText
                            color: Kirigami.Theme.textColor
                            font.capitalization: Font.Capitalize
                        }
                        function refreshDirSize() {
                            const dir = right_content.wpmodel ? right_content.wpmodel.path : "";
                            if (!dir || !dir.match(Common.regex_path_check)) {
                                control_dir_size.visible = false;
                                return;
                            }
                            pyext.get_dir_size(Common.urlNative(dir)).then(res => {
                                dirSizeText.text = Utils.prettyBytes(res);
                                control_dir_size.visible = true;
                            }).catch(reason => console.error(reason));
                        }
                        Connections {
                            target: right_content
                            function onWpmodelChanged() { control_dir_size.refreshDirSize(); }
                        }
                        Component.onCompleted: refreshDirSize()
                    }

                    Kirigami.ActionToolBar {
                        Layout.fillWidth: false
                        Layout.preferredWidth: implicitWidth
                        flat: true

                        actions: [
                            Kirigami.Action {
                                id: right_act_favor
                                
                                icon.name: right_content.wpmodel.favor 
                                    ? "bookmarks-symbolic"
                                    : "bookmark-add-symbolic"
                                tooltip: right_content.wpmodel.favor
                                    ? 'Remove from favorites'
                                    : 'Add to favorites'
                                onTriggered: picViewLoader.item.toggleFavor(right_content.wpmodel)
                            },
                            Kirigami.Action {
                                icon.name: "emblem-symbolic-link"
                                tooltip: "Open Workshop Link"
                                enabled: right_content.wpmodel.workshopid.match(Common.regex_workshop_online)
                                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(right_content.wpmodel.workshopid))
                            },
                            Kirigami.Action {
                                icon.name: "folder-symbolic"
                                tooltip: "Open Containing Folder"
                                // Qt.openUrlExternally silently no-ops on
                                // bare paths — needs a scheme. Most
                                // wpmodel.path values are already
                                // "file://..." from QUrl resolution, but
                                // guard the bare-path case anyway.
                                onTriggered: {
                                    const p = right_content.wpmodel.path || "";
                                    const url = p.indexOf("://") > 0 ? p
                                                : (p.startsWith("/") ? ("file://" + p) : p);
                                    Qt.openUrlExternally(url);
                                }
                            }
                        ]
                    }
                }

                ListView {
                    id: tagsListView
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
                    implicitWidth: contentItem.childrenRect.width
                    implicitHeight: contentItem.childrenRect.height

                    orientation: ListView.Horizontal
                    model: ListModel {}
                    function rebuildTags() {
                        const wpmodel = right_content.wpmodel;
                        const _model = tagsListView.model;
                        _model.clear();
                        // tags/playlists are ListModels (.count + .get) at runtime
                        // but can be arrays or empty/undefined in transient states.
                        // Resolve length from .count OR .length and append only real
                        // objects — `Array(model.length)` is `[undefined]` for a
                        // ListModel (no .length), which silently dropped all but the
                        // first row and appended a non-object.
                        const _appendAll = (src) => {
                            if (! src) return;
                            const n = (src.count !== undefined) ? src.count
                                    : (src.length !== undefined ? src.length : 0);
                            for (let i = 0; i < n; ++i) {
                                const v = src.get ? src.get(i) : src[i];
                                if (v && typeof v === "object") _model.append(v);
                            }
                        };
                        _appendAll(wpmodel ? wpmodel.tags : null);
                        _appendAll(wpmodel ? wpmodel.playlists : null);
                        if (wpmodel && wpmodel.contentrating !== undefined)
                            _model.append({key: wpmodel.contentrating});
                    }
                    Connections {
                        target: right_content
                        function onWpmodelChanged() { tagsListView.rebuildTags(); }
                    }
                    Component.onCompleted: rebuildTags()
                    clip: false
                    spacing: 8

                    delegate: Control {
                        leftPadding: 8
                        topPadding: 4
                        rightPadding: leftPadding
                        bottomPadding: topPadding

                        background: Rectangle {
                            color: Kirigami.Theme.activeBackgroundColor
                            radius: 8
                        }
                        contentItem: Text {
                            color: Kirigami.Theme.textColor
                            text: model.key
                        }
                    }
                }

                Component {
                    id: right_opt_combox
                    ComboBox {
                        property var def_val

                        textRole: "text"
                        onActivated: {}

                        property var res_val: currentIndex >= 0 ? Common.cbCurrentValue(this) : def_val
                        function finish() {
                            currentIndex = Common.cbIndexOfValue(this, def_val);
                        }
                    }
                }
                Component {
                    id: right_opt_switch
                    Switch {
                        property bool def_val
                        property bool res_val: checked
                        function finish() {
                            checked = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_spinbox
                    SpinBox {
                        property int def_val
                        property int res_val: value
                        function finish() {
                            value = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_dspinbox
                    DoubleSpinBox {
                        property real def_val
                        property real res_val: dValue
                        function finish() {
                            dValue = def_val;
                        }
                    }
                }
                Component {
                    id: right_opt_color
                    // Override ColorButton's per-channel-floats res_val with
                    // Qt's color string so the per-wallpaper override
                    // round-trips through the same BackgroundColor format the
                    // global setting uses (and Rectangle.color accepts).
                    ColorButton {
                        res_val: colorValue.toString()
                    }
                }

                OptionGroup {
                    id: right_opts
                    Layout.fillWidth: true

                    readonly property string workshopid: wallpaperPageRoot.activeWorkshopid

                    property var config_resets: new Set()
                    property var config_changes: ({})
                    // config is sourced from the page-root shared read — one
                    // pyext.read_wallpaper_config per selection across both
                    // OptionGroups (used to be two: right_opts + user_props_
                    // group each issued their own). The downstream
                    // onConfigChanged Repeater notify (line ~919) still fires
                    // because reassigning activeConfig emits a notify here.
                    property var config: wallpaperPageRoot.activeConfig

                    // Opt-in debug traces for the per-wallpaper save flow.
                    // Default OFF — release builds stay quiet (the journal
                    // used to flood with five lines per per-wallpaper option
                    // flip including JSON.stringify(config_changes) dumps).
                    // Enable by toggling this property at runtime from a dev
                    // overlay; debugLogCount is bumped on each emit so tests
                    // can verify the gate without intercepting console.log
                    // (qmltestrunner suppresses it; the binding is native).
                    property bool debugLogs: false
                    property int debugLogCount: 0
                    function _debugLog(...args) {
                        if (!debugLogs) return;
                        debugLogCount++;
                        console.log(...args);
                    }
                    function save_changes() {
                        _debugLog("save_changes called, config_changes:", JSON.stringify(config_changes));
                        config_resets.forEach((wid) => {
                            pyext.reset_wallpaper_config(wid).then(res => {});
                        });
                        Object.entries(config_changes).forEach(([wid, cfg]) => {
                            _debugLog("saving config for wid:", wid, "cfg:", JSON.stringify(cfg));
                            pyext.write_wallpaper_config(wid, cfg);
                        });
                        // Clear after saving
                        config_changes = {};
                        config_resets.clear();
                    }
                    function set_config(key, val) {
                        _debugLog("set_config called, key:", key, "val:", val, "workshopid:", workshopid);
                        if(!key || !workshopid) return;

                        if (!config_changes[workshopid])
                            config_changes[workshopid] = {}
                        config_changes[workshopid][key] = val;

                        this.config_changesChanged();

                        // Write to disk immediately (like savePropChange does)
                        const cfg = {};
                        cfg[key] = val;
                        pyext.write_wallpaper_config(workshopid, cfg);

                        _debugLog("set_config: cfg_PerOptChanged before:", cfg_PerOptChanged);
                        cfg_PerOptChanged++;
                        _debugLog("set_config: cfg_PerOptChanged after:", cfg_PerOptChanged);
                    }
                    function reset_config() {
                        config_resets.add(workshopid);
                        delete config_changes[workshopid];
                        config = {}
                        // Write reset to disk immediately
                        pyext.reset_wallpaper_config(workshopid);
                        cfg_PerOptChanged++;
                    }
                    function in_config_changes(key) {
                        return config_changes.hasOwnProperty(workshopid) && config_changes[workshopid].hasOwnProperty(key);
                    }

                    function get_config_val(key) {
                        if (in_config_changes(key))
                            return config_changes[workshopid][key];
                        if (config.hasOwnProperty(key))
                            return config[key];
                        return null;
                    }
                    function has_change(key) {
                        return config.hasOwnProperty(key) || in_config_changes(key);
                    }

                    header.text: 'Option'
                    header.text_color: Kirigami.Theme.textColor
                    header.icon: '../../images/cheveron-down.svg'
                    header.color: Kirigami.Theme.activeBackgroundColor

                    header.actor: Kirigami.ActionToolBar {
                        Layout.fillWidth: true
                        alignment: Qt.AlignRight
                        flat: true
                        actions: [
                            Kirigami.Action {
                                text: 'Reset'
                                onTriggered: resetSceneOptsConfirm.open()
                            }
                        ]
                    }
                    Repeater {
                        property bool markModel: false;
                        model: [
                            {
                                mark_: markModel,
                                text: 'Display',
                                config_key: 'display_mode',
                                comp: right_opt_combox,
                                props: {
                                    model: [
                                        {
                                            text: "Keep Aspect Ratio",
                                            value: Common.DisplayMode.Aspect
                                        },
                                        {
                                            text: "Scale and Crop",
                                            value: Common.DisplayMode.Crop
                                        },
                                        {
                                            text: "Scale to Fill",
                                            value: Common.DisplayMode.Scale
                                        },
                                    ],
                                    def_val: cfg_DisplayMode,
                                }
                            },
                            // Per-wallpaper Background Color override.  Shows
                            // through the letterbox bars in Keep-Aspect-Ratio
                            // mode now that backend/Scene.qml sizes the renderer
                            // to the wallpaper's native aspect (nativeAspectRatio).
                            {
                                mark_: markModel,
                                text: 'Background Color',
                                config_key: 'background_color',
                                comp: right_opt_color,
                                props: {
                                    def_val: cfg_BackgroundColor,
                                },
                            },
                            {
                                text: 'Mute Audio',
                                config_key: 'mute_audio',
                                comp: right_opt_switch,
                                props: {
                                    def_val: cfg_MuteAudio
                                },
                            },
                            {
                                text: 'Volume',
                                config_key: 'volume', 
                                comp: right_opt_spinbox,
                                props: {
                                    def_val: cfg_Volume,
                                    from: 1,
                                    to: 100,
                                    stepSize: 1,
                                },
                            },
                            {
                                text: 'Speed',
                                config_key: 'speed', 
                                comp: right_opt_dspinbox,
                                props: {
                                    def_val: cfg_Speed,
                                    dFrom: 0.1,
                                    dTo: 16,
                                    dStepSize: 0.1,
                                },
                            },
                            // ON → "ultra" (HDR mip-chain bloom), OFF → scene
                            // default. Experimental: Ultra can look too dark on
                            // some scenes (audit open); opt-in per wallpaper.
                            {
                                text: 'Postprocessing (Ultra, experimental)',
                                config_key: 'postprocessing',
                                comp: right_opt_switch,
                                props: {
                                    def_val: false,
                                },
                            },

                        ]
                        OptionItem {
                            text: modelData.text
                            text_color: Kirigami.Theme.textColor

                            property bool is_changed: right_opts.config &&
                                right_opts.config_changes &&
                                right_opts.has_change(modelData.config_key)

                            icon: is_changed ? Qt.resolvedUrl('../../images/edit-pencil.svg') : ''
                            actor: Loader {
                                sourceComponent: modelData.comp
                                onLoaded: {
                                    Object.entries(modelData.props).forEach(([key, value]) => {
                                        this.item[key] = value;
                                    });
                                    const changed_val = right_opts.get_config_val(modelData.config_key);
                                    if(changed_val !== null) {
                                        this.item['def_val'] = changed_val;
                                    }

                                    this.item.finish();
                                    this.item.onRes_valChanged.connect(() => {
                                        right_opts.set_config(modelData.config_key, this.item.res_val);
                                    });
                                }
                            }
                        }
                        Component.onCompleted: {
                            right_opts.onConfigChanged.connect(() => {
                                markModel = !markModel;
                            });
                        }
                    }
                }
                // User Properties from project.json
                Component {
                    id: user_prop_color
                    ColorButton { }
                }
                // String-valued user property — wallpapers read it as
                // properties.<key>.value with type "textinput".
                Component {
                    id: user_prop_textinput
                    TextField {
                        property string def_val: ""
                        property string res_val: text
                        function finish() { text = def_val; }
                        // Keep the picker compact — most labels are wide
                        // enough that we don't need a sprawling field.
                        Layout.preferredWidth: 220
                    }
                }
                // File picker — wallpapers receive the absolute path string
                // (matching WE Windows behaviour, including the leading
                // "file:///" prefix the wallpaper itself prepends if it
                // wants a URL).  `fileType` (set by onLoaded) drives the
                // FileDialog name-filters; unknown/missing falls back to
                // all-files so users are never blocked.
                Component {
                    id: user_prop_file
                    Row {
                        spacing: 4
                        property string def_val: ""
                        property string fileType: ""
                        property string res_val: pathField.text
                        function finish() {
                            pathField.text = def_val;
                            fileDlg.nameFilters = Utils.fileTypeNameFilters(fileType);
                        }
                        TextField {
                            id: pathField
                            width: 220
                            placeholderText: "(no file selected)"
                        }
                        Button {
                            text: "Browse…"
                            onClicked: fileDlg.open()
                        }
                        FileDialog {
                            id: fileDlg
                            onAccepted: {
                                pathField.text = Common.urlNative(fileDlg.selectedFile.toString());
                            }
                        }
                    }
                }
                // Directory picker — same shape as user_prop_file but with
                // a FolderDialog so wallpapers can use it for slideshow
                // roots, etc.
                Component {
                    id: user_prop_directory
                    Row {
                        spacing: 4
                        property string def_val: ""
                        property string res_val: pathField.text
                        function finish() { pathField.text = def_val; }
                        TextField {
                            id: pathField
                            width: 220
                            placeholderText: "(no folder selected)"
                        }
                        Button {
                            text: "Browse…"
                            onClicked: dirDlg.open()
                        }
                        FolderDialog {
                            id: dirDlg
                            onAccepted: {
                                pathField.text = Utils.trimCharR(
                                    Common.urlNative(dirDlg.selectedFolder.toString()), '/');
                            }
                        }
                    }
                }

                OptionGroup {
                    id: user_props_group
                    Layout.fillWidth: true
                    visible: user_props_repeater.model.length > 0

                    readonly property string workshopid: wallpaperPageRoot.activeWorkshopid
                    onWorkshopidChanged: {
                        // Load saved config FIRST so it's available when Repeater creates delegates
                        propChanges = {};
                        if (workshopid) {
                            // propConfig is sourced from wallpaperPageRoot.
                            // activeConfig (one read per selection, shared
                            // with right_opts); we only need to fetch the
                            // user-props-specific active bindings here.
                            pyext.read_active_bindings(workshopid).then(res => {
                                activeBindings = Array.isArray(res) ? res : [];
                            });
                        } else {
                            activeBindings = [];
                        }
                        // Clear last — this triggers _loadProps → userProperties → Repeater rebuild
                        userProperties = [];
                    }

                    property var userProperties: []
                    property var propConfig: wallpaperPageRoot.activeConfig
                    property var propChanges: ({})
                    property var activeBindings: []

                    property bool _loadProps: {
                        // Force re-evaluation when workshopid changes
                        const wid = workshopid;
                        const wpPath = right_content.wpmodel.path;
                        const projectPath = Common.getWpModelProjectPath(right_content.wpmodel);
                        if (wid && wpPath && wpPath.match(Common.regex_path_check)) {
                            pyext.readfile(Common.urlNative(projectPath)).then(value => {
                                const project = Utils.parseJson(value);
                                if (project && project.general && project.general.properties) {
                                    const props = project.general.properties;
                                    const arr = [];
                                    // Pulled into Utils.formatPropertyLabel so the
                                    // transform is unit-testable. Behavior unchanged.
                                    const formatLabel = Utils.formatPropertyLabel;
                                    for (const key in props) {
                                        const prop = props[key];
                                        // Skip non-interactive types (info text, groups)
                                        if (!prop.type || prop.type === 'text' || prop.type === 'group')
                                            continue;
                                        arr.push({
                                            key: key,
                                            text: formatLabel(prop.text, key),
                                            type: prop.type,
                                            value: prop.value,
                                            min: prop.min,
                                            max: prop.max,
                                            options: prop.options,
                                            fileType: prop.fileType  // for file picker name filters
                                        });
                                    }
                                    userProperties = arr;
                                } else {
                                    userProperties = [];
                                }
                            }).catch(reason => {
                                console.error(`read project.json error: ${reason}`);
                                userProperties = [];
                            });
                        } else {
                            userProperties = [];
                        }
                        return true;
                    }

                    function savePropChange(key, val) {
                        if (!workshopid) return;

                        // Create new object to trigger QML binding update
                        const newChanges = Object.assign({}, propChanges);
                        newChanges[key] = val;
                        propChanges = newChanges;

                        // Build config to save: merge with existing under 'user_props' key
                        const userPropsConfig = {};
                        userPropsConfig['user_props'] = Object.assign({}, propConfig['user_props'] || {}, propChanges);
                        pyext.write_wallpaper_config(workshopid, userPropsConfig);

                        // Signal main.qml to reload config
                        cfg_PerOptChanged++;
                    }

                    function getPropValue(key, defaultVal) {
                        if (propChanges.hasOwnProperty(key)) return propChanges[key];
                        if (propConfig['user_props'] && propConfig['user_props'].hasOwnProperty(key))
                            return propConfig['user_props'][key];
                        return defaultVal;
                    }

                    function resetUserProps() {
                        propChanges = {};
                        const resetConfig = { 'user_props': {} };
                        pyext.write_wallpaper_config(workshopid, resetConfig);
                        propConfig = {};

                        // Signal main.qml to reload config
                        cfg_PerOptChanged++;
                    }

                    header.text: 'User Properties'
                    header.text_color: Kirigami.Theme.textColor
                    header.icon: '../../images/cheveron-down.svg'
                    header.color: Kirigami.Theme.activeBackgroundColor

                    header.actor: Kirigami.ActionToolBar {
                        Layout.fillWidth: true
                        alignment: Qt.AlignRight
                        flat: true
                        actions: [
                            Kirigami.Action {
                                text: 'Reset'
                                onTriggered: resetUserPropsConfirm.open()
                            }
                        ]
                    }

                    Repeater {
                        id: user_props_repeater
                        model: user_props_group.userProperties

                        OptionItem {
                            text: modelData.text
                            text_color: Kirigami.Theme.textColor

                            // Gray out properties not bound to any shader
                            property bool isBound: {
                                const ab = user_props_group.activeBindings;
                                return !Array.isArray(ab) || ab.length === 0
                                    || ab.indexOf(modelData.key) >= 0;
                            }
                            enabled: isBound
                            opacity: isBound ? 1.0 : 0.4

                            property bool is_changed: user_props_group.propChanges.hasOwnProperty(modelData.key)
                            icon: is_changed ? Qt.resolvedUrl('../../images/edit-pencil.svg') : ''

                            actor: Loader {
                                sourceComponent: {
                                    switch(modelData.type) {
                                        case 'bool':
                                            return right_opt_switch;
                                        case 'slider':
                                            // Use int spinbox if min/max are integers
                                            const hasDecimals = (modelData.min && modelData.min % 1 !== 0) ||
                                                               (modelData.max && modelData.max % 1 !== 0) ||
                                                               (modelData.value && modelData.value % 1 !== 0);
                                            return hasDecimals ? right_opt_dspinbox : right_opt_spinbox;
                                        case 'color':
                                            return user_prop_color;
                                        case 'combo':
                                            return right_opt_combox;
                                        case 'textinput':
                                            return user_prop_textinput;
                                        case 'file':
                                            return user_prop_file;
                                        case 'directory':
                                            return user_prop_directory;
                                        default:
                                            return null;
                                    }
                                }

                                onLoaded: {
                                    const savedVal = user_props_group.getPropValue(modelData.key, null);
                                    const defVal = savedVal !== null ? savedVal : modelData.value;

                                    switch(modelData.type) {
                                        case 'bool':
                                            this.item.def_val = Boolean(defVal);
                                            break;
                                        case 'slider':
                                            const hasDecimals = (modelData.min && modelData.min % 1 !== 0) ||
                                                               (modelData.max && modelData.max % 1 !== 0) ||
                                                               (modelData.value && modelData.value % 1 !== 0);
                                            if (hasDecimals) {
                                                this.item.dFrom = modelData.min || 0;
                                                this.item.dTo = modelData.max || 100;
                                                this.item.dStepSize = (modelData.max - modelData.min) / 100 || 0.01;
                                                this.item.def_val = defVal || 0;
                                            } else {
                                                this.item.from = Math.floor(modelData.min || 0);
                                                this.item.to = Math.floor(modelData.max || 100);
                                                this.item.stepSize = 1;
                                                this.item.def_val = Math.floor(defVal || 0);
                                            }
                                            break;
                                        case 'color':
                                            // Color can be string "0.1 0.2 0.3" or object {r,g,b}
                                            let colorVal = "#ffffff";
                                            if (typeof defVal === 'string' && defVal.includes(' ')) {
                                                const parts = defVal.split(' ').map(Number);
                                                if (parts.length >= 3) {
                                                    colorVal = Qt.rgba(parts[0], parts[1], parts[2], 1.0);
                                                }
                                            } else if (defVal && typeof defVal === 'string') {
                                                colorVal = defVal;
                                            }
                                            this.item.def_val = colorVal;
                                            this.item.colorValue = colorVal;
                                            break;
                                        case 'combo':
                                            // Build model from options
                                            if (modelData.options) {
                                                const comboModel = [];
                                                for (const opt of modelData.options) {
                                                    let label = String(opt.label || opt.value);
                                                    // Convert localization keys to readable text
                                                    if (label.startsWith('ui_browse_properties_')) {
                                                        const suffix = label.replace('ui_browse_properties_', '');
                                                        label = suffix.split('_').map(w =>
                                                            w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
                                                        ).join(' ');
                                                    }
                                                    // Strip HTML tags
                                                    label = label.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
                                                    comboModel.push({
                                                        text: label,
                                                        value: opt.value
                                                    });
                                                }
                                                this.item.model = comboModel;
                                                this.item.def_val = defVal || 0;
                                            }
                                            break;
                                        case 'textinput':
                                        case 'directory':
                                            this.item.def_val = (typeof defVal === 'string') ? defVal : "";
                                            break;
                                        case 'file':
                                            this.item.def_val = (typeof defVal === 'string') ? defVal : "";
                                            // WE properties carry .fileType (video/image/sound);
                                            // missing → empty → all-files filter
                                            this.item.fileType = modelData.fileType || "";
                                            break;
                                    }

                                    this.item.finish();
                                    this.item.onRes_valChanged.connect(() => {
                                        user_props_group.savePropChange(modelData.key, this.item.res_val);
                                    });
                                }
                            }
                        }
                    }
                }

                PlasmaComponents.TextArea {
                    id: descriptionTextArea
                    Layout.alignment: Qt.AlignTop
                    Layout.fillWidth: true
                    Layout.minimumWidth: 0
                    Layout.minimumHeight: implicitHeight

                    visible: false
                    text: ''
                    color: Kirigami.Theme.textColor

                    function loadDescription() {
                        const path = Common.getWpModelProjectPath(right_content.wpmodel);
                        if (path) {
                            pyext.readfile(Common.urlNative(path)).then(value => {
                                const project = Utils.parseJson(value);
                                const desc = project && project.description ? project.description : '';
                                descriptionTextArea.visible = Boolean(desc);
                                if (descriptionTextArea.visible) {
                                    descriptionTextArea.text = BBCode.parser.parse(desc);
                                }
                            }).catch(reason => console.error(`read '${path}' error\n`, reason));
                        } else {
                            descriptionTextArea.visible = false;
                        }
                    }

                    Connections {
                        target: right_content
                        function onWpmodelChanged() {
                            descriptionTextArea.loadDescription();
                        }
                    }
                    Component.onCompleted: loadDescription()

                    font.bold: false
 
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                    horizontalAlignment: Text.AlignLeft
                    readOnly: true

                    onLinkActivated: Qt.openUrlExternally(link)
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                        acceptedButtons: Qt.NoButton
                    }
                }
            }
        }
    }
}
