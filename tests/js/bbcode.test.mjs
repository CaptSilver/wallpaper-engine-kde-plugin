import { test } from 'node:test';
import assert from 'node:assert/strict';

import { parser } from '../../plugin/contents/ui/js/bbcode.mjs';

test('newline → <br>', () => {
    assert.equal(parser.parse('a\nb'), 'a<br>b');
});

test('[br] → <br>', () => {
    assert.equal(parser.parse('a[br]b'), 'a<br>b');
});

test('inline emphasis tags', () => {
    assert.equal(parser.parse('[b]bold[/b]'), '<strong>bold</strong>');
    assert.equal(parser.parse('[i]italic[/i]'), '<em>italic</em>');
    assert.equal(parser.parse('[u]under[/u]'), '<u>under</u>');
});

test('[h1]..[h6] map to native heading tags', () => {
    for (let i = 1; i <= 6; i++) {
        assert.equal(parser.parse(`[h${i}]hi[/h${i}]`), `<h${i}>hi</h${i}>`);
    }
});

test('[p] → <p>', () => {
    assert.equal(parser.parse('[p]hi[/p]'), '<p>hi</p>');
});

test('[color=red] uses CSS colon (regression: bbcode.mjs `color,$1` typo)', () => {
    assert.equal(
        parser.parse('[color=red]x[/color]'),
        '<span style="color:red">x</span>',
    );
});

test('[size=12] uses CSS colon (regression: bbcode.mjs `font-size,$1px` typo)', () => {
    assert.equal(
        parser.parse('[size=12]x[/size]'),
        '<span style="font-size:12px">x</span>',
    );
});

test('[img] both forms', () => {
    assert.equal(parser.parse('[img]a.png[/img]'), '<img src="a.png">');
    assert.equal(parser.parse('[img=a.png]'),       '<img src="a.png">');
});

test('[email] uses mailto: scheme (regression: bbcode.mjs `mailto,$1` typo)', () => {
    assert.equal(
        parser.parse('[email]a@b.c[/email]'),
        '<a href="mailto:a@b.c">a@b.c</a>',
    );
    assert.equal(
        parser.parse('[email=a@b.c]label[/email]'),
        '<a href="mailto:a@b.c">label</a>',
    );
});

test('[url] simple form', () => {
    assert.equal(
        parser.parse('[url]http://x.com[/url]'),
        '<a href="http://x.com">http://x.com</a>',
    );
});

test('[url=href]label[/url]', () => {
    assert.equal(
        parser.parse('[url=http://x.com]label[/url]'),
        '<a href="http://x.com">label</a>',
    );
});

test('[url=href target=_blank] (regression: bbcode.mjs `starget=` malformed alternation)', () => {
    assert.equal(
        parser.parse('[url=http://x.com target=_blank]label[/url]'),
        '<a href="http://x.com" target="_blank">label</a>',
    );
});

test('[a=anchor] named-anchor form', () => {
    assert.equal(
        parser.parse('[a=top]label[/a]'),
        '<a href="top" name="top">label</a>',
    );
});

test('[list][*]item[/*][/list] (regression: bbcode.mjs unescaped `*` in regex)', () => {
    assert.equal(
        parser.parse('[list][*]a[/*][/list]'),
        '<ul><li>a</li></ul>',
    );
});

test('multiple tags compose in one pass', () => {
    assert.equal(
        parser.parse('[b]bold[/b] and [i]italic[/i]'),
        '<strong>bold</strong> and <em>italic</em>',
    );
});

test('plain text passes through unchanged', () => {
    assert.equal(parser.parse('hello world'), 'hello world');
});
