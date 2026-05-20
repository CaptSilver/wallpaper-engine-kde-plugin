// Headless stand-in for the Plasma WallpaperItem root type. Production main.qml
// is `WallpaperItem { Rectangle { id: background; anchors.fill: parent ... } }`.
// The real type pulls in Plasma containment/applet runtime that doesn't init
// cleanly offscreen; a plain Item gives deterministic geometry. Only main.qml
// imports org.kde.plasma.plasmoid, so shadowing it in _stubs is safe.
import QtQuick
Item { }
