// Shared grid surface used by both WallpaperPage (WE wallpapers) and
// VideoPage (plain videos). Source-agnostic: emits intent (itemClicked,
// favorToggled) and lets the parent page decide what to do.
import QtQuick 2.6
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.5
import QtQuick.Window 2.0

import ".."

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kcmutils as KCM
import org.kde.kirigami 2.6 as Kirigami

KCM.GridView {
    id: root

    // ── Public API ───────────────────────────────────────────────────────────
    property string activeWorkshopId: ""
    property int    iconSize: 48
    property bool   animatedPreviewActive: true   // bind from cfg_AnimatedPreview on WE
    property bool   showFavorites: true
    property bool   showWorkshopLink: true
    property var    customConf: null              // {favor: Set} when showFavorites
    property string accessibleName: "Wallpapers"  // override per-caller (Orca announces this)
    signal itemClicked(var item, int index)
    signal favorToggled(var item, int index)
    signal itemRightClicked(var item, int index, real x, real y)
    signal saveCustomConfRequested()

    // Screen-reader hints. KCM.GridView is a QML Item under the hood, so the
    // attached Accessible.* props are honoured even though the framework
    // didn't ship them.
    Accessible.role: Accessible.List
    Accessible.name: accessibleName

    // System-pref read for honouring "Reduce animations" in the desktop's
    // accessibility settings. `hasOwnProperty` survives older Kirigami
    // builds where `hasReducedAnimations` may not yet exist (Plasma 6.0/
    // 6.1) without a binding error — the AnimatedImage preview Loader
    // below reads this to fall back to a static Image.  Non-`readonly`
    // so the QML test harness can override the live binding to probe
    // both axes (animatedPreviewActive × reducedMotion) without mocking
    // the Kirigami singleton itself.
    property bool reducedMotion: Kirigami.Settings.hasOwnProperty('hasReducedAnimations')
                                 ? Kirigami.Settings.hasReducedAnimations
                                 : false

    // ── Internal state preserved from original implementation ────────────────
    readonly property var currentModel: view.model.get(view.currentIndex)
    readonly property var defaultModel: ListModel {}
    visible: view.count > 0

    view.implicitCellWidth: Screen.width / 10 + Kirigami.Units.smallSpacing * 2
    view.implicitCellHeight: Screen.height / 10 + Kirigami.Units.smallSpacing * 2 + Kirigami.Units.gridUnit * 3
    view.model: defaultModel
    view.delegate: KCM.GridDelegate {
        text: title
        hoverEnabled: true

        // Screen-reader announcement per tile. Falls back to workshopid when
        // title is empty (offline-rebuilt entries, malformed project.json).
        // Description carries the unrenderable-type hint surfaced visually by
        // the badge Loader below — Orca speaks it after the name so the user
        // hears "Wallpaper 2866 — Unsupported: Windows application".
        Accessible.role: Accessible.ListItem
        Accessible.name: title || workshopid
        Accessible.description: {
            if (!model.type) return "";
            if (model.type === "application") return "Unsupported: Windows application";
            if (model.type === "preset")      return "Unsupported: preset overlay";
            return model.type;
        }
        Accessible.selected: index === view.currentIndex
        Accessible.onPressAction: {
            view.currentIndex = index;
            root.itemClicked(model, index);
        }

        actions: [
            Kirigami.Action {
                visible: root.showFavorites
                icon.name: favor ? "user-bookmarks-symbolic" : "bookmark-add-symbolic"
                tooltip: favor ? i18nc("@info:tooltip remove wallpaper from favorites", "Remove from favorites") : i18nc("@info:tooltip add wallpaper to favorites", "Add to favorites")
                Accessible.role: Accessible.Button
                Accessible.name: tooltip
                onTriggered: root.toggleFavor(model, index)
            },
            Kirigami.Action {
                visible: root.showWorkshopLink
                icon.name: "folder-remote-symbolic"
                tooltip: i18nc("@info:tooltip open workshop link in browser", "Open Workshop Link")
                enabled: workshopid && workshopid.match(Common.regex_workshop_online)
                Accessible.role: Accessible.Button
                Accessible.name: tooltip
                onTriggered: Qt.openUrlExternally(Common.getWorkshopUrl(workshopid))
            }
        ]
        thumbnail: Rectangle {
            anchors.fill: parent
            color: "transparent"

            Kirigami.Icon {
                anchors.centerIn: parent
                width: root.iconSize
                height: width
                source: "view-preview"
                visible: imgPre.status !== Loader.Ready || (imgPre.item && !imgPre.item.visible)
            }

            Loader {
                id: imgPre
                anchors.fill: parent
                // System "Reduce animations" pref wins over the user's
                // cfg_AnimatedPreview: never pump GIF playback into the
                // grid when the desktop asked us not to. The user-pref
                // controls only the downward direction; reduced-motion
                // is one-way authoritative.
                sourceComponent: (root.animatedPreviewActive && !root.reducedMotion)
                    ? animatedPre : staticPre
            }

            // "Updated since you last loaded it" dot badge. The Loader keeps
            // it out of the scene-graph entirely for un-updated entries —
            // important for libraries with hundreds of wallpapers where only
            // one or two might carry the badge at any given time.
            //
            // model.updated may be absent on QML test stubs (older ListModel
            // shapes lack the field) — `=== true` keeps the binding silent
            // in that case rather than triggering a TypeError.
            Loader {
                id: updatedBadge
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing
                z: 2
                active: model.updated === true
                sourceComponent: Rectangle {
                    width: Kirigami.Units.iconSizes.small
                    height: width
                    radius: width / 2
                    color: Kirigami.Theme.positiveTextColor
                    border.color: Qt.rgba(0, 0, 0, 0.5)
                    border.width: 1
                    ToolTip.visible: ma.containsMouse
                    ToolTip.text: i18n("Updated since you last loaded it")
                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }
                }
            }

            // Unsupported-type badge. WallpaperListModel.loadItemFromJson
            // lowercases project.type at load; we surface the two unrenderable
            // types ('application' = native Windows .exe host, 'preset' =
            // pointer at another wallpaper) so users can spot them in the
            // grid instead of discovering on Apply. Theme-driven so it adapts
            // to light/dark schemes. The Loader keeps the Rectangle+Label
            // out of the scene-graph entirely for renderable types — cheaper
            // than a `visible:` toggle on a per-delegate basis across a
            // workshop folder of thousands of items.
            Loader {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Kirigami.Units.smallSpacing
                z: 2  // sit above imgPre (Loader fills the rectangle)
                active: model.type === "application" || model.type === "preset"
                sourceComponent: Rectangle {
                    radius: 3
                    color: Qt.rgba(0, 0, 0, 0.7)
                    border.color: Kirigami.Theme.negativeTextColor
                    border.width: 1
                    implicitWidth: badgeText.implicitWidth + 8
                    implicitHeight: badgeText.implicitHeight + 4
                    Label {
                        id: badgeText
                        anchors.centerIn: parent
                        text: model.type === "application"
                            ? i18nc("@info badge unsupported application wallpaper", "Application (unsupported)")
                            : i18nc("@info badge unsupported preset wallpaper", "Preset (unsupported)")
                        color: "white"
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                    }
                }
            }

            Component {
                id: animatedPre
                AnimatedImage {
                    anchors.fill: parent
                    source: Common.getWpModelPreviewSource(model);
                    sourceSize.width: parent.width
                    fillMode: Image.PreserveAspectCrop
                    clip: true
                    cache: false
                    asynchronous: true
                    smooth: true
                    visible: true
                    paused: false
                    onVisibleChanged: paused = !visible
                    onStatusChanged: playing = (status == AnimatedImage.Ready)
                }
            }

            Component {
                id: staticPre
                Image {
                    anchors.fill: parent
                    source: Common.getWpModelPreviewSource(model);
                    sourceSize.width: parent.width
                    sourceSize.height: parent.height
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    asynchronous: true
                    smooth: true
                    visible: Boolean(preview)
                }
            }
        }
        onClicked: {
            view.currentIndex = index;
            root.itemClicked(model, index);
        }

        // Right-click: emit signal so the parent page can pop a context menu
        // (e.g. AddToPlaylistMenu). Doesn't block left-click — propagates.
        // Accessible.ignored: the MouseArea is a supplemental gesture; the
        // context menu's own items are announced via their own MenuItem roles
        // once the menu pops, so this anchor doesn't need to speak.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            propagateComposedEvents: true
            Accessible.ignored: true
            onClicked: function(mouse) {
                root.itemRightClicked(model, index, mouse.x, mouse.y);
            }
        }
    }

    function backtoBegin() {
        view.model = defaultModel
    }

    // When true, setCurIndex emits itemClicked for the resolved index (used
    // by WE page on first run when no wallpaper has been set yet).
    property bool autoCommitOnIndexResolve: false

    function setCurIndex(model) {
        new Promise((resolve, reject) => {
            for (let i = 0; i < model.count; i++) {
                if (model.get(i).workshopid === root.activeWorkshopId) {
                    view.currentIndex = i;
                    break;
                }
            }
            if (view.currentIndex == -1 && model.count != 0)
                view.currentIndex = 0;

            if (root.autoCommitOnIndexResolve && view.currentIndex != -1)
                root.itemClicked(model.get(view.currentIndex), view.currentIndex);

            resolve();
        });
    }

    function toggleFavor(model, index) {
        if (!index) index = view.currentIndex;
        if (!root.customConf) {
            // No favorites store wired up — emit a signal so the page may handle.
            root.favorToggled(model, index);
            return;
        }
        if (model.favor) {
            root.customConf.favor.delete(model.workshopid);
        } else {
            root.customConf.favor.add(model.workshopid);
        }
        view.model.assignModel(index, { favor: !model.favor });
        root.saveCustomConfRequested();

        if (index == view.currentIndex) view.currentIndexChanged();
    }
}
