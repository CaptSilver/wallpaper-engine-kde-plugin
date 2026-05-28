// Stub of the C++ WekDiagnostics class for QML test harnesses.
//
// Production: collects journal / GPU / Vulkan / redacted cfg / cache
// manifest into a .tar.gz under $XDG_CACHE_HOME and returns the path.
// Tests don't have journalctl / vulkaninfo / a real cache dir; the stub
// returns a deterministic fake path so the AboutPage button is reachable
// without crashing.
import QtQuick

QtObject {
    property string lastError: ""
    property string nextBundlePath: "/tmp/wekde-stub-diag.tar.gz"
    property int    saveBundleCallCount: 0

    function saveBundle() {
        ++saveBundleCallCount;
        return nextBundlePath;
    }
}
