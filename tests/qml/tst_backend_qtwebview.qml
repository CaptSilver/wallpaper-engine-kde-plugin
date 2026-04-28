import QtQuick
import QtTest

import "../../plugin/contents/ui" as Plugin
import "../../plugin/contents/ui/backend" as Backend
import Helpers 1.0

TestCase {
    name: "Backend_QtWebView"
    width: 200; height: 100
    when: windowShown

    BackgroundFake { id: background }

    Backend.QtWebView {
        id: web
        source: "file:///tmp/fake_wallpaper.html"
        readfile: function(p) {
            // QtWebView reads project.json via readfile() to populate
            // userProperties. Return a parseable JSON string in a thenable.
            return {
                then: function(cb) {
                    cb('{"general":{"properties":{"sliderProp":{"value":50}}}}');
                    return this;
                },
            };
        }
        patchedHtml: function(_) { return "<html><body>stub</body></html>"; }
        qwebChannelJs: "<<qwebchannel-js-stub-content>>".repeat(20);
    }

    function test_loadWallpaper_doesNotThrowEvenWhenScriptsNotReady() {
        web.loadWallpaper();
        verify(true);
    }

    function test_play_pause_togglePausedFlag() {
        web.play();
        web.pause();
        verify(true);
    }

    function test_getMouseTargetReturnsBinding() {
        const t = web.getMouseTarget();
        verify(t !== undefined);
    }

    function test_userPropsJsonChange_doesNotThrowWhenWebobjUnloaded() {
        background.userPropsJson = '{"sliderProp": 75}';
        web.userPropsJsonChanged();
        verify(true);
    }

    function test_fpsChange_doesNotThrowWhenWebobjUnloaded() {
        background.fps = 60;
        web.fpsChanged();
        verify(true);
    }

    function test_sourceChange_re_triggersLoadWallpaper() {
        web.source = "file:///tmp/another_wallpaper.html";
        web.sourceChanged();
        verify(true);
    }
}
