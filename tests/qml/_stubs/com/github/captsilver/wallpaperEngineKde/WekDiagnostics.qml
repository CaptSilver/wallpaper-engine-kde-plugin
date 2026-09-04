// Stub of the C++ WekDiagnostics class for QML test harnesses.
//
// Production: collects journal / GPU / Vulkan / redacted cfg / cache
// manifest into a .tar.gz under $XDG_CACHE_HOME and returns the path,
// then copies that archive to the destination the user picks in the
// save-as dialog. Tests don't have journalctl / vulkaninfo / a real
// cache dir, so the stub returns a deterministic fake path and records
// the export call instead of touching the filesystem.
//
// lastError() is a function here because it is a Q_INVOKABLE in
// production — a plain property would let a caller's `lastError()` pass
// against the stub and throw against the real class.
import QtQuick

QtObject {
    property string nextBundlePath: "/tmp/wekde-stub-diag.tar.gz"
    property int    saveBundleCallCount: 0

    // Failure injection: set nextBundlePath to "" for a create failure or
    // exportSucceeds to false for a copy failure; nextLastError is what
    // lastError() then reports.
    property string nextLastError: ""
    property bool   exportSucceeds: true

    property int    exportBundleCallCount: 0
    property string lastExportSrc: ""
    property string lastExportDest: ""

    function lastError() {
        return nextLastError;
    }

    function saveBundle() {
        ++saveBundleCallCount;
        return nextBundlePath;
    }

    function exportBundle(srcPath, dest) {
        ++exportBundleCallCount;
        lastExportSrc = String(srcPath);
        lastExportDest = String(dest);
        return exportSucceeds;
    }
}
