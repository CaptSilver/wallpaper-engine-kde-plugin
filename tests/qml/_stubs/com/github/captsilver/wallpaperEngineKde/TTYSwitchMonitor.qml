import QtQuick
QtObject {
    // main.qml uses `onTtySwitch: { if (sleep) ... else ... }` — the
    // signal carries a `sleep` arg.
    signal ttySwitch(bool sleep)
}
