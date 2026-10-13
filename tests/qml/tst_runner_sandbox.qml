import QtQuick
import QtCore
import QtTest

// Some suites drive real plugin types (PlaylistManager writes playlists.json)
// whenever the real module wins over the stubs on the import path, e.g. on a
// box with the plugin installed. The runner must keep every such write out
// of the user's real config.
TestCase {
    name: "RunnerSandbox"

    function test_configLocationIsSandboxed() {
        const cfg = StandardPaths.writableLocation(StandardPaths.GenericConfigLocation).toString();
        verify(cfg.indexOf("/wek-test-sandbox/") >= 0, "config resolves outside the sandbox: " + cfg);
    }

    function test_dataLocationIsSandboxed() {
        const data = StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString();
        verify(data.indexOf("/wek-test-sandbox/") >= 0, "data resolves outside the sandbox: " + data);
    }
}
