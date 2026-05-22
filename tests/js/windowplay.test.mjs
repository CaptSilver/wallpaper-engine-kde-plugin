import { test } from 'node:test';
import assert from 'node:assert/strict';

import { PauseMode, countWindows, shouldPlay } from '../../plugin/contents/ui/js/windowplay.mjs';

// Window descriptor helper: defaults everything false, override per case.
// Matches the shape WindowModel.qml builds from tasksModel.data(idx, role):
//   { isMinimized, isMaximized, isFullScreen, isActive }
const w = (o = {}) => ({
    isMinimized: false, isMaximized: false, isFullScreen: false, isActive: false, ...o,
});

// ── enum values must match Common.qml's PauseMode declaration order ──────────
test('PauseMode integer values match the Common.qml enum order', () => {
    assert.equal(PauseMode.Never, 0);
    assert.equal(PauseMode.Any, 1);
    assert.equal(PauseMode.Max, 2);
    assert.equal(PauseMode.Focus, 3);
    assert.equal(PauseMode.FocusOrMax, 4);
    assert.equal(PauseMode.FullScreen, 5);
});

// ── empty model: every mode plays (no window satisfies any predicate) ────────
test('empty model plays in every mode (including Never and unknown)', () => {
    for (const m of [0, 1, 2, 3, 4, 5, 99]) assert.equal(shouldPlay([], m), true);
});

// ── Any: pause iff a non-minimized window exists ─────────────────────────────
test('Any: one non-minimized window pauses', () => {
    assert.equal(shouldPlay([w()], PauseMode.Any), false);
});
test('Any: a single minimized window plays (minimized excluded)', () => {
    assert.equal(shouldPlay([w({ isMinimized: true })], PauseMode.Any), true);
});

// ── Max: pause iff a non-minimized maximized-or-fullscreen window exists ──────
test('Max: a maximized window pauses', () => {
    assert.equal(shouldPlay([w({ isMaximized: true })], PauseMode.Max), false);
});
test('Max: a fullscreen window pauses (max counts fullscreen)', () => {
    assert.equal(shouldPlay([w({ isFullScreen: true })], PauseMode.Max), false);
});
test('Max: a plain non-minimized window plays', () => {
    assert.equal(shouldPlay([w()], PauseMode.Max), true);
});
test('Max: a maximized-but-minimized window plays (minimized excluded first)', () => {
    assert.equal(shouldPlay([w({ isMaximized: true, isMinimized: true })], PauseMode.Max), true);
});

// ── Focus: pause iff a non-minimized active window exists ─────────────────────
test('Focus: an active window pauses', () => {
    assert.equal(shouldPlay([w({ isActive: true })], PauseMode.Focus), false);
});
test('Focus: an active-but-minimized window plays', () => {
    assert.equal(shouldPlay([w({ isActive: true, isMinimized: true })], PauseMode.Focus), true);
});
test('Focus: non-active windows play', () => {
    assert.equal(shouldPlay([w(), w()], PauseMode.Focus), true);
});

// ── FocusOrMax: pause iff active OR maximized (non-minimized) ──────────────────
test('FocusOrMax: active-only pauses', () => {
    assert.equal(shouldPlay([w({ isActive: true })], PauseMode.FocusOrMax), false);
});
test('FocusOrMax: maximized-only pauses', () => {
    assert.equal(shouldPlay([w({ isMaximized: true })], PauseMode.FocusOrMax), false);
});
test('FocusOrMax: neither active nor maximized plays', () => {
    assert.equal(shouldPlay([w(), w()], PauseMode.FocusOrMax), true);
});

// ── FullScreen: pause iff a non-minimized fullscreen window exists ────────────
test('FullScreen: a fullscreen window pauses', () => {
    assert.equal(shouldPlay([w({ isFullScreen: true })], PauseMode.FullScreen), false);
});
test('FullScreen: a maximized-not-fullscreen window plays (distinguishes Max from FullScreen)', () => {
    assert.equal(shouldPlay([w({ isMaximized: true })], PauseMode.FullScreen), true);
});
test('FullScreen: a fullscreen-but-minimized window plays', () => {
    assert.equal(shouldPlay([w({ isFullScreen: true, isMinimized: true })], PauseMode.FullScreen), true);
});

// ── countWindows early-out invariants (pin the optimization, not just decision)
test('countWindows(Any) skips max/full/active work (all stay 0)', () => {
    const c = countWindows([w({ isActive: true, isMaximized: true, isFullScreen: true })], PauseMode.Any);
    assert.equal(c.notMin, 1);
    assert.equal(c.max, 0);
    assert.equal(c.full, 0);
    assert.equal(c.active, 0);
});
test('countWindows(Focus) counts active but skips max/full', () => {
    const c = countWindows([w({ isActive: true, isMaximized: true, isFullScreen: true })], PauseMode.Focus);
    assert.equal(c.notMin, 1);
    assert.equal(c.active, 1);
    assert.equal(c.max, 0);
    assert.equal(c.full, 0);
});

// ── mixed realistic set across all six modes (integration-shaped equivalence) ─
test('mixed set (active+maximized, fullscreen, minimized) matches every mode', () => {
    const set = [
        w({ isActive: true, isMaximized: true }),  // counts: notMin, active, max
        w({ isFullScreen: true }),                 // counts: notMin, full, max
        w({ isMinimized: true, isMaximized: true }), // excluded (minimized)
    ];
    assert.equal(shouldPlay(set, PauseMode.Any), false);        // 2 non-min
    assert.equal(shouldPlay(set, PauseMode.Max), false);        // 2 max-or-fs
    assert.equal(shouldPlay(set, PauseMode.Focus), false);      // 1 active
    assert.equal(shouldPlay(set, PauseMode.FocusOrMax), false); // active or max
    assert.equal(shouldPlay(set, PauseMode.FullScreen), false); // 1 fullscreen
    assert.equal(shouldPlay(set, PauseMode.Never), true);       // never pauses
});
