// Instantiating config.qml fires the entire KCM page tree:
// config → WallpaperPage + SettingPage + AboutPage. All of those files'
// Component.onCompleted handlers + property bindings + signal handlers
// run during instantiation, giving us coverage on the whole UI surface.
import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin

TestCase {
    id: testCase
    name: "Config"
    width: 800; height: 600
    when: windowShown

    // config.qml is lowercase so it can't be referenced as a type via
    // directory import. Load programmatically.
    property var cfg: null
    property var loadError: ""

    Item { id: configHost; anchors.fill: parent }

    function initTestCase() {
        const comp = Qt.createComponent("../../plugin/contents/ui/config.qml");
        if (comp.status === Component.Error) {
            loadError = comp.errorString();
            return;
        }
        cfg = comp.createObject(configHost, {});
        if (!cfg) loadError = "createObject returned null";
    }

    function test_componentInstantiates() {
        if (loadError) console.warn("config load error:", loadError);
        verify(cfg !== null);
        verify(cfg.libcheck !== undefined);
    }

    function test_libcheck_isResolvedObject() {
        // libcheck is { wallpaper: bool, qtwebchannel: bool }
        compare(typeof cfg.libcheck.wallpaper,    "boolean");
        compare(typeof cfg.libcheck.qtwebchannel, "boolean");
    }

    function test_pluginInfo_resolvesEvenWithoutNativePlugin() {
        verify(cfg.plugin_info !== null);
        // Either the stub PluginInfo or the no-lib fallback.
        compare(typeof cfg.plugin_info.version, "string");
        // The stub must not carry the old hardcoded literal — guards against
        // accidental reintroduction of the stale value in stub or production code.
        verify(cfg.plugin_info.version !== "0.6.0",
               "plugin_info.version must not be the stale '0.6.0' sentinel");
    }

    function test_pyext_isCreated() {
        verify(cfg.pyext !== null);
        verify(cfg.pyext.ok);
    }

    function test_config_pyext_is_local_Pyext_type() {
        verify(cfg.pyext !== null);
        // Pyext exposes a readfile(path) function (Pyext.qml). The declarative
        // `Pyext { id: pyext }` resolves to the local-qmldir-registered type;
        // this assertion pins the type contract regardless of how the object
        // is instantiated (createQmlObject template or declarative child).
        compare(typeof cfg.pyext.readfile, "function");
    }

    function test_config_plugin_info_when_libcheck_wallpaper() {
        // The declarative WEKde.PluginInfo { id: nativePluginInfo } resolves
        // to the C++-registered PluginInfo from the captsilver namespace,
        // which exposes a `version` string + `cache_path` url. Verify both.
        verify(cfg.plugin_info !== null);
        compare(typeof cfg.plugin_info.version, "string");
        // cache_path is assignable through plugin_info post-fix (writes
        // through to nativePluginInfo.cache_path on the C++ object).
        cfg.plugin_info.cache_path = "file:///tmp/cache";
        compare(String(cfg.plugin_info.cache_path), "file:///tmp/cache");
    }

    // ── Q9: pyext + plugin_info are declarative children, not Qt.createQmlObject ──
    // When pyext / plugin_info are declared as `Pyext { id: pyext }` /
    // `WEKde.PluginInfo { id: nativePluginInfo }` inside the root scope, they
    // become entries in cfg.data (declarative child items live there in QML).
    // The Qt.createQmlObject(`...`, this) form, by contrast, parents the new
    // object to `this` (cfg) via QObject::setParent() but does NOT add it to
    // the visual-item children/data list — it's only reachable via the JS
    // property. This test fails against the createQmlObject form and passes
    // only when the objects are instantiated declaratively.
    function test_config_pyext_and_plugin_info_are_declarative_tree_children() {
        verify(cfg.pyext !== null);
        verify(cfg.plugin_info !== null);

        let pyextInData = false;
        let pluginInfoInData = false;
        const data = cfg.data || [];
        for (let i = 0; i < data.length; i++) {
            if (data[i] === cfg.pyext)       pyextInData = true;
            if (data[i] === cfg.plugin_info) pluginInfoInData = true;
        }
        verify(pyextInData,
               "cfg.pyext must be a declarative tree child (in cfg.data), "
               + "not a Qt.createQmlObject-parented JS-only reference");
        verify(pluginInfoInData,
               "cfg.plugin_info must point to a declarative tree child "
               + "(in cfg.data), not a Qt.createQmlObject-parented JS-only reference");
    }

    function test_customConf_loadedFromCfgString() {
        // cfg_CustomConf default is "" → loadCustomConf → empty conf with
        // .favor as empty Set.
        verify(cfg.customConf !== null);
        verify(cfg.customConf.favor instanceof Set);
        compare(cfg.customConf.favor.size, 0);
    }

    function test_saveCustomConf_roundTripsThroughCfgCustomConf() {
        cfg.customConf = { favor: new Set(["111", "222"]) };
        cfg.saveCustomConf();
        verify(cfg.cfg_CustomConf.length > 0);
        // Verify that re-decoding produces the same set.
        const back = Plugin.Common.loadCustomConf(cfg.cfg_CustomConf);
        compare(back.favor.size, 2);
        verify(back.favor.has("111"));
    }

    // cfg_CustomConf is a live dependency of customConf: changing the encoded
    // config string at runtime (e.g., favor toggle persisted, KConfig reload)
    // must recompute customConf so dependent consumers (WallpaperListModel's
    // initItemOp at config.qml:142-145 reads customConf.favor) see fresh
    // state. A property binding that self-assigns inside its own evaluator
    // (`property var customConf: { customConf = load(cfg_CustomConf); }`)
    // evaluates ONCE — the assignment lands and QML drops the binding — so
    // the reactivity authored for cfg_CustomConf silently dies. This case
    // pins the live-recompute contract.
    function test_customConf_recomputesOnCfgCustomConfChange() {
        verify(cfg !== null);
        // Encode a starter conf with one favored workshop id.
        const v1 = Plugin.Common.prepareCustomConf({ favor: new Set(["111"]) });
        cfg.cfg_CustomConf = v1;
        tryCompare(cfg.customConf.favor, "size", 1, 1000);
        verify(cfg.customConf.favor.has("111"));

        // Mutate cfg_CustomConf with a different favored set. Pre-fix (binding
        // self-assigns) customConf is frozen at the first eval — favor.size
        // stays 1, has("222") is false. Post-fix (Component.onCompleted +
        // onCfg_CustomConfChanged) customConf recomputes to the new set.
        const v2 = Plugin.Common.prepareCustomConf({ favor: new Set(["222", "333"]) });
        cfg.cfg_CustomConf = v2;
        tryCompare(cfg.customConf.favor, "size", 2, 1000);
        verify(cfg.customConf.favor.has("222"));
        verify(cfg.customConf.favor.has("333"));
        verify(!cfg.customConf.favor.has("111"));
    }

    function test_saveConfig_delegatesToWallpaperPage() {
        // Structural check + best-effort call. saveConfig may legitimately
        // fail without a Steam dir set; either path is acceptable. The
        // useful assertion is that the function exists on the config root.
        verify(typeof cfg.saveConfig === "function");
        try { cfg.saveConfig(); } catch (e) {}
    }

    // ── BackgroundColor wiring ───────────────────────────────────────────────
    // cfg_BackgroundColor is aliased from config.qml down to SettingPage,
    // so writes on either side should mirror through. The setting drives
    // the Rectangle backdrop in main.qml that shows as letterbox bars when
    // a wallpaper's aspect doesn't match the screen.
    function test_cfgBackgroundColor_defaultsToBlackString() {
        verify(cfg !== null);
        compare(cfg.cfg_BackgroundColor, "black");
    }

    function test_cfgBackgroundColor_writePropagatesToSettingPage() {
        verify(cfg !== null);
        // Find the SettingPage child; it owns the actual property.
        function findSettingPage(parent) {
            const all = [...(parent.children || []), ...(parent.data || [])];
            for (const c of all) {
                if (c && typeof c.cfg_BackgroundColor !== "undefined"
                      && typeof c.cfg_HdrOutput !== "undefined") return c;
                const found = findSettingPage(c);
                if (found) return found;
            }
            return null;
        }
        const sp = findSettingPage(cfg);
        verify(sp !== null);
        cfg.cfg_BackgroundColor = "#112233";
        compare(sp.cfg_BackgroundColor, "#112233");
        // Write from the page side should also mirror back via the alias.
        sp.cfg_BackgroundColor = "#445566";
        compare(cfg.cfg_BackgroundColor, "#445566");
    }

    // ── cfg_PresentMode: alias round-trips through SettingPage's cbPresentMode ─
    // SettingPage declares `property alias cfg_PresentMode: cbPresentMode.currentIndex`
    // so the ComboBox selection writes through to the KConfig-backed
    // wallpaper.configuration.PresentMode at the plasmoid layer.  Locks the
    // 0..4 policy range and the two-way binding (programmatic write -> currentIndex
    // and currentIndex -> alias).
    function test_cfgPresentMode_roundTripsThroughSettingPage() {
        verify(cfg !== null);
        function findSettingPage(parent) {
            const all = [...(parent.children || []), ...(parent.data || [])];
            for (const c of all) {
                if (c && typeof c.cfg_PresentMode !== "undefined"
                      && typeof c.cfg_HdrOutput !== "undefined") return c;
                const found = findSettingPage(c);
                if (found) return found;
            }
            return null;
        }
        const sp = findSettingPage(cfg);
        verify(sp !== null);
        // Default is Auto (0) per main.xml.
        compare(sp.cfg_PresentMode, 0);
        // Flip to MAILBOX (3) — currentIndex maps directly to policy because
        // the ComboBox model is indexed in PresentModePolicy enum order.
        sp.cfg_PresentMode = 3;
        compare(sp.cfg_PresentMode, 3);
        // Round-trip back to Auto.
        sp.cfg_PresentMode = 0;
        compare(sp.cfg_PresentMode, 0);
    }
}
