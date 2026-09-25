// Plasma's wallpaper config dialog reads/persists only ROOT-level `cfg_<Key>`
// properties declared directly on plugin/contents/ui/config.qml. A settings
// page (plugin/contents/ui/page/*.qml) can declare its own `cfg_<Key>` -- as
// a plain property, or as `property alias cfg_Key: someControl.currentIndex`
// -- and that's enough for the page's own ComboBox/Switch handlers to read
// and write it, since QML resolves the unqualified identifier through the
// page's own scope or the enclosing context chain. But Plasma never sees a
// page-local declaration: it only diffs and saves cfg_<Key> properties that
// exist on config.qml's root object. A key declared only on a page either
// throws a ReferenceError (nothing declares it anywhere) or silently stops
// persisting (the page has its own copy, but the root has none to save).
//
// This walks plugin/contents/ui/page/*.qml for cfg_<Key> identifiers that
// name a real main.xml entry, and checks each one against a root-level
// declaration in config.qml.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mainXmlPath = join(repoRoot, 'plugin', 'contents', 'config', 'main.xml');
const configQmlPath = join(repoRoot, 'plugin', 'contents', 'ui', 'config.qml');
const pageDir = join(repoRoot, 'plugin', 'contents', 'ui', 'page');

// Keys that are deliberately NOT root cfg_ aliases even though a page uses
// a same-named cfg_<Key> identifier and main.xml carries a matching entry.
// ActivePlaylistId / CurrentItemIndex are ordinary properties WallpaperPage
// and PlaylistsPage declare for themselves (config.qml feeds them from
// `wallpaperConfiguration["ActivePlaylistId"]`, not a cfg_ alias) -- see the
// comment above config.qml's activePlaylistId/currentItemIndex properties.
// Extend only for another documented, deliberate case.
const ALLOWLIST = new Set(['ActivePlaylistId', 'CurrentItemIndex']);

function mainXmlKeys() {
    const text = readFileSync(mainXmlPath, 'utf8');
    return new Set([...text.matchAll(/<entry name="([^"]+)"/g)].map((m) => m[1]));
}

function pageQmlFiles() {
    return readdirSync(pageDir, { withFileTypes: true })
        .filter((entry) => entry.isFile() && entry.name.endsWith('.qml'))
        .map((entry) => join(pageDir, entry.name));
}

function pageReferencedKeys(knownKeys) {
    const text = pageQmlFiles()
        .map((f) => readFileSync(f, 'utf8'))
        .join('\n');
    const referenced = new Set();
    for (const m of text.matchAll(/\bcfg_([A-Za-z0-9_]+)\b/g)) {
        if (knownKeys.has(m[1])) referenced.add(m[1]);
    }
    return referenced;
}

// config.qml's ColumnLayout root declares its direct properties at exactly
// 4-space indent; anything nested deeper belongs to a child item, not the
// root object Plasma actually reads.
function configRootDeclaredKeys() {
    const text = readFileSync(configQmlPath, 'utf8');
    const declared = new Set();
    for (const line of text.split('\n')) {
        const m = line.match(/^ {4}(?:readonly\s+)?property\s+\S+\s+cfg_([A-Za-z0-9_]+)\b/);
        if (m) declared.add(m[1]);
    }
    return declared;
}

test('every cfg_<Key> a settings page uses has a root-level declaration in config.qml', () => {
    const knownKeys = mainXmlKeys();
    const referenced = pageReferencedKeys(knownKeys);
    const declaredAtRoot = configRootDeclaredKeys();
    const missing = [...referenced]
        .filter((key) => !ALLOWLIST.has(key) && !declaredAtRoot.has(key))
        .sort();
    assert.deepEqual(
        missing,
        [],
        `cfg_<Key> used by a settings page but not declared at config.qml's root ` +
            `(never saved by Plasma's Apply/persist path): ${missing.join(', ')}`
    );
});
