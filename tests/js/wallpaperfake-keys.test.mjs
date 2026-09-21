// plugin/contents/config/main.xml and tests/qml/Helpers/WallpaperFake.qml both hand-list
// the same set of KConfigXT entry names. Nothing else compares them, so a key present in
// one and absent from the other reads back silently wrong at runtime: QML resolves the
// missing `wallpaper.configuration.X` to `undefined`, which a typed property (int/bool)
// can't accept, so it keeps its C++ default instead of main.xml's declared one, logged
// only as a QML warning. The failOnWarning patterns in tests/qml/tst_main_*.qml catch
// that warning at runtime; this check catches the drift itself.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mainXmlPath = join(repoRoot, 'plugin', 'contents', 'config', 'main.xml');
const fakePath = join(repoRoot, 'tests', 'qml', 'Helpers', 'WallpaperFake.qml');

function mainXmlKeys() {
    const text = readFileSync(mainXmlPath, 'utf8');
    return new Set([...text.matchAll(/<entry name="([^"]+)"/g)].map((m) => m[1]));
}

function fakeConfigKeys() {
    // A key on a commented-out line is not mirrored, so drop line comments first.
    const text = readFileSync(fakePath, 'utf8')
        .split('\n')
        .filter((line) => !line.trimStart().startsWith('//'))
        .join('\n');
    return new Set([...text.matchAll(/"([A-Z][A-Za-z]+)":/g)].map((m) => m[1]));
}

test('WallpaperFake.qml mirrors every main.xml config key', () => {
    const xmlKeys = mainXmlKeys();
    const fakeKeys = fakeConfigKeys();

    const missingFromFake = [...xmlKeys].filter((k) => !fakeKeys.has(k)).sort();
    const extraInFake = [...fakeKeys].filter((k) => !xmlKeys.has(k)).sort();

    assert.deepEqual(missingFromFake, [],
        `main.xml keys missing from WallpaperFake.qml: ${missingFromFake.join(', ')}`);
    assert.deepEqual(extraInFake, [],
        `WallpaperFake.qml keys not in main.xml: ${extraInFake.join(', ')}`);
});
