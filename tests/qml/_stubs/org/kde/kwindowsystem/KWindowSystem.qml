// Test stub — see tests/qml/_stubs/README.md for contract.
// Real source: KWindowSystem (KF6), QML singleton org.kde.kwindowsystem
// Last contract review: 2026-09-30

// Only the surface WindowModel.qml reads: the "Show Desktop" state and its
// notify signal.  Tests assign showingDesktop directly; the auto-generated
// showingDesktopChanged() drives WindowModel's Connections like the real one.
pragma Singleton
import QtQuick
QtObject {
    property bool showingDesktop: false
}
