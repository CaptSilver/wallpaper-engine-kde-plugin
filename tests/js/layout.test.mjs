import { test } from 'node:test';
import assert from 'node:assert/strict';

import { letterboxSize, fillModeFor } from '../../plugin/contents/ui/js/layout.mjs';

const A169 = 16 / 9;
const MODES = { STRETCH: 0, ASPECTFIT: 1, ASPECTCROP: 2 };

test('letterboxSize: 16:9 wallpaper on 16:9 screen fills exactly', () => {
    assert.deepEqual(letterboxSize(true, A169, 1920, 1080), { width: 1920, height: 1080 });
});
test('letterboxSize: 16:9 on 21:9 ultrawide → height-bound side bars', () => {
    assert.deepEqual(letterboxSize(true, A169, 3440, 1440), { width: 2560, height: 1440 });
});
test('letterboxSize: 16:9 on 32:9 superwide → height-bound', () => {
    assert.deepEqual(letterboxSize(true, A169, 5120, 1440), { width: 2560, height: 1440 });
});
test('letterboxSize: 16:9 on portrait 1080x1920 → width-bound top/bottom bars', () => {
    assert.deepEqual(letterboxSize(true, A169, 1080, 1920), { width: 1080, height: 607.5 });
});
test('letterboxSize: not-Aspect always full-fills regardless of aspect', () => {
    assert.deepEqual(letterboxSize(false, A169, 3440, 1440), { width: 3440, height: 1440 });
});
test('letterboxSize: aspect==0 (scene not loaded) full-fills', () => {
    assert.deepEqual(letterboxSize(true, 0, 3440, 1440), { width: 3440, height: 1440 });
});
test('letterboxSize: degenerate parent dims do not produce NaN', () => {
    assert.deepEqual(letterboxSize(true, A169, 0, 0), { width: 0, height: 0 });
});

test('fillModeFor: Aspect + loaded → STRETCH (renderer never pads)', () => {
    assert.equal(fillModeFor(true, false, A169, MODES), MODES.STRETCH);
});
test('fillModeFor: Aspect + not-loaded (aspect 0) → ASPECTFIT', () => {
    assert.equal(fillModeFor(true, false, 0, MODES), MODES.ASPECTFIT);
});
test('fillModeFor: Crop → ASPECTCROP', () => {
    assert.equal(fillModeFor(false, true, A169, MODES), MODES.ASPECTCROP);
});
test('fillModeFor: Scale → STRETCH', () => {
    assert.equal(fillModeFor(false, false, A169, MODES), MODES.STRETCH);
});
