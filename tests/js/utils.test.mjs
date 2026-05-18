import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
    parseJson,
    basename,
    dirname,
    trimCharR,
    strToIntArray,
    intArrayToStr,
    prettyBytes,
    fileTypeNameFilters,
    formatPropertyLabel,
} from '../../plugin/contents/ui/js/utils.mjs';

test('parseJson: valid JSON shapes', () => {
    assert.deepEqual(parseJson('{"a":1}'), { a: 1 });
    assert.deepEqual(parseJson('[1,2,3]'), [1, 2, 3]);
    assert.equal(parseJson('"hello"'), 'hello');
    assert.equal(parseJson('42'), 42);
    assert.equal(parseJson('true'), true);
    assert.equal(parseJson('null'), null);
});

test('parseJson: empty / falsy returns null', () => {
    assert.equal(parseJson(''), null);
    assert.equal(parseJson(null), null);
    assert.equal(parseJson(undefined), null);
});

test('parseJson: SyntaxError swallowed → null', () => {
    assert.equal(parseJson('{not valid}'), null);
    assert.equal(parseJson('{"a": }'), null);
    assert.equal(parseJson('[1,2,'), null);
});

test('basename: trailing path component', () => {
    assert.equal(basename('/foo/bar/baz.txt'), 'baz.txt');
    assert.equal(basename('baz.txt'), 'baz.txt');
    assert.equal(basename('a/b/c'), 'c');
});

test('basename: trailing slash returns empty string', () => {
    assert.equal(basename('/foo/bar/'), '');
});

test('dirname: directory portion (regression: utils.mjs#L46 referenced undefined `str`)', () => {
    assert.equal(dirname('/foo/bar/baz.txt'), '/foo/bar');
    assert.equal(dirname('a/b/c'), 'a/b');
    assert.equal(dirname('/single'), '');
});

test('dirname: no slash returns empty', () => {
    assert.equal(dirname('baz.txt'), '');
});

test('trimCharR: strips trailing instances of the given char', () => {
    assert.equal(trimCharR('foo/', '/'), 'foo');
    assert.equal(trimCharR('foo//', '/'), 'foo');
    assert.equal(trimCharR('foo///', '/'), 'foo');
    assert.equal(trimCharR('foo', '/'), 'foo');
    assert.equal(trimCharR('///', '/'), '');
});

test('strToIntArray / intArrayToStr round-trip on digit strings', () => {
    assert.deepEqual(strToIntArray('12345'), [1, 2, 3, 4, 5]);
    assert.deepEqual(strToIntArray('0'), [0]);
    assert.equal(intArrayToStr([1, 2, 3, 4, 5]), '12345');
    assert.equal(intArrayToStr([0]), '0');
});

test('prettyBytes: scales to human-readable units', () => {
    assert.equal(prettyBytes(0), '0 B');
    assert.equal(prettyBytes(1023), '1023 B');
    assert.equal(prettyBytes(1024), '1 kB');
    assert.equal(prettyBytes(1024 * 1024), '1 MB');
    assert.equal(prettyBytes(1024 ** 3), '1 GB');
});

test('prettyBytes: maxFrac controls fractional digits', () => {
    assert.equal(prettyBytes(1500, 1), '1.5 kB');
    assert.equal(prettyBytes(1500, 2), '1.46 kB');
    assert.equal(prettyBytes(1500, 0), '1 kB');
});

test('prettyBytes: negative numbers carry the sign', () => {
    assert.match(prettyBytes(-1024), /^-/);
    assert.equal(prettyBytes(-1024), '-1 kB');
});

// ── fileTypeNameFilters: WE file-property fileType → Qt FileDialog filters
test('fileTypeNameFilters: video maps to video extensions', () => {
    const f = fileTypeNameFilters('video');
    assert.equal(f.length, 2);
    assert.match(f[0], /Video files/);
    assert.match(f[0], /\*\.webm/);
    assert.match(f[0], /\*\.mp4/);
    assert.equal(f[f.length - 1], 'All files (*)');
});

test('fileTypeNameFilters: image maps to image extensions', () => {
    const f = fileTypeNameFilters('image');
    assert.match(f[0], /Image files/);
    assert.match(f[0], /\*\.png/);
    assert.match(f[0], /\*\.jpg/);
    assert.equal(f[f.length - 1], 'All files (*)');
});

test('fileTypeNameFilters: sound and audio both map to audio extensions', () => {
    const fSound = fileTypeNameFilters('sound');
    const fAudio = fileTypeNameFilters('audio');
    assert.deepEqual(fSound, fAudio);
    assert.match(fSound[0], /Audio files/);
    assert.match(fSound[0], /\*\.ogg/);
});

test('fileTypeNameFilters: unknown / missing → all-files only', () => {
    assert.deepEqual(fileTypeNameFilters(''), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(undefined), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(null), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters('xml'), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(42), ['All files (*)']);
});

test('fileTypeNameFilters: case-insensitive match', () => {
    assert.match(fileTypeNameFilters('VIDEO')[0], /Video files/);
    assert.match(fileTypeNameFilters('Image')[0], /Image files/);
    assert.match(fileTypeNameFilters('Sound')[0], /Audio files/);
});

// formatPropertyLabel — extracted from WallpaperPage.qml's inner
// _loadProps helper so the transform is unit-testable. The regex and
// underscore-split are easy Mull mutation targets.
test('formatPropertyLabel: ui_browse_properties_X_Y → "X Y"', () => {
    assert.equal(formatPropertyLabel('ui_browse_properties_brightness', 'k'),
                 'Brightness');
    assert.equal(formatPropertyLabel('ui_browse_properties_color_intensity', 'k'),
                 'Color Intensity');
    // Title-case applied per word: first char upper, rest lower.
    assert.equal(formatPropertyLabel('ui_browse_properties_MIX_AMOUNT', 'k'),
                 'Mix Amount');
});

test('formatPropertyLabel: HTML tags stripped, whitespace collapsed', () => {
    assert.equal(formatPropertyLabel('<b>Bold label</b>', 'k'), 'Bold label');
    assert.equal(formatPropertyLabel('<span>multi  </span>  <i>word</i>', 'k'),
                 'multi word');
    assert.equal(formatPropertyLabel('plain text', 'k'), 'plain text');
});

test('formatPropertyLabel: empty / whitespace / falsy → key', () => {
    assert.equal(formatPropertyLabel('', 'fallback'), 'fallback');
    assert.equal(formatPropertyLabel(null, 'fallback'), 'fallback');
    assert.equal(formatPropertyLabel(undefined, 'fallback'), 'fallback');
    // Whitespace-only after HTML strip + collapse → empty → fallback.
    assert.equal(formatPropertyLabel('   ', 'fallback'), 'fallback');
    assert.equal(formatPropertyLabel('<br>  <br>', 'fallback'), 'fallback');
});

test('formatPropertyLabel: localization prefix wins over HTML strip', () => {
    // Strings that BEGIN with the prefix bypass the HTML path entirely
    // — they're identifiers, not user text.
    assert.equal(formatPropertyLabel('ui_browse_properties_<b>nope</b>', 'k'),
                 '<b>nope</b>');
});
