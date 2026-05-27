import QtQuick
QtObject {
    // Production signal is `screenSaverActiveChanged(bool)` and is used as
    // the NOTIFY for the `active` property. The tests poke `active`
    // directly; the binding chain handles the notify.
    property bool active: false
    signal screenSaverActiveChanged(bool active)
}
