// The QML modules the shipped UI imports by name are invisible to every
// dependency generator: rpm reads DT_NEEDED off the .so, dpkg-shlibdeps does the
// same, and neither ever opens a .qml file.  So a missing runtime module is not a
// build failure or an install failure — the package installs clean and plasmashell
// then logs a QML error and draws nothing.  These tests are the only thing
// standing between a new `import` line and a silently broken package.
//
// Package names below were each checked against the distro's own metadata, not
// guessed: Fedora via `rpm -q --whatprovides 'qt6qml(<module>)'`, openSUSE and
// Mageia by resolving the module's qmldir to its owning rpm in the Tumbleweed
// repo listing / the Mageia cauldron files index, Debian against the trixie
// Packages index, Arch via the archlinux.org package files API.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const uiDir = join(repoRoot, 'plugin', 'contents', 'ui');

// Distro keys are the manifest sections the checks below know how to read.
const DISTROS = ['fedora', 'opensuse', 'mageia', 'debian', 'arch'];

// Modules that need naming in the manifests, with the package that ships them.
// `strength: 'required'` means a hard dependency — a weak Recommends is not
// enough, because a user installing with weak deps disabled would get a package
// that cannot draw a wallpaper at all.
const DECLARED_MODULES = {
    // main.qml instantiates WindowModel and PowerSource unconditionally, and both
    // are Plasma5Support.DataSource wrappers.  Without the module the root item
    // fails to create and the desktop shows no wallpaper — nothing degrades, it
    // just stops.  On Fedora it happens to arrive because plasma-workspace
    // requires the `plasmashell` capability that plasma-desktop provides; that is
    // far too incidental a chain to leave a hard runtime requirement resting on.
    'org.kde.plasma.plasma5support': {
        strength: 'required',
        packages: {
            fedora: 'plasma5support',
            opensuse: 'plasma5support6',
            mageia: 'plasma5support',
            debian: 'qml6-module-org-kde-plasma-plasma5support',
            arch: 'plasma5support',
        },
    },
    // The web wallpaper backend talks to SafeWallpaperBridge over QWebChannel.
    // Nothing in the Plasma stack pulls it in on any distro checked.
    QtWebChannel: {
        strength: 'required',
        packages: {
            fedora: 'qt6-qtwebchannel',
            opensuse: 'qt6-webchannel-imports',
            mageia: 'qtwebchannel6',
            debian: 'qml6-module-qtwebchannel',
            arch: 'qt6-webchannel',
        },
    },
    // Web wallpapers only.  Scene and video wallpapers work without it, so a weak
    // dependency is the right strength.
    QtWebEngine: {
        strength: 'recommended',
        packages: {
            fedora: 'qt6-qtwebengine',
            opensuse: 'qt6-webengine-imports',
            mageia: 'qtwebengine6',
            debian: 'qml6-module-qtwebengine',
            arch: 'qt6-webengine',
        },
    },
    // config/main.xml defaults VideoBackend to Mpv, so this is the fallback the
    // user reaches by switching backend or by not having libmpv — weak, but it
    // must be nameable.  Debian only gets it today by accident, via a barcode
    // library (qml6-module-org-kde-prison) in plasma-workspace's closure.
    QtMultimedia: {
        strength: 'recommended',
        packages: {
            fedora: 'qt6-qtmultimedia',
            opensuse: 'qt6-multimedia-imports',
            mageia: 'qtmultimedia6',
            debian: 'qml6-module-qtmultimedia',
            arch: 'qt6-multimedia',
        },
    },
};

// Modules that are already guaranteed by a dependency every manifest declares.
// Naming them again would be noise, so each row records what covers it instead.
const PROVIDED_MODULES = {
    QtQuick: 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Controls': 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Controls.Material': 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Dialogs': 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Layouts': 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Templates': 'Qt Quick runtime the plugin .so links against',
    'QtQuick.Window': 'Qt Quick runtime the plugin .so links against',
    'Qt5Compat.GraphicalEffects': 'plasma-workspace — the Breeze QML uses it too',
    'org.kde.kcmutils': 'plasma-workspace — every Plasma KCM imports it',
    'org.kde.kirigami': 'plasma-workspace — the whole Plasma UI is Kirigami',
    'org.kde.plasma.components': 'plasma-workspace — plasmashell renders with it',
    'org.kde.plasma.core': 'plasma-workspace — plasmashell renders with it',
    'org.kde.plasma.plasmoid': 'plasma-workspace — the applet API itself',
    'org.kde.taskmanager': 'plasma-workspace — ships the task manager applet',
    'com.github.captsilver.wallpaperEngineKde': 'this package installs it',
};

function qmlFilesUnder(dir) {
    const out = [];
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) out.push(...qmlFilesUnder(full));
        else if (entry.name.endsWith('.qml')) out.push(full);
    }
    return out.sort();
}

// Relative imports ("..", "../components") and JS imports are the plugin's own
// files, so only dotted module identifiers are packaging-relevant.
function importedModules() {
    const found = new Map();
    for (const file of qmlFilesUnder(uiDir)) {
        const text = readFileSync(file, 'utf8')
            .replace(/\/\*[\s\S]*?\*\//g, '')
            .replace(/\/\/[^\n]*/g, '');
        for (const line of text.split('\n')) {
            const m = /^\s*import\s+([A-Za-z_][\w.]*)/.exec(line);
            if (!m) continue;
            if (!found.has(m[1])) found.set(m[1], []);
            found.get(m[1]).push(file.slice(repoRoot.length + 1));
        }
    }
    return found;
}

// ── manifest readers ─────────────────────────────────────────────────────────
// Each returns { hard: Set, weak: Set } of package names for one distro.

// rpm/wek.spec carries all three rpm distros in one file behind nested
// %if/%else, so the tokens have to be filtered down to the branch that is live
// for the distro under test — a name sitting in the openSUSE arm does nothing
// for Mageia.
function specDependencies(distro) {
    const text = readFileSync(join(repoRoot, 'rpm', 'wek.spec'), 'utf8');
    const hard = new Set();
    const weak = new Set();
    // Unknown conditions (e.g. %{with check}) evaluate true: over-including can
    // only ever hide a spurious failure, never a genuinely missing dependency.
    const evalCond = (cond) => {
        if (/suse_version/.test(cond)) return distro === 'opensuse';
        if (/mageia/.test(cond)) return distro === 'mageia';
        if (/fedora/.test(cond)) return distro === 'fedora';
        return true;
    };
    const stack = [];
    const live = () => stack.every((f) => f.active);
    for (const line of text.split('\n')) {
        const ifm = /^%if\s+(.*)$/.exec(line);
        if (ifm) {
            stack.push({ value: evalCond(ifm[1]), active: evalCond(ifm[1]) });
            continue;
        }
        if (/^%else\b/.test(line)) {
            const frame = stack[stack.length - 1];
            if (frame) frame.active = !frame.value;
            continue;
        }
        if (/^%endif\b/.test(line)) {
            stack.pop();
            continue;
        }
        if (!live()) continue;
        const dep = /^(Requires|Recommends):\s*(\S+)/.exec(line);
        if (dep) (dep[1] === 'Requires' ? hard : weak).add(dep[2]);
    }
    return { hard, weak };
}

function debianDependencies() {
    const text = readFileSync(join(repoRoot, 'debian', 'control'), 'utf8');
    // Only the binary stanza matters; Build-Depends is a compile-time list.
    const binary = text.split(/\n(?=Package:)/).find((s) => /^Package:\s*\S/.test(s));
    assert.ok(binary, 'debian/control has no binary package stanza');
    // deb822 is line-oriented: a field header starts in column 0, its
    // continuations are indented, and '#' comments are stripped before parsing.
    const field = (name) => {
        const out = new Set();
        const add = (chunk) => {
            for (const raw of chunk.split(',')) {
                const pkg = raw.trim().split(/[\s|]/)[0];
                if (pkg && !pkg.startsWith('${')) out.add(pkg);
            }
        };
        let inField = false;
        for (const line of binary.split('\n')) {
            if (line.startsWith('#')) continue;
            const header = /^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$/.exec(line);
            if (header) {
                inField = header[1] === name;
                if (inField) add(header[2]);
            } else if (inField && /^\s/.test(line)) {
                add(line);
            }
        }
        return out;
    };
    return { hard: field('Depends'), weak: field('Recommends') };
}

function archDependencies() {
    const text = readFileSync(join(repoRoot, 'arch', 'PKGBUILD'), 'utf8');
    const array = (name) => {
        const m = new RegExp(`^${name}=\\(([\\s\\S]*?)^\\)`, 'm').exec(text);
        if (!m) return new Set();
        return new Set(
            [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1].split(':')[0].trim())
        );
    };
    return { hard: array('depends'), weak: array('optdepends') };
}

function dependenciesFor(distro) {
    if (distro === 'debian') return debianDependencies();
    if (distro === 'arch') return archDependencies();
    return specDependencies(distro);
}

test('every runtime QML module the UI imports is declared in every packaging manifest', () => {
    const imported = importedModules();
    const deps = Object.fromEntries(DISTROS.map((d) => [d, dependenciesFor(d)]));
    const missing = [];
    for (const [module, spec] of Object.entries(DECLARED_MODULES)) {
        assert.ok(imported.has(module), `${module} is declared but no longer imported — drop the row`);
        for (const distro of DISTROS) {
            const pkg = spec.packages[distro];
            const { hard, weak } = deps[distro];
            if (spec.strength === 'required') {
                if (!hard.has(pkg)) missing.push(`${distro}: ${module} needs a hard dependency on ${pkg}`);
            } else if (!hard.has(pkg) && !weak.has(pkg)) {
                missing.push(`${distro}: ${module} needs at least a weak dependency on ${pkg}`);
            }
        }
    }
    assert.deepEqual(missing, [], `undeclared runtime QML modules:\n  ${missing.join('\n  ')}`);
});

// This is the check that would have caught the three modules above before they
// shipped.  Adding an `import` line is the moment a new runtime dependency is
// created, so that is the moment it has to be accounted for — either as a
// package to name in the manifests, or as one already covered by a declared
// dependency.  A module that fits neither is usually an import nothing uses.
test('no QML module is imported without being accounted for in the packaging tables', () => {
    const unaccounted = [];
    for (const [module, files] of importedModules()) {
        if (module in DECLARED_MODULES || module in PROVIDED_MODULES) continue;
        unaccounted.push(`${module} (imported by ${files.join(', ')})`);
    }
    assert.deepEqual(
        unaccounted,
        [],
        `QML modules with no packaging entry:\n  ${unaccounted.join('\n  ')}`
    );
});
