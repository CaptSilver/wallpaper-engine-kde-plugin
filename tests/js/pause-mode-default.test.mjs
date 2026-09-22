// main.xml's KConfigXT default for PauseMode gates whether the wallpaper ever
// stops rendering behind another window out of the box. Pin it here so a
// future edit can't silently revert it back to Never.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mainXmlPath = join(repoRoot, 'plugin', 'contents', 'config', 'main.xml');

function pauseModeDefault() {
    const text = readFileSync(mainXmlPath, 'utf8');
    const m = /<entry name="PauseMode"[^>]*>[\s\S]*?<default>([^<]+)<\/default>/.exec(text);
    assert.ok(m, 'main.xml no longer has a PauseMode entry with a <default> value');
    return m[1];
}

test('PauseMode defaults to Max (2) — pause on a maximized or fullscreen window out of the box', () => {
    assert.equal(pauseModeDefault(), '2');
});
