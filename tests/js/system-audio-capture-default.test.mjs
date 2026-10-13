// main.xml's KConfigXT default for SystemAudioCapture decides whether an
// audio-reactive scene wallpaper hears real desktop sound the first time it
// runs, or only its own (usually silent) background music. Pin it here so a
// future edit can't silently revert it back to off.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const mainXmlPath = join(repoRoot, 'plugin', 'contents', 'config', 'main.xml');

function systemAudioCaptureDefault() {
    const text = readFileSync(mainXmlPath, 'utf8');
    const m = /<entry name="SystemAudioCapture"[^>]*>[\s\S]*?<default>([^<]+)<\/default>/.exec(text);
    assert.ok(m, 'main.xml no longer has a SystemAudioCapture entry with a <default> value');
    return m[1];
}

test('SystemAudioCapture defaults to true — audio-reactive wallpapers respond to real sound out of the box', () => {
    assert.equal(systemAudioCaptureDefault(), 'true');
});
