// src/qmldir's `classname` directive names the C++ class QML instantiates when this
// module is statically linked (Q_IMPORT_QML_PLUGIN) or introspected by qmlimportscanner
// without dlopen'ing the .so. Nothing in this project's own build reads it today -- the
// module loads by dlopen'ing `plugin WallpaperEngineKde` and instantiating whatever
// class carries Q_PLUGIN_METADATA(IID QQmlExtensionInterface_iid) -- but the directive
// is still supposed to name the real QQmlExtensionPlugin subclass, and four leftover
// lines from a 2021 misreading of the directive (one classname per QML-exposed type,
// not the plugin class itself) never named it, not even once. Derive the expected name
// from plugin.cpp instead of hardcoding it so a future rename can't drift silently again.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const qmldirPath = join(repoRoot, 'src', 'qmldir');
const pluginCppPath = join(repoRoot, 'src', 'plugin.cpp');

function declaredClassnames() {
    const text = readFileSync(qmldirPath, 'utf8');
    return [...text.matchAll(/^classname\s+(\S+)/gm)].map((m) => m[1]);
}

function realExtensionPluginClass() {
    const text = readFileSync(pluginCppPath, 'utf8');
    const match = text.match(/class\s+(\w+)\s*:\s*public\s+QQmlExtensionPlugin/);
    assert.ok(match,
        'src/plugin.cpp has no QQmlExtensionPlugin subclass -- did the plugin class move or get renamed?');
    return match[1];
}

test('src/qmldir names the real QQmlExtensionPlugin subclass exactly once', () => {
    const classnames = declaredClassnames();
    const real = realExtensionPluginClass();

    assert.equal(classnames.length, 1,
        `src/qmldir should carry exactly one classname line, found ${classnames.length}: ${classnames.join(', ')}`);
    assert.equal(classnames[0], real,
        `src/qmldir's classname line names '${classnames[0]}', but the real QQmlExtensionPlugin subclass is '${real}'`);
});
