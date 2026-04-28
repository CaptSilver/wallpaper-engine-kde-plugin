// Runtime QML coverage tracer.
//
// `qmltestrunner` creates a fresh QQmlEngine per .qml test file, so a
// singleton accumulating state across files doesn't work — each file gets
// its own Cov instance. Instead we emit `__COV_TICK__:<key>` to stderr the
// first time a key is seen *within an engine*; report.py unions across
// all emissions in the runlog.
pragma Singleton
import QtQuick

QtObject {
    id: root

    // Per-engine dedup so a hot function only emits once per test file.
    property var _seen: ({})

    function tick(key) {
        if (root._seen[key] === undefined) {
            root._seen[key] = true;
            console.warn("__COV_TICK__:" + key);
        }
    }
}
