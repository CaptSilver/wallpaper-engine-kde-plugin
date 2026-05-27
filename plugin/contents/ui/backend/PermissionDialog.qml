import QtQuick 2.5
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

// Wallpaper permission consent surface.  askFor(view, origin, feature, cb)
// opens the dialog; the user's choice + remember-checkbox state are
// forwarded to cb(allow, remember).  Tests drive allow()/deny() directly
// instead of clicking through the buttons.
Item {
    id: root

    // Test/programmatic hooks.
    function allow()  { _resolve(true,  _rememberChecked); }
    function deny()   { _resolve(false, _rememberChecked); }

    property var    _cb: null
    property bool   _rememberChecked: true

    function askFor(view, origin, feature, callback) {
        _cb = callback;
        _rememberChecked = true;
        _featureLabel.text = _featureName(feature);
        _originLabel.text  = String(origin);
        _dlg.open();
    }

    function _featureName(f) {
        // Mirror WebEngineView.Feature enum subset (Qt 6).
        if (f === 1) return "your location";
        if (f === 2) return "your microphone";
        if (f === 3) return "your camera";
        if (f === 4) return "your microphone and camera";
        if (f === 5) return "your mouse pointer";
        if (f === 6) return "your desktop video";
        if (f === 7) return "your desktop audio and video";
        if (f === 8) return "send notifications";
        return "feature #" + f;
    }

    function _resolve(allow, remember) {
        const cb = _cb;
        _cb = null;
        _dlg.close();
        if (cb) cb(allow, remember);
    }

    Dialog {
        id: _dlg
        modal: true
        title: "Wallpaper permission request"
        standardButtons: Dialog.NoButton

        ColumnLayout {
            spacing: 8
            Label {
                text: "This wallpaper is requesting access to:"
                wrapMode: Text.Wrap
            }
            Label {
                id: _featureLabel
                wrapMode: Text.Wrap
                font.bold: true
            }
            Label {
                id: _originLabel
                wrapMode: Text.Wrap
                font.italic: true
            }
            CheckBox {
                text: "Remember this choice for this wallpaper"
                checked: root._rememberChecked
                onCheckedChanged: root._rememberChecked = checked
            }
            RowLayout {
                spacing: 8
                Button { text: "Deny";  onClicked: root.deny() }
                Button { text: "Allow"; onClicked: root.allow() }
            }
        }
    }
}
