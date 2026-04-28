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
    function test_onAcceptedHandlerCopiesSelectedColor() {
        function findColorDialog(parent) {
            const all = [...(parent.children || []), ...(parent.data || [])];
            for (const c of all) {
                if (c && typeof c.selectedColor !== "undefined" && typeof c.accepted === "function") return c;
            }
            return null;
        }
        const dlg = findColorDialog(btn);
        verify(dlg !== null);
        dlg.selectedColor = Qt.rgba(1, 0, 0, 1);
        dlg.accepted(); // emit the signal — onAccepted: in QML fires
        compare(btn.colorValue.toString().toLowerCase(), "#ff0000");
    }
}
