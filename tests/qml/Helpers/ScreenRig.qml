// One simulated monitor. Holds the fake `wallpaper` context and loads the REAL
// plugin/contents/ui/main.qml into it. main.qml's unqualified `wallpaper`
// resolves to `id: wallpaper` below via the Qt.createComponent creation-context
// chain (the same way production Scene.qml resolves `background`). main.qml is a
// lowercase file so it CANNOT be a static type — createComponent is mandatory and
// production-faithful. Set `screenGeometry` per test; `wallpaper.parent.screenGeometry`
// reads it. Mutate config via setConfig() (reassigns the whole object so bindings
// re-fire — see WallpaperFake).
import QtQuick

Item {
    id: rig
    property rect screenGeometry: Qt.rect(0, 0, 1920, 1080)
    width:  screenGeometry.width
    height: screenGeometry.height
    property var mainItem: null

    WallpaperFake {
        id: wallpaper
        anchors.fill: parent
        Component.onCompleted: rig._loadMain()
    }
    property alias ctx: wallpaper

    function _loadMain() {
        const comp = Qt.createComponent(Qt.resolvedUrl("../../../plugin/contents/ui/main.qml"));
        if (comp.status === Component.Error) {
            console.warn("ScreenRig main.qml: " + comp.errorString());
            return;
        }
        mainItem = comp.createObject(wallpaper);
        if (mainItem) mainItem.anchors.fill = wallpaper;
    }

    // Reassign the whole configuration object so `wallpaper.configuration.X`
    // bindings in main.qml re-evaluate (a single-key write would not notify).
    function setConfig(partial) {
        var c = {};
        var src = wallpaper.configuration;
        for (var k in src) c[k] = src[k];
        for (var k2 in partial) c[k2] = partial[k2];
        wallpaper.configuration = c;
    }

    function _find(node, pred) {
        if (!node) return null;
        const buckets = [node.children || [], node.data || []];
        for (const b of buckets)
            for (let i = 0; i < b.length; i++) {
                const c = b[i];
                if (c && pred(c)) return c;
                const deep = _find(c, pred);
                if (deep) return deep;
            }
        return null;
    }
    function background()         { return _find(mainItem, o => typeof o.get_opt_value === "function"); }
    function player()             { return _find(mainItem, o => typeof o.setAcceptMouse === "function"); }
    function windowModel()        { return _find(mainItem, o => typeof o.filterByScreen !== "undefined" && typeof o.modePlay !== "undefined"); }
    function powerSource()        { return _find(mainItem, o => typeof o.st_battery_state !== "undefined"); }
    function playlistController() { return _find(mainItem, o => typeof o.activePlaylistIdRead !== "undefined"); }
    function pyext()              { return _find(mainItem, o => typeof o.read_wallpaper_config === "function"); }
    function fileHelper()         { return _find(pyext(),  o => typeof o.readWallpaperConfig === "function"); }
}
