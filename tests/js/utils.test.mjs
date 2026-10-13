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
    badgeUpdated,
    evaluateCondition,
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
test('fileTypeNameFilters: video label is built from the injected list', () => {
    assert.deepEqual(fileTypeNameFilters('video', ['zzz']),
                     ['Video files (*.zzz)', 'All files (*)']);
    assert.deepEqual(fileTypeNameFilters('video', ['mp4', 'mkv']),
                     ['Video files (*.mp4 *.mkv)', 'All files (*)']);
});

test('fileTypeNameFilters: video without a list is all-files only', () => {
    assert.deepEqual(fileTypeNameFilters('video', []), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters('video'), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters('video', null), ['All files (*)']);
});

test('fileTypeNameFilters: the video list does not leak into other types', () => {
    assert.deepEqual(fileTypeNameFilters('image', ['zzz']), fileTypeNameFilters('image'));
    assert.deepEqual(fileTypeNameFilters('xml', ['zzz']), ['All files (*)']);
});

test('fileTypeNameFilters: image maps to image extensions', () => {
    const f = fileTypeNameFilters('image');
    assert.deepEqual(f, ['Image files (*.png *.jpg *.jpeg *.gif *.bmp *.webp *.tga)',
                         'All files (*)']);
});

test('fileTypeNameFilters: sound and audio both map to audio extensions', () => {
    const fSound = fileTypeNameFilters('sound');
    const fAudio = fileTypeNameFilters('audio');
    assert.deepEqual(fSound, fAudio);
    assert.deepEqual(fSound, ['Audio files (*.ogg *.mp3 *.wav *.flac *.opus *.m4a)',
                              'All files (*)']);
});

test('fileTypeNameFilters: unknown / missing → all-files only', () => {
    assert.deepEqual(fileTypeNameFilters(''), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(undefined), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(null), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters('xml'), ['All files (*)']);
    assert.deepEqual(fileTypeNameFilters(42), ['All files (*)']);
});

test('fileTypeNameFilters: case-insensitive match', () => {
    assert.match(fileTypeNameFilters('VIDEO', ['mp4'])[0], /Video files/);
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

test('formatPropertyLabel: U+3164 Hangul filler is stripped', () => {
    // Wallpaper Engine authors use U+3164 (HANGUL FILLER) as fake
    // indentation in the editor. It's category Lo, not Zs, so JS's \s
    // doesn't match it and it survives the whitespace collapse untouched.
    assert.equal(
        formatPropertyLabel('ㅤ<b><small>Album Name</small></b>', 'k'),
        'Album Name');
    // Also strip it mid-string and collapse the space left behind.
    assert.equal(formatPropertyLabel('AlbumㅤName', 'k'), 'Album Name');
});

// badgeUpdated — the "Updated since you last loaded it" dot predicate,
// extracted from WallpaperListModel.loadItemFromJson. A wallpaper badges
// ONLY if the user has loaded it before (seenVersion > 0) and Steam has
// updated it since. Never-loaded wallpapers (seenVersion 0) must NOT badge,
// or the whole library lights up — the bug this guards against marked
// 1053 of 1084 wallpapers "updated".
test('badgeUpdated: never-loaded wallpaper (seen 0) does not badge', () => {
    assert.equal(badgeUpdated(1500000000, 0), false);
    assert.equal(badgeUpdated(0, 0), false);
});

test('badgeUpdated: loaded then updated by Steam badges', () => {
    assert.equal(badgeUpdated(1700000000, 1600000000), true);
});

test('badgeUpdated: loaded and unchanged does not badge', () => {
    assert.equal(badgeUpdated(1600000000, 1600000000), false);
});

test('badgeUpdated: loaded but manifest older or missing does not badge', () => {
    assert.equal(badgeUpdated(1500000000, 1600000000), false); // older manifest
    assert.equal(badgeUpdated(0, 1600000000), false);          // no manifest entry
});

// evaluateCondition — project.json gates some properties on another
// property's live value ("condition": "mediavisualizer.value == true"). The
// grammar below was read out of the real Workshop corpus (1081 project.json
// files under 431960/), not guessed: ==, !=, <, >, <=, >=, &&, ||, unary !,
// parens, true/false/number/'string' literals and `name.value` references,
// all written with inconsistent spacing. `resolve` stands in for
// WallpaperPage's live property lookup (propChanges/propConfig, keyed by
// name) — plain object literal here since only the value matters.
test('evaluateCondition: no condition means always visible', () => {
    assert.equal(evaluateCondition('', () => { throw new Error('must not resolve'); }), true);
    assert.equal(evaluateCondition(undefined, () => { throw new Error('must not resolve'); }), true);
    assert.equal(evaluateCondition(null, () => { throw new Error('must not resolve'); }), true);
    assert.equal(evaluateCondition('   ', () => { throw new Error('must not resolve'); }), true);
});

test('evaluateCondition: simple equality against a boolean literal', () => {
    const resolve = name => ({ mediavisualizer: true })[name];
    assert.equal(evaluateCondition('mediavisualizer.value == true', resolve), true);
    assert.equal(evaluateCondition('mediavisualizer.value == false', resolve), false);
});

test('evaluateCondition: numeric equality (combo option index)', () => {
    const resolve = name => ({ type1: 2 })[name];
    assert.equal(evaluateCondition('type1.value == 2', resolve), true);
    assert.equal(evaluateCondition('type1.value == 3', resolve), false);
});

test('evaluateCondition: compound && requires every clause true', () => {
    // This wallpaper's real "Album Name" row condition.
    const resolve = name => ({ mediavisualizer: true, albumname: false })[name];
    assert.equal(evaluateCondition('mediavisualizer.value == true && albumname.value == true', resolve), false);
    const resolveBoth = name => ({ mediavisualizer: true, albumname: true })[name];
    assert.equal(evaluateCondition('mediavisualizer.value == true && albumname.value == true', resolveBoth), true);
});

test('evaluateCondition: compound || is satisfied by either clause', () => {
    const resolve = name => ({ backgroundSource: 'image' })[name];
    assert.equal(evaluateCondition("backgroundSource.value == '' || backgroundSource.value == 'image'", resolve), true);
    assert.equal(evaluateCondition("backgroundSource.value == '' || backgroundSource.value == 'video'", resolve), false);
});

test('evaluateCondition: a THIRD ||-chained clause is still parsed, not left dangling', () => {
    // Real corpus condition. This does NOT prove every clause gets
    // evaluated: a naive `left = Boolean(left) || Boolean(parseAnd())` fold
    // would skip parsing the third clause once the first two already made
    // `left` true (JS's `||` short-circuits the right-hand `parseAnd()`
    // call), leaving its tokens unconsumed and falling into the "trailing
    // tokens" catch, which fails OPEN to true. But `||` is monotonic — an
    // earlier clause is only true when the real answer is also true — so
    // that fail-open value happens to match the correct one in every case
    // this expression can produce. This test only proves the OR path
    // returns the right answer, not that it does so by genuinely evaluating
    // every clause; see the && test below for the case that tells the two
    // apart.
    const resolve = name => ({ colormode: 2 })[name];
    assert.equal(
        evaluateCondition('colormode.value == 0 || colormode.value == 1 || colormode.value == 2', resolve),
        true);
    const resolveNoMatch = name => ({ colormode: 9 })[name];
    assert.equal(
        evaluateCondition('colormode.value == 0 || colormode.value == 1 || colormode.value == 2', resolveNoMatch),
        false);
});

test('evaluateCondition: a THIRD &&-chained clause is genuinely evaluated when the first clause is false', () => {
    // Real corpus condition (nested App Dock toggles). Unlike the OR case
    // above, && only skips its right-hand clause when the LEFT side is
    // already false — which is exactly the case where the real answer is
    // also false, so a naive `left = Boolean(left) && Boolean(parseComparison())`
    // fold would short-circuit past the remaining clauses' tokens, hit the
    // "trailing tokens" catch, and fail OPEN to true: the wrong answer. This
    // is the shape that actually distinguishes a genuinely-evaluated chain
    // from a short-circuited one.
    const expr = 'appdocksettings.value == true && appdockenabled.value == true && appdockautohide.value == true';
    const resolveFirstFalse = name => ({ appdocksettings: false, appdockenabled: true, appdockautohide: true })[name];
    assert.equal(evaluateCondition(expr, resolveFirstFalse), false);
    const resolveAllTrue = name => ({ appdocksettings: true, appdockenabled: true, appdockautohide: true })[name];
    assert.equal(evaluateCondition(expr, resolveAllTrue), true);
});

test('evaluateCondition: unary negation, bare and parenthesized', () => {
    assert.equal(evaluateCondition('!audio_wireframe.value', () => false), true);
    assert.equal(evaluateCondition('!audio_wireframe.value', () => true), false);
    const resolve = name => ({ a: false, b: false, c: false })[name];
    assert.equal(evaluateCondition('!(a.value || b.value || c.value)', resolve), true);
    const resolveOne = name => ({ a: false, b: true, c: false })[name];
    assert.equal(evaluateCondition('!(a.value || b.value || c.value)', resolveOne), false);
});

test('evaluateCondition: negation binds tighter than comparison', () => {
    // Real corpus condition "!dibu.value==0" parses as (!dibu.value) == 0,
    // matching JS operator precedence, not !(dibu.value==0).
    assert.equal(evaluateCondition('!dibu.value==0', () => true), true);
    assert.equal(evaluateCondition('!dibu.value==0', () => false), false);
});

test('evaluateCondition: relational and inequality operators', () => {
    const resolve = (key, value) => name => ({ [key]: value })[name];
    assert.equal(evaluateCondition('col2Count.value >= 3', resolve('col2Count', 3)), true);
    assert.equal(evaluateCondition('col2Count.value >= 3', resolve('col2Count', 2)), false);
    assert.equal(evaluateCondition('audioreactivebokeh.value < 5', resolve('audioreactivebokeh', 4)), true);
    assert.equal(evaluateCondition('clock.value != 4', resolve('clock', 4)), false);
    assert.equal(evaluateCondition('clock.value != 4', resolve('clock', 3)), true);
});

test('evaluateCondition: a string-stored combo value compares loosely against a numeric literal', () => {
    // Real corpus: combo properties store their `value` as a STRING
    // ('"1"', '"2"', ...) even though sibling rows gate on it with a
    // NUMBER literal ("type1.value == 2"). == (not ===) is required for
    // this to work — WE itself relies on this coercion.
    const resolve = value => name => ({ type1: value })[name];
    assert.equal(evaluateCondition('type1.value == 2', resolve('1')), false);
    assert.equal(evaluateCondition('type1.value == 2', resolve('2')), true);
    assert.equal(evaluateCondition('type1.value == 3', resolve('3')), true);
});

test('evaluateCondition: whitespace around operators is optional', () => {
    // Real corpus: "effects.value == true &&darken.value == true" (no space
    // before the second clause) and "bgaudiobars.value==1" (no spaces at all).
    const resolve = name => ({ effects: true, darken: true })[name];
    assert.equal(evaluateCondition('effects.value == true &&darken.value == true', resolve), true);
    assert.equal(evaluateCondition('bgaudiobars.value==1', () => 1), true);
});

test('evaluateCondition: a bare "=" typo is read as equality', () => {
    // Real corpus condition "raineffects.value=true" — single '=', not '=='.
    assert.equal(evaluateCondition('raineffects.value=true', () => true), true);
    assert.equal(evaluateCondition('raineffects.value=true', () => false), false);
});

test('evaluateCondition: unsupported expressions fail open (row stays visible)', () => {
    // The WE-editor "self-mutating label text" hack (abuses `condition` for
    // a ternary that assigns to another property's `.text`) and a method
    // chain are both real corpus entries; neither is a boolean condition we
    // can safely evaluate without eval(), so both must not hide the row and
    // must not throw.
    assert.equal(
        evaluateCondition(
            "background_enable.value ? background_enable.text = background_enable.text.replace('a','b') : false",
            () => true),
        true);
    assert.equal(
        evaluateCondition("ruleset.value.split('/')[0].includes('0')", () => 'a/b'),
        true);
    // Unterminated string / garbage input must not throw either.
    assert.equal(evaluateCondition("broken.value == 'unterminated", () => 'x'), true);
});
