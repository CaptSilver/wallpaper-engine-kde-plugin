import QtQuick

// An animated wallpaper preview that only reaches AnimatedImage once its
// first frame decodes.
//
// Qt 6.12's AnimatedImage restarts a finished movie from inside the movie's
// own finished signal. A multi-frame GIF whose first frame fails to decode (a
// truncated or corrupt preview.gif) finishes immediately on every start, so
// the restart recurses until the stack overflows, and one such file anywhere
// in the library took down System Settings or plasmashell as soon as the
// wallpaper page opened. A plain Image decodes that same first frame with the
// same reader: it fails cleanly, and the preview stays static.
Item {
    id: root

    property url source
    property int fillMode: Image.PreserveAspectCrop
    property bool cache: false
    property bool paused: false
    property real sourceWidth: width

    readonly property int probeStatus: probe.status
    // The source whose first frame last decoded. AnimatedImage binds to this,
    // never to `source` directly: when `source` changes, the new file must
    // not reach AnimatedImage before the probe has decoded it.
    property url decodedSource
    readonly property bool firstFrameDecoded: probe.status === Image.Ready
                                              && decodedSource === source
    // The AnimatedImage, or null while (or because) the first frame has not
    // decoded. Tests read it; nothing else needs to.
    readonly property var animation: animated.item

    Image {
        id: probe
        anchors.fill: parent
        source: root.source
        sourceSize.width: root.sourceWidth
        fillMode: root.fillMode
        clip: true
        cache: false
        asynchronous: true
        smooth: true
        // Shown until the animation draws, and in its place for a file that
        // never animates.
        visible: !animated.item || animated.item.status !== Image.Ready
        onStatusChanged: if (status === Image.Ready) root.decodedSource = source
    }

    Loader {
        id: animated
        anchors.fill: parent
        active: root.firstFrameDecoded
        sourceComponent: AnimatedImage {
            source: root.decodedSource
            sourceSize.width: root.sourceWidth
            fillMode: root.fillMode
            clip: true
            cache: root.cache
            asynchronous: true
            smooth: true
            paused: root.paused
        }
    }
}
