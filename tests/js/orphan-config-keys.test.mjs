// Every main.xml KConfigXT entry needs a live reader somewhere under plugin/contents/ui --
// either a `cfg_<Key>` alias (the settings-dialog surface) or a `configuration.<Key>` /
// `configuration["<Key>"]` read (the running wallpaper). A key with neither is schema-only
// dead weight: KConfig keeps persisting it, nothing in the plugin ever looks at it. Catch
// the whole class here instead of relying on someone noticing one dead key at a time.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mainXmlPath = join(repoRoot, 'plugin', 'contents', 'config', 'main.xml');
const uiDir = join(repoRoot, 'plugin', 'contents', 'ui');

// Keys with no cfg_/configuration. reader today, on purpose. Extend this list only for a
// documented, deliberate case -- never to silence a real orphan.
//   PostProcessing: replaced by a per-wallpaper option (main.qml reads `postProcessing` via
//   get_opt_value('postprocessing', ...), never wallpaper.configuration.PostProcessing); the
//   kcfg entry stays dormant so existing configs don't churn on migration. A key read only
//   from C++ (this scan only looks at plugin/contents/ui/**/*.qml) would be a second
//   legitimate category here -- there is no such key today.
const ALLOWLIST = new Set(['PostProcessing']);

function mainXmlKeys() {
    const text = readFileSync(mainXmlPath, 'utf8');
    return [...text.matchAll(/<entry name="([^"]+)"/g)].map((m) => m[1]);
}

function walkQmlFiles(dir) {
    const out = [];
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...walkQmlFiles(full));
        else if (entry.name.endsWith('.qml')) out.push(full);
    }
    return out;
}

function readerText() {
    return walkQmlFiles(uiDir)
        .map((f) => readFileSync(f, 'utf8')
            .split('\n')
            .filter((line) => !line.trimStart().startsWith('//'))
            .join('\n'))
        .join('\n');
}

test('every main.xml config key has a live QML reader', () => {
    const text = readerText();
    const orphans = mainXmlKeys().filter((key) => {
        if (ALLOWLIST.has(key)) return false;
        const aliasRe = new RegExp(`cfg_${key}\\b`);
        const configRe = new RegExp(`configuration\\.${key}\\b|configuration\\["${key}"\\]`);
        return !(aliasRe.test(text) || configRe.test(text));
    });
    assert.deepEqual(orphans, [], `main.xml keys with no live reader: ${orphans.join(', ')}`);
});
