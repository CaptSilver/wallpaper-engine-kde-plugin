import QtQuick
import QtTest

TestCase {
    id: tc
    name: "IntegrationSmoke"
    when: windowShown
    width: 400; height: 300

    Item { id: host; anchors.fill: parent }

    function test_wallpaper_context_property_is_a_real_qobject() {
        verify(typeof wallpaper !== "undefined");
        verify(wallpaper.configuration !== null);
        // real uppercase Q_PROPERTY, settable + notifying
        wallpaper.configuration.DisplayMode = 2;
        compare(wallpaper.configuration.DisplayMode, 2);
        wallpaper.parent.screenGeometry = Qt.rect(0, 0, 3440, 1440);
        compare(wallpaper.parent.screenGeometry.width, 3440);
    }

    function test_mainqml_loads_with_context_property() {
        wallpaper.parent.screenGeometry = Qt.rect(0, 0, 1920, 1080);
        const comp = Qt.createComponent("../../plugin/contents/ui/main.qml");
        if (comp.status === Component.Error) console.warn(comp.errorString());
        compare(comp.status, Component.Ready);
        const m = comp.createObject(host, { width: 1920, height: 1080 });
        verify(m !== null);
        m.destroy();
    }
}
