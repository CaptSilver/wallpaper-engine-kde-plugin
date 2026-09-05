import QtQuick 2.6
import QtQuick.Controls 2.2
import QtQuick.Dialogs
import QtQuick.Layouts 1.5

import ".."
import "../components"

import com.github.captsilver.wallpaperEngineKde

import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.kirigami 2.4 as Kirigami


Flickable {
    // Наследуем тему от родителя
    Kirigami.Theme.inherit: true

    Layout.fillWidth: true
    ScrollBar.vertical: ScrollBar { id: scrollbar }

    // Absolute local path -> file:// URL. Pasting the path straight after
    // "file://" leaves '#' and '?' for the URL parser to read as a fragment
    // or query marker, which silently cuts the name short. '%' goes first so
    // a literal percent in the path can't swallow the escapes added after it.
    function localFileUrl(path) {
        return "file://" + path.replace(/%/g, "%25")
                               .replace(/#/g, "%23")
                               .replace(/\?/g, "%3F");
    }

    // Diagnostic-bundle helpers.  They go in `resources` rather than the
    // Flickable's default property: Flickable reparents Items into its
    // contentItem and drops non-Items into a bare QObject child list that
    // never appears in data/children/resources, so anything declared the
    // plain way here is unreachable from the item tree.  The WekDiagnostics
    // QObject collects the bundle; FileDialog presents the save-as picker
    // after a successful create.
    resources: [
        WekDiagnostics { id: diagnostics },
        FileDialog {
            id: saveBundleDialog
            title: i18nc("@title:window save diagnostic bundle", "Save diagnostic bundle as...")
            fileMode: FileDialog.SaveFile
            nameFilters: [i18nc("@item:inlistbox file dialog name filter", "Tar gzip (*.tar.gz)")]
            onAccepted: {
                // The bundle already exists in the cache dir; picking a
                // destination has to copy it there, or the user goes looking
                // for a file that was never written.
                if (diagnostics.exportBundle(diagnosticRow.bundlePath, selectedFile)) {
                    diagnosticStatus.text = i18nc("@info diagnostic bundle saved, %1=destination path",
                                                  "Saved to %1",
                                                  Common.urlNative(selectedFile));
                } else {
                    console.warn("[wek-diag] Bundle export failed:", diagnostics.lastError());
                    diagnosticStatus.text = i18nc("@info diagnostic bundle export failed, %1=reason",
                                                  "Could not save bundle: %1",
                                                  diagnostics.lastError());
                }
            }
        }
    ]
    //ScrollBar.horizontal: ScrollBar { }

    contentWidth: width - (scrollbar.visible ? scrollbar.width : 0)
    contentHeight: contentItem.childrenRect.height
    clip: true
    boundsBehavior: Flickable.OvershootBounds

    OptionGroup {
        id: option_group
        header.visible: false
        anchors.left: parent.left
        anchors.right: parent.right

        OptionItem {
            text: i18nc("@label about page section", "Requirements")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'

            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: i18nc("@info about page requirements section, rich text", "<ol><li><i>Wallpaper Engine</i> installed on Steam</li><li>Subscribe to some wallpapers on the Workshop</li><li>Select the <i>steamlibrary</i> folder on the Wallpapers tab of this plugin<ul><li>The <i>steamlibrary</i> which contains the <i>steamapps</i> folder<ul><li>This is usually <i>~/.local/share/Steam</i> by default</li></ul></li><li><i>Wallpaper Engine</i> needs to be installed in this <i>steamlibrary</i></li></ul></li></ol>")
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            visible: libcheck.wallpaper

            text: i18nc("@label about page section fix crashes", "Fix Crashes")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: i18nc("@info about page fix crashes section, rich text", "<ol><li>Remove <i>WallpaperSource</i> line in <b>~/.config/plasma-org.kde.plasma.desktop-appletsrc</b></li><li>Restart KDE</li></ol>")
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            text: i18nc("@label about page section multi-monitor", "Multi-monitor")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: i18nc("@info about page multi-monitor section, rich text", "<p>Each screen has its own desktop (a Plasma <i>containment</i>) and its own Wallpaper Engine settings. To set a different wallpaper per screen:</p><ol><li>Right-click the desktop you want to change → <b>Configure Desktop and Wallpaper…</b></li><li>Pick a wallpaper from the <b>Wallpapers</b> or <b>Videos</b> tab; click <b>Apply</b>.</li><li>Repeat on each screen.</li></ol><p><b>Tip:</b> if both screens always change together, your screens are sharing one desktop. Open <i>System Settings → Workspace → Workspace Behavior → Virtual Desktops</i> (or right-click the panel → <i>Manage Panels and Desktops</i>) and ensure each screen has its own desktop.</p><p>Per-screen scope also covers the background color, display mode, mute/volume, and per-wallpaper user properties.</p><p>Playlists with an active <i>Active Playlist</i> are intentionally synchronized across screens — every screen cycles to the same wallpaper on the same tick.</p>")
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            id: githubRow
            icon: '../../images/github.svg'
            text: i18nc("@label about page section github repo", "Github Repo")
            text_color: Kirigami.Theme.textColor
            // Keyboard reachable + visible focus + tooltip showing the URL.
            // Previously a bare MouseArea: no Tab focus, no Space/Enter
            // activation, no hint where the link goes.
            activeFocusOnTab: true
            Accessible.role: Accessible.Link
            Accessible.name: i18nc("@info:whatsthis accessible name for github link", "Open Github repository")
            Accessible.description: Common.repo_url
            Keys.onSpacePressed: Qt.openUrlExternally(Common.repo_url)
            Keys.onReturnPressed: Qt.openUrlExternally(Common.repo_url)
            Keys.onEnterPressed: Qt.openUrlExternally(Common.repo_url)
            ToolTip.text: Common.repo_url
            ToolTip.visible: ghLinkArea.containsMouse || githubRow.activeFocus
            ToolTip.delay: 500
            // Focus ring overlay — same accent as Kirigami highlight.
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: Kirigami.Theme.highlightColor
                border.width: 2
                radius: 3
                visible: githubRow.activeFocus
                z: 99
            }
            MouseArea {
                id: ghLinkArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    githubRow.forceActiveFocus();
                    Qt.openUrlExternally(Common.repo_url);
                }
            }
        }

        OptionItem {
            text: i18nc("@label about page section version", "Version")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/tag.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    // Live HTML composition: keep the structural rich-text outside
                    // i18n() so translators see only user-facing pieces.
                    text: {
                        const warn = plugin_info.version === "-"
                            ? "<br><b>" + i18nc("@info native plugin lib not loaded warning",
                                                 "warning: Native plugin lib not loaded — version unavailable")
                              + "</b>"
                            : "";
                        return "<ul>"
                            + "<li>" + i18nc("@info version row plugin qml, %1=version",
                                              "plugin (qml): %1", plugin_info.version) + "</li>"
                            + "<li>" + i18nc("@info version row plugin lib, %1=version",
                                              "plugin (lib): %1", plugin_info.version) + "</li>"
                            + warn
                            + "<li>" + i18nc("@info version row kde, %1=version",
                                              "kde: %1", Qt.application.version) + "</li>"
                            + "<li>" + i18nc("@info version row file helper backend",
                                              "file helper: native") + "</li>"
                            + "</ul>";
                    }
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            id: diagnosticRow
            text: i18nc("@label about page section diagnostic bundle", "Diagnostic bundle")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'

            // Where saveBundle() put the archive, kept until the save-as
            // dialog comes back with a destination to copy it to.
            property string bundlePath: ""

            actor: Button {
                text: i18nc("@action:button save diagnostic bundle", "Save diagnostic bundle...")
                onClicked: {
                    diagnosticRow.bundlePath = diagnostics.saveBundle();
                    if (diagnosticRow.bundlePath) {
                        diagnosticStatus.text = "";
                        // Pre-select the bundle's own filename so the picker
                        // opens on it and the user only has to choose a folder.
                        saveBundleDialog.selectedFile = localFileUrl(diagnosticRow.bundlePath);
                        saveBundleDialog.open();
                    } else {
                        console.warn("[wek-diag] Bundle creation failed:",
                                     diagnostics.lastError());
                        diagnosticStatus.text = i18nc("@info diagnostic bundle creation failed, %1=reason",
                                                      "Could not create bundle: %1",
                                                      diagnostics.lastError());
                    }
                }
            }

            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: i18nc("@info diagnostic bundle help text", "Collects journal, GPU info, plugin environment, and redacted config into a single archive you can attach to a GitHub issue. Your home path is redacted to &lt;HOME&gt; before saving; review the bundle before posting publicly.")
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
                Text {
                    id: diagnosticStatus
                    Layout.fillWidth: true
                    color: Kirigami.Theme.textColor
                    text: ""
                    visible: text !== ""
                    wrapMode: Text.Wrap
                    // Plain text: the reasons carry filesystem paths and raw
                    // tar stderr, which rich text would mangle.
                    textFormat: Text.PlainText
                }
            }
        }

        OptionItem {
            text: i18nc("@label about page section lib checking", "Lib Checking")
            text_color: Kirigami.Theme.textColor
            icon: '../../images/checkmark.svg'
            contentBottom: ListView {
                implicitHeight: contentItem.childrenRect.height

                model: ListModel {}
                clip: false
                property var modelraw: {
                    const _model = [
                        {
                            ok: libcheck.qtwebchannel,
                            name: i18nc("@item lib checking row qtwebchannel", "qtwebchannel (qml) (for web)")
                        },
                        {
                            ok: libcheck.wallpaper,
                            name: i18nc("@item lib checking row plugin lib", "plugin lib (for scene,mpv)")
                        }
                    ];
                    return _model;
                }
                onModelrawChanged: {
                    this.model.clear();
                    this.modelraw.forEach((el) => {
                        this.model.append(el);
                    });
                }
                delegate: CheckBox {
                    text: name
                    checked: ok
                    enabled: false
                    contentItem: Text {
                        text: parent.text
                        color: Kirigami.Theme.disabledTextColor
                        leftPadding: parent.indicator.width + parent.spacing
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
