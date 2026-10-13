// Qt unloads a QML plugin when the engine that imported it is torn down
// (System Settings closing its wallpaper page). The plugin starts its own
// threads -- PulseAudio capture, file-scan pools -- that can outlive that, and
// a thread still running code in an unmapped library crashes the host. The
// plugin links with -z nodelete so the library stays mapped.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

test('the QML plugin links with -z nodelete', () => {
    const cmake = readFileSync(new URL('../../src/CMakeLists.txt', import.meta.url), 'utf8');
    assert.match(cmake, /target_link_options\(\s*\$\{PROJECT_NAME\}\s+PRIVATE[^)]*-Wl,-z,nodelete/);
});
