// ki18n_install(po) in the top-level CMakeLists stages <builddir>/locale into
// %{buildroot}%{_datadir}/locale on every build, translations or not.  While po/
// holds only the .pot template that tree is empty, and rpm's unpackaged-files
// check ignores directories, so an rpm spec with no locale entry builds fine.
// The first .po anyone lands turns that empty directory into a real .mo with no
// %files owner, and %_unpackaged_files_terminate_build (on by default) aborts
// rpmbuild — on a commit that looks like a pure translation.
//
// These tests pin the spec to the CMake side: the locale tree has an owner, the
// domain it collects matches the catalog po/Messages.sh extracts into, and the
// collection survives the state we are in today, where there is nothing to
// collect.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const specPath = join(repoRoot, 'rpm', 'wek.spec');
const spec = readFileSync(specPath, 'utf8');

// The gettext catalog name. Messages.sh is where it is decided — it names the
// .pot xgettext writes, and every translation lands as <catalog>.po, which
// ki18n_install compiles to <catalog>.mo.
function catalogName() {
    const text = readFileSync(join(repoRoot, 'po', 'Messages.sh'), 'utf8');
    const m = /^CATALOG=(\S+)/m.exec(text);
    assert.ok(m, 'po/Messages.sh no longer sets CATALOG');
    return m[1];
}

// Resolve the spec's own %global / %define values so a %{...} reference in the
// text below reads the way rpm will see it. Unknown macros (%{_datadir} and
// friends) are left alone.
function expandSpecMacros(text) {
    const globals = new Map();
    for (const m of spec.matchAll(/^%(?:global|define)\s+(\S+)\s+(.*)$/gm)) {
        globals.set(m[1], m[2].trim());
    }
    return text.replace(/%\{\??([A-Za-z_]\w*)\}/g, (all, name) =>
        globals.has(name) ? globals.get(name) : all,
    );
}

// Return the body of one section of the spec, %<name> up to the next %<section>.
const SECTIONS = ['prep', 'build', 'install', 'check', 'files', 'changelog', 'description'];
function specSection(name) {
    const lines = spec.split('\n');
    const start = lines.findIndex((l) => new RegExp(`^%${name}\\b`).test(l));
    assert.ok(start >= 0, `rpm/wek.spec has no %${name} section`);
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
        const m = /^%([a-z]+)\b/.exec(lines[i]);
        if (m && SECTIONS.includes(m[1])) {
            end = i;
            break;
        }
    }
    return expandSpecMacros(lines.slice(start, end).join('\n'));
}

test('the top-level build still stages a locale tree', () => {
    const cmake = readFileSync(join(repoRoot, 'CMakeLists.txt'), 'utf8');
    assert.match(
        cmake,
        /^\s*ki18n_install\(po\)/m,
        'CMakeLists.txt no longer calls ki18n_install(po) — if translations moved ' +
            'to another mechanism, this whole file needs rewriting against it',
    );
});

test('the rpm spec owns the translation catalogs the build installs', () => {
    const files = specSection('files');
    const install = specSection('install');
    const catalog = catalogName();

    // Two ways to own the tree: a %find_lang-generated file list, or an explicit
    // glob. %find_lang is the one that also marks the files %lang(xx), so users
    // installing with a locale filter do not carry every translation.
    const usesFindLang = new RegExp(`^%files\\b.*-f\\s+${catalog.replace(/\./g, '\\.')}\\.lang`, 'm').test(files);
    const usesGlob = /^%\{_datadir\}\/locale\b/m.test(files) || /^%\{_datadir\}\/locale\//m.test(files);
    assert.ok(
        usesFindLang || usesGlob,
        'ki18n_install stages %{_datadir}/locale but %files claims nothing under it. ' +
            'The first translation to land becomes an unpackaged file and rpmbuild ' +
            `aborts. Add "%find_lang ${catalog}" to %install and "-f ${catalog}.lang" ` +
            `to %files. Got %files:\n${files}`,
    );

    if (usesFindLang) {
        assert.match(
            install,
            new RegExp(`^%find_lang\\s+${catalog.replace(/\./g, '\\.')}\\b`, 'm'),
            `%files reads ${catalog}.lang but %install never runs %find_lang to write it`,
        );
    }
});

// Text checks only go so far here: rpm rejects an empty -f manifest as hard as
// it rejects an unpackaged file ("Empty %files file"), and a manifest of nothing
// but comments counts as empty too.  So run the spec's own catalog-collection
// line — macros expanded by rpmspec, not re-implemented here — against a fake
// buildroot in both states that matter.
const findLangSh = '/usr/lib/rpm/find-lang.sh';
const tooling = (() => {
    try {
        readFileSync(findLangSh);
        execFileSync('rpmspec', ['--version'], { stdio: 'ignore' });
        return false;
    } catch {
        return 'rpmspec / find-lang.sh not available';
    }
})();

// _topdir is redirected so the %{buildroot} rpm hands the command lands in the
// throwaway tree; that path is read back out of the expanded command rather
// than guessed.  Continuation lines are joined, and comment lines skipped — the
// spec's own commentary mentions find-lang.sh.
function catalogCollection(work) {
    const expanded = execFileSync('rpmspec', ['-P', '--define', `_topdir ${work}`, specPath], {
        encoding: 'utf8',
    });
    const lines = expanded.split('\n');
    const first = lines.findIndex(
        (l) => l.includes('find-lang.sh') && !l.trimStart().startsWith('#'),
    );
    assert.ok(first >= 0, '%install no longer collects translation catalogs');
    let last = first;
    while (lines[last].trimEnd().endsWith('\\')) last++;
    const command = lines.slice(first, last + 1).join('\n');
    const buildroot = /find-lang\.sh\s+(\S+)/.exec(command);
    assert.ok(buildroot, `cannot read the buildroot out of: ${command}`);
    return { command, buildroot: buildroot[1] };
}

// One .mo per staged language is what ki18n_install produces from po/<lang>/.
function stageCatalogs(buildroot, catalogs) {
    mkdirSync(join(buildroot, 'usr', 'share', 'locale'), { recursive: true });
    for (const [lang, name] of catalogs) {
        const dir = join(buildroot, 'usr', 'share', 'locale', lang, 'LC_MESSAGES');
        mkdirSync(dir, { recursive: true });
        writeFileSync(join(dir, `${name}.mo`), '');
    }
}

// rpm skips blank and comment lines when it decides a manifest is empty.
function manifestEntries(dir) {
    return readdirSync(dir)
        .filter((f) => f.endsWith('.lang'))
        .flatMap((f) => readFileSync(join(dir, f), 'utf8').split('\n'))
        .map((l) => l.trim())
        .filter((l) => l && !l.startsWith('#'));
}

function collectCatalogs(catalogs) {
    const work = mkdtempSync(join(tmpdir(), 'wek-findlang-'));
    try {
        const { command, buildroot } = catalogCollection(work);
        stageCatalogs(buildroot, catalogs);
        execFileSync('bash', ['-c', command], { cwd: work });
        return manifestEntries(work);
    } finally {
        rmSync(work, { recursive: true, force: true });
    }
}

test('an untranslated build still produces a file list rpm will accept', { skip: tooling }, () => {
    const entries = collectCatalogs([]);
    assert.notDeepEqual(
        entries,
        [],
        'with po/ holding only the .pot template the catalog collection leaves an ' +
            'empty file list, and rpm fails %files with "Empty %files file" — the ' +
            'build breaks on every distro until someone contributes a translation',
    );
});

test('a translated build packages the catalog it installed', { skip: tooling }, () => {
    const catalog = catalogName();
    const entries = collectCatalogs([['de', catalog]]);
    assert.ok(
        entries.some((e) => e.endsWith(`/usr/share/locale/de/LC_MESSAGES/${catalog}.mo`)),
        `the catalog ki18n_install writes (${catalog}.mo) is not in the file list, so ` +
            `rpm would abort on it as unpackaged. Got:\n  ${entries.join('\n  ')}`,
    );
});
