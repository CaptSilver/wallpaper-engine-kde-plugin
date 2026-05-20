import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    id: tc
    name: "Letterbox_Integration"
    when: windowShown
    width: 400; height: 300   // container; stages may exceed this (geometry-only asserts)

    // Each test spins a fresh, independently-sized stage (one "screen").
    Component {
        id: stageComp
        BackgroundStageFake {
            id: background   // backend/Scene.qml resolves unqualified `background` via creation scope
            property alias scene: sceneInner
            color: "#808080"
            displayMode: Plugin.Common.DisplayMode.Aspect
            Backend.Scene { id: sceneInner; source: "stub://scene.pkg" }
        }
    }

    function _player(stage) {
        const scene = stage.scene;
        const buckets = [scene.children || [], scene.data || []];
        for (const b of buckets)
            for (let i = 0; i < b.length; i++)
                if (b[i] && typeof b[i].setAcceptMouse === "function") return b[i];
        return null;
    }

    function _mk(w, h, aspect) {
        const stage = stageComp.createObject(tc, { width: w, height: h });
        verify(stage !== null);
        const p = _player(stage);
        verify(p !== null);
        p.nativeAspectRatio = aspect;
        return { stage: stage, p: p };
    }

    // ultrawide: 16:9 wallpaper on 21:9 screen → side bars, backdrop shows through
    function test_ultrawide_letterboxes_and_shows_backdrop() {
        const r = _mk(3440, 1440, 16 / 9);
        compare(Math.round(r.p.width), 2560);                 // 1440 * 16/9
        compare(Math.round(r.p.height), 1440);
        verify(r.p.width < r.stage.width);                    // side bars exist
        compare(Math.round(r.p.x), Math.round((r.stage.width - r.p.width) / 2)); // centred → symmetric
        compare(r.p.fillMode, 0 /* STRETCH: renderer must NOT pad */);
        verify(Qt.colorEqual(r.stage.color, "#808080"));      // bars = backdrop colour
        r.stage.destroy();
    }

    // matched aspect: fills, no bars
    function test_matched_aspect_fills_no_bars() {
        const r = _mk(1920, 1080, 16 / 9);
        compare(Math.round(r.p.width), 1920);
        compare(Math.round(r.p.height), 1080);
        verify(r.p.width >= r.stage.width);
        r.stage.destroy();
    }

    // portrait screen: top/bottom bars
    function test_portrait_letterboxes_vertically() {
        const r = _mk(1080, 1920, 16 / 9);
        compare(Math.round(r.p.width), 1080);
        compare(Math.round(r.p.height), 608);                 // 1080 / (16/9) = 607.5
        verify(r.p.height < r.stage.height);
        r.stage.destroy();
    }

    // not yet loaded (aspect 0): full-fill, ASPECTFIT graceful (no scene visible yet)
    function test_unloaded_fills_screen() {
        const r = _mk(3440, 1440, 0);
        compare(Math.round(r.p.width), 3440);
        compare(Math.round(r.p.height), 1440);
        compare(r.p.fillMode, 1 /* ASPECTFIT pre-load */);
        r.stage.destroy();
    }

    // Scale mode ignores aspect → fills + STRETCH
    function test_scale_mode_fills_and_stretches() {
        const stage = stageComp.createObject(tc, { width: 3440, height: 1440 });
        stage.displayMode = Plugin.Common.DisplayMode.Scale;
        const p = _player(stage);
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 3440);
        compare(p.fillMode, 0 /* STRETCH */);
        stage.destroy();
    }

    // Crop mode ignores aspect → fills + ASPECTCROP
    function test_crop_mode_fills_and_crops() {
        const stage = stageComp.createObject(tc, { width: 3440, height: 1440 });
        stage.displayMode = Plugin.Common.DisplayMode.Crop;
        const p = _player(stage);
        p.nativeAspectRatio = 16 / 9;
        compare(Math.round(p.width), 3440);
        compare(p.fillMode, 2 /* ASPECTCROP */);
        stage.destroy();
    }
}
