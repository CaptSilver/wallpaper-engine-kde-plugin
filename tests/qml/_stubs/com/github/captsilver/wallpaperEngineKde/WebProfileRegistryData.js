// Backing state for the WebProfileRegistry stub -- see
// tests/qml/_stubs/README.md for the stub's contract.
//
// This is a .pragma library JS module, not a QML property, on purpose: a
// QML property binding that calls into a JS function which reads ANOTHER
// QML property gets Qt's dependency tracker attributing that read back to
// the CALLING binding too, so a later, unrelated write to that property (a
// different view looking up a different wallpaper) marks the calling
// binding dirty and forces it to re-run. That happened here: with the
// cache and call log stored as `property var` on the singleton, one
// QtWebView's already-settled `wallpaperProfile` binding would silently
// re-evaluate -- and re-query the registry for its OWN (unchanged)
// workshopId -- purely because some OTHER view's lookup mutated the
// shared `calls` array. A .pragma library module's variables are plain JS
// state, invisible to the QML property system, so reading or writing them
// from inside profileFor() creates no such dependency. The real C++
// WebProfileRegistry was never at risk of this: a Q_INVOKABLE call is
// opaque to the QML engine's dependency tracker, which only instruments
// QML/JS property reads, not compiled C++.
.pragma library

var _profiles = ({});
var _interceptors = ({});
var _calls = [];

function storageNameFor(workshopId) {
    var wid = workshopId ? String(workshopId) : "";
    var sanitized = wid.replace(/[^A-Za-z0-9_-]/g, "");
    return "wek-wp-" + (sanitized ? sanitized : "local");
}

// Creates the (profile, interceptor) pair for a storage name on first
// request; returns the name either way. `owner` is the QObject the
// dynamically-created profile/interceptor get parented to (Qt.createQmlObject
// needs one); the QML-side caller passes its own singleton instance.
function ensure(workshopId, owner) {
    var name = storageNameFor(workshopId);
    if (_profiles[name]) return name;

    var profile = Qt.createQmlObject(
        'import QtWebEngine 1.10\n' +
        'WebEngineProfile {\n' +
        '    offTheRecord: false\n' +
        '    httpCacheType: WebEngineProfile.DiskHttpCache\n' +
        '    httpCacheMaximumSize: ' + (50 * 1024 * 1024) + '\n' +
        '}',
        owner, "WebProfileRegistryStore-profile.qml");
    profile.storageName = name;

    var interceptor = Qt.createQmlObject(
        'import com.github.captsilver.wallpaperEngineKde 1.2\n' +
        'WebUrlInterceptor {}',
        owner, "WebProfileRegistryStore-interceptor.qml");
    interceptor.installOn(profile);

    _profiles[name]     = profile;
    _interceptors[name] = interceptor;
    return name;
}

function profileFor(workshopId, owner) {
    _calls.push(workshopId === undefined || workshopId === null ? "" : String(workshopId));
    return _profiles[ensure(workshopId, owner)];
}

function interceptorFor(workshopId, owner) {
    return _interceptors[ensure(workshopId, owner)];
}

function liveProfileCount() {
    return Object.keys(_profiles).length;
}

// Test seam: a snapshot of every workshopId passed to profileFor(), in call
// order. Returned as a fresh array (not the live one) so callers can't
// accidentally mutate the log by holding onto the reference.
function callsSnapshot() {
    return _calls.slice();
}

function resetCalls() {
    _calls = [];
}
