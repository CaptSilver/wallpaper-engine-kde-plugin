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

    // Diagnostic-bundle helpers — non-visual children of the Flickable so
    // the OptionGroup below stays a clean list of OptionItem rows.  The
    // WekDiagnostics QObject collects the bundle; FileDialog presents the
    // save-as picker after a successful bundle create.
    WekDiagnostics { id: diagnostics }
    FileDialog {
        id: saveBundleDialog
        title: "Save diagnostic bundle as..."
        fileMode: FileDialog.SaveFile
        nameFilters: ["Tar gzip (*.tar.gz)"]
    }
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
            text: 'Requirements'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'

            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <ol>
                        <li><i>Wallpaper Engine</i> installed on Steam</li>
                        <li>Subscribe to some wallpapers on the Workshop</li>
                        <li>Select the <i>steamlibrary</i> folder on the Wallpapers tab of this plugin
                            <ul>
                                <li>The <i>steamlibrary</i> which contains the <i>steamapps</i> folder
                                    <ul>
                                        <li>This is usually <i>~/.local/share/Steam</i> by default</li>
                                    </ul>
                                </li>
                                <li><i>Wallpaper Engine</i> needs to be installed in this <i>steamlibrary</i></li>
                            </ul>
                        </li>
                        </ol>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            visible: libcheck.wallpaper

            text: 'Fix Crashes'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <ol>
                        <li>Remove <i>WallpaperSource</i> line in <b>~/.config/plasma-org.kde.plasma.desktop-appletsrc</b></li>
                        <li>Restart KDE</li>
                        </ol>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            text: 'Multi-monitor'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <p>Each screen has its own desktop (a Plasma
                        <i>containment</i>) and its own Wallpaper Engine
                        settings. To set a different wallpaper per
                        screen:</p>
                        <ol>
                        <li>Right-click the desktop you want to change
                            → <b>Configure Desktop and Wallpaper…</b></li>
                        <li>Pick a wallpaper from the <b>Wallpapers</b>
                            or <b>Videos</b> tab; click <b>Apply</b>.</li>
                        <li>Repeat on each screen.</li>
                        </ol>
                        <p><b>Tip:</b> if both screens always change
                        together, your screens are sharing one desktop.
                        Open <i>System Settings → Workspace → Workspace
                        Behavior → Virtual Desktops</i> (or right-click
                        the panel → <i>Manage Panels and Desktops</i>)
                        and ensure each screen has its own desktop.</p>
                        <p>Per-screen scope also covers the background
                        color, display mode, mute/volume, and
                        per-wallpaper user properties.</p>
                        <p>Playlists with an active <i>Active Playlist</i>
                        are intentionally synchronized across screens —
                        every screen cycles to the same wallpaper on the
                        same tick.</p>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }
        OptionItem {
            id: githubRow
            icon: '../../images/github.svg'
            text: 'Github Repo'
            text_color: Kirigami.Theme.textColor
            // Keyboard reachable + visible focus + tooltip showing the URL.
            // Previously a bare MouseArea: no Tab focus, no Space/Enter
            // activation, no hint where the link goes.
            activeFocusOnTab: true
            Accessible.role: Accessible.Link
            Accessible.name: "Open Github repository"
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
            text: 'Version'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/tag.svg'
            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: `
                        <ul>
                        <li>plugin (qml): ${plugin_info.version}</li>
                        <li>plugin (lib): ${plugin_info.version}</li>
                        ${plugin_info.version === "-" ? "<br><b>warning: Native plugin lib not loaded — version unavailable</b>" : ""}
                        <li>kde: ${Qt.application.version}</li>
                        <li>file helper: native</li>
                        </ul>
                    `
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            text: 'Diagnostic bundle'
            text_color: Kirigami.Theme.textColor
            icon: '../../images/information-outline.svg'

            actor: Button {
                text: "Save diagnostic bundle..."
                onClicked: {
                    const path = diagnostics.saveBundle();
                    if (path) {
                        // Open a save-as dialog so the user can move the bundle
                        // out of the cache dir.  Default-selected name is the
                        // bundle's filename.
                        saveBundleDialog.currentFile = "file://" + path;
                        saveBundleDialog.open();
                    } else {
                        console.warn("[wek-diag] Bundle creation failed:",
                                     diagnostics.lastError());
                        // Once GAP-5 has fully landed the renderer surface
                        // could fire notifier.backendUnavailable("Diagnostics",
                        // lastError) here.
                    }
                }
            }

            contentBottom: ColumnLayout {
                Text {
                    Layout.fillWidth: true
                    color: Kirigami.Theme.disabledTextColor
                    text: "Collects journal, GPU info, plugin environment, and "
                        + "redacted config into a single archive you can attach to a "
                        + "GitHub issue. Your home path is redacted to &lt;HOME&gt; "
                        + "before saving; review the bundle before posting publicly."
                    wrapMode: Text.Wrap
                    textFormat: Text.RichText
                }
            }
        }

        OptionItem {
            text: 'Lib Checking'
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
                            name: "qtwebchannel (qml) (for web)"
                        },
                        {
                            ok: libcheck.wallpaper,
                            name: "plugin lib (for scene,mpv)"
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
