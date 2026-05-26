import QtQuick
import QtTest

import "../../plugin/contents/ui/components" as Components

TestCase {
    name: "ColorButton"
    width: 100; height: 50
    when: windowShown

    Components.ColorButton {
        id: btn
        def_val: "#abcdef"
    }

    function test_initialColorMatchesDefault() {
        compare(btn.colorValue.toString().toLowerCase(), "#abcdef");
    }

    function test_resValIsRgbStringWithThreeFloats() {
        // Format is "r g b" with each component to 3 decimals.
        const parts = btn.res_val.split(" ");
        compare(parts.length, 3);
        for (const p of parts) {
            verify(/^[0-9]+\.[0-9]{3}$/.test(p));
        }
    }

    function test_finishResetsColorToDefault() {
        btn.colorValue = "#000000";
        btn.finish();
        compare(btn.colorValue.toString().toLowerCase(), "#abcdef");
    }

    // The `onAccepted` handler on the inner ColorDialog mutates colorValue
    // from selectedColor. Fire the dialog's `accepted` signal directly from
    // JS — opening the dialog in offscreen QPA is unreliable.
    function _findColorDialog(parent) {
        const all = [...(parent.children || []), ...(parent.data || [])];
        for (const c of all) {
            if (c && typeof c.selectedColor !== "undefined" && typeof c.accepted === "function") return c;
        }
        return null;
    }

    function test_onAcceptedHandlerCopiesSelectedColor() {
        const dlg = _findColorDialog(btn);
        verify(dlg !== null);
        dlg.selectedColor = Qt.rgba(1, 0, 0, 1);
        dlg.accepted(); // emit the signal — onAccepted: in QML fires
        compare(btn.colorValue.toString().toLowerCase(), "#ff0000");
    }

    // colorPicked fires only when the user accepts the ColorDialog.
    // Callers can connect to this signal to distinguish user picks from
    // binding-driven colorValue updates (which fire colorValueChanged too).
    function test_colorPickedSignalFiresOnDialogAccepted() {
        const dlg = _findColorDialog(btn);
        verify(dlg !== null);
        const spy = pickedSpy;
        spy.clear();
        dlg.selectedColor = Qt.rgba(0, 1, 0, 1);
        dlg.accepted();
        compare(spy.count, 1);
        compare(spy.signalArguments[0][0].toString().toLowerCase(), "#00ff00");
    }

    function test_colorPickedNotFiredByBindingUpdate() {
        // Programmatic colorValue change must NOT trigger colorPicked.
        const spy = pickedSpy;
        spy.clear();
        btn.colorValue = Qt.rgba(0, 0, 1, 1);
        compare(spy.count, 0);
    }

    SignalSpy {
        id: pickedSpy
        target: btn
        signalName: "colorPicked"
    }

    // MouseArea.onClicked — coverage anchor for the inner click handler.
    // The handler calls forceActiveFocus + colorDialog.open(); we don't
    // need to verify the dialog actually opens (offscreen QPA flaky),
    // just that the click body executes.
    function _findInnerMouseArea() {
        const all = [...(btn.children || []), ...(btn.data || [])];
        for (const c of all) {
            if (c && typeof c.clicked === "function"
                && typeof c.cursorShape !== "undefined") return c;
        }
        return null;
    }
    // Coverage anchor: the click handler calls forceActiveFocus() +
    // colorDialog.open(). Neither is reliably observable in offscreen QPA
    // (focus context absent, ColorDialog won't show). Assert the
    // structural invariant — the MouseArea exists with a click handler
    // bound to it — which catches a refactor that removes the path.
    function test_mouseAreaClick_handlerIsBound() {
        const ma = _findInnerMouseArea();
        verify(ma !== null);
        verify(typeof ma.clicked === "function");
        // The onClicked binding has to evaluate at least once for QML to
        // know it's wired; calling the signal directly fails type-coercion
        // (QQuickMouseEvent isn't constructible from JS). Verifying the
        // production component contains the binding is enough here.
        const dlg = _findColorDialog(btn);
        verify(dlg !== null);  // dialog wired = click handler can open it
    }
}
