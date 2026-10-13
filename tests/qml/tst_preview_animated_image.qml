// PreviewAnimatedImage only hands a file to AnimatedImage once its first frame
// decodes. Qt 6.12's AnimatedImage restarts a finished movie from inside the
// movie's finished signal; a multi-frame GIF whose first frame fails to decode
// then recurses until the stack overflows, which took down System Settings or
// plasmashell when a library held one broken preview.gif. On Qt 6.12 the
// broken-file case below crashes the test runner if the guard is missing.
import QtQuick
import QtTest

import "../../plugin/contents/ui/components" as Components

TestCase {
    id: tc
    name: "PreviewAnimatedImage"
    width: 200; height: 200
    when: windowShown

    Component {
        id: previewComp
        Components.PreviewAnimatedImage { width: 64; height: 64 }
    }

    function fixture(name) {
        return Qt.resolvedUrl("../fixtures/previews/" + name);
    }

    function test_a_decodable_gif_animates() {
        const p = createTemporaryObject(previewComp, tc, { source: fixture("animated.gif") });
        verify(p);
        tryCompare(p, "firstFrameDecoded", true);
        tryVerify(() => p.animation !== null && p.animation.status === Image.Ready);
    }

    function test_a_gif_whose_first_frame_fails_never_reaches_AnimatedImage() {
        const p = createTemporaryObject(previewComp, tc, { source: fixture("bad_first_frame.gif") });
        verify(p);
        tryVerify(() => p.probeStatus === Image.Error);
        wait(200);
        compare(p.animation, null);
    }

    function test_changing_the_source_to_a_broken_gif_drops_the_animation() {
        const p = createTemporaryObject(previewComp, tc, { source: fixture("animated.gif") });
        tryVerify(() => p.animation !== null);
        p.source = fixture("bad_first_frame.gif");
        tryVerify(() => p.probeStatus === Image.Error);
        compare(p.animation, null);
    }

    // AnimatedImage reads sourceSize.width 0 as a scale size of zero, decodes
    // nothing and recurses on Qt 6.12 just like a broken file; Image reads the
    // same 0 as "natural size" and decodes fine. A tile laid out at zero width
    // (before layout, or in a hidden page instance) must stay static.
    function test_a_zero_width_preview_never_reaches_AnimatedImage() {
        const p = createTemporaryObject(previewComp, tc,
                                        { source: fixture("animated.gif"), width: 0 });
        verify(p);
        wait(300);
        compare(p.animation, null);
    }

    function test_a_zero_width_preview_animates_once_it_has_a_width() {
        const p = createTemporaryObject(previewComp, tc,
                                        { source: fixture("animated.gif"), width: 0 });
        wait(200);
        compare(p.animation, null);
        p.width = 64;
        tryVerify(() => p.animation !== null && p.animation.status === Image.Ready);
    }

}
