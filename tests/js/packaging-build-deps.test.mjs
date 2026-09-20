// The renderer probes EGL, GL, GBM and libpulse with a plain pkg_check_modules —
// no REQUIRED — and switches two features on whether they were found.  Missing
// them costs a message(STATUS) at configure time and nothing else: the build goes
// green, the package installs, and the hardware video-texture decoder plus the
// PulseAudio default-sink live-rebind are simply not in it.  Nothing downstream
// ever notices, which is what makes these worth pinning.
//
// Every list that provisions a build has to name them, and the lists live in
// files nobody edits together.  The probe table below is the join: the CMake side
// says which libraries matter, and each reader says whether one manifest knows.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const probeCMake = join(repoRoot, 'src', 'backend_scene', 'src', 'CMakeLists.txt');

// pkg-config module -> the package that ships its .pc file, per manifest.  Names
// were resolved against each distro rather than guessed: Fedora via
// `dnf repoquery --whatprovides 'pkgconfig(<mod>)'`, Debian/Ubuntu from the
// libglvnd and mesa binary packages, Arch from libglvnd (gl.pc, egl.pc) and mesa
// (gbm.pc).  `spec` is the capability the rpm spec asks for, which is what lets
// one BuildRequires resolve on Fedora, openSUSE and Mageia alike.
const OPTIONAL_PROBES = {
    // EGL, GL and GBM are one feature: HWVideoTextureDecoder.cpp includes all
    // three headers, so two out of three still compiles the decoder out and MP4
    // scene textures fall back to the software path.
    egl: { spec: 'pkgconfig(egl)', fedora: 'libglvnd-devel', debian: 'libegl-dev', arch: 'libglvnd' },
    gl: { spec: 'pkgconfig(gl)', fedora: 'libglvnd-devel', debian: 'libgl-dev', arch: 'libglvnd' },
    gbm: { spec: 'pkgconfig(gbm)', fedora: 'mesa-libgbm-devel', debian: 'libgbm-dev', arch: 'mesa' },
    // Without it AudioCapture binds to whatever the default sink was at startup
    // and needs a plasmashell restart to follow a sink change.
    libpulse: {
        spec: 'pkgconfig(libpulse)',
        fedora: 'pulseaudio-libs-devel',
        debian: 'libpulse-dev',
        arch: 'libpulse',
    },
};

// Optional probes are the ones without REQUIRED — those are the silent ones.
// A REQUIRED probe that goes missing stops the configure, so it needs no pinning.
function optionalProbes() {
    const text = readFileSync(probeCMake, 'utf8');
    const found = [];
    for (const m of text.matchAll(/^\s*pkg_check_modules\(([^)]*)\)/gm)) {
        const args = m[1].split(/\s+/).filter(Boolean);
        args.shift(); // the result-variable prefix
        if (args.some((a) => a === 'REQUIRED')) continue;
        for (const a of args) {
            if (/^[A-Z_]+$/.test(a)) continue; // pkg_check_modules keywords
            found.push(a);
        }
    }
    return found;
}

// ── manifest readers ─────────────────────────────────────────────────────────

// BuildRequires outside every %if. These libraries are needed on all three rpm
// distros, so a conditional one would be a defect, not a pass.
function specUnconditionalBuildRequires() {
    const text = readFileSync(join(repoRoot, 'rpm', 'wek.spec'), 'utf8');
    const out = new Set();
    let depth = 0;
    for (const line of text.split('\n')) {
        if (/^%if\b/.test(line)) depth++;
        else if (/^%endif\b/.test(line)) depth--;
        else if (depth === 0) {
            const m = /^BuildRequires:\s*(\S+)/.exec(line);
            if (m) out.add(m[1]);
        }
    }
    return out;
}

// Build-Depends from the source stanza (the one before the first Package:).
function debianBuildDepends() {
    const text = readFileSync(join(repoRoot, 'debian', 'control'), 'utf8');
    const source = text.split(/\n(?=Package:)/)[0];
    const out = new Set();
    let inField = false;
    for (const line of source.split('\n')) {
        if (line.startsWith('#')) continue;
        const header = /^([A-Za-z][A-Za-z0-9-]*):\s*(.*)$/.exec(line);
        if (header) {
            inField = header[1] === 'Build-Depends';
            if (!inField) continue;
        } else if (!inField || !/^\s/.test(line)) {
            continue;
        }
        for (const raw of (header ? header[2] : line).split(',')) {
            const pkg = raw.trim().split(/[\s|(]/)[0];
            if (pkg) out.add(pkg);
        }
    }
    return out;
}

// makepkg installs depends as well as makedepends before build(), and these
// libraries are linked into the shipped .so, so either array is a correct home.
function archBuildDeps() {
    const text = readFileSync(join(repoRoot, 'arch', 'PKGBUILD'), 'utf8');
    const out = new Set();
    for (const name of ['depends', 'makedepends']) {
        const m = new RegExp(`^${name}=\\(([\\s\\S]*?)^\\)`, 'm').exec(text);
        if (!m) continue;
        for (const x of m[1].matchAll(/'([^']+)'/g)) out.add(x[1].split(':')[0].trim());
    }
    return out;
}

// preflight.sh provisions the Fedora distrobox the local gate runs in. It is the
// list that matters most: the gate is where a regression is supposed to surface,
// and a gate built without these probes cannot see one.
function preflightDeps() {
    const text = readFileSync(join(repoRoot, 'tools', 'scripts', 'preflight.sh'), 'utf8');
    const m = /^DEPS_FEDORA=\(([\s\S]*?)^\)/m.exec(text);
    assert.ok(m, 'tools/scripts/preflight.sh no longer defines DEPS_FEDORA');
    const out = new Set();
    for (const line of m[1].split('\n')) {
        if (/^\s*#/.test(line)) continue;
        for (const tok of line.split(/\s+/)) if (tok) out.add(tok);
    }
    return out;
}

// Every list that configures and builds the whole project. The workflow's
// unit-tests job is absent on purpose: it builds tests/ standalone, which stubs
// AudioCapture and never compiles the renderer. The workflow's package jobs
// are absent because they carry no list of their own; see the mechanism test.
const MANIFESTS = [
    { name: 'rpm/wek.spec BuildRequires', key: 'spec', read: specUnconditionalBuildRequires },
    { name: 'debian/control Build-Depends', key: 'debian', read: debianBuildDepends },
    { name: 'arch/PKGBUILD depends + makedepends', key: 'arch', read: archBuildDeps },
    { name: 'tools/scripts/preflight.sh DEPS_FEDORA', key: 'fedora', read: preflightDeps },
];

// The workflow's package jobs install straight from the manifests above, so a
// package added to a manifest reaches CI without a second edit. Pinning the
// command keeps a hand-maintained list from creeping back into ci.yml, where
// it would drift from the manifest the way the old jobs' lists did.
const CI_INSTALLS_FROM_MANIFEST = {
    'package-rpm': /dnf builddep -y \S*\.src\.rpm/,
    'package-deb': /apt-get build-dep -y \.\//,
    'package-arch': /source arch\/PKGBUILD\n\s*pacman -S [^\n]*"\$\{depends\[@\]\}" "\$\{makedepends\[@\]\}"/,
};

function ciJobBlock(jobId) {
    const text = readFileSync(join(repoRoot, '.github', 'workflows', 'ci.yml'), 'utf8');
    const block = text
        .split(/\n(?=  [A-Za-z0-9_-]+:\n)/)
        .find((b) => new RegExp(`^\\s*${jobId}:$`, 'm').test(b));
    assert.ok(block, `.github/workflows/ci.yml has no ${jobId} job`);
    return block;
}

test('every optional pkg-config probe is declared in every build-dependency list', () => {
    const missing = [];
    for (const manifest of MANIFESTS) {
        const declared = manifest.read();
        for (const [module, packages] of Object.entries(OPTIONAL_PROBES)) {
            const pkg = packages[manifest.key];
            if (!declared.has(pkg)) missing.push(`${manifest.name}: ${module} needs ${pkg}`);
        }
    }
    assert.deepEqual(
        missing,
        [],
        'a build from these lists silently loses the feature the probe guards:\n  ' + missing.join('\n  '),
    );
});

test('every workflow package job installs its build dependencies from a manifest', () => {
    for (const [jobId, command] of Object.entries(CI_INSTALLS_FROM_MANIFEST)) {
        assert.match(
            ciJobBlock(jobId),
            command,
            `${jobId} in .github/workflows/ci.yml no longer installs from the packaging manifest`,
        );
    }
});

test('no optional pkg-config probe escapes the dependency table', () => {
    const probed = optionalProbes();
    const unaccounted = probed.filter((m) => !(m in OPTIONAL_PROBES));
    assert.deepEqual(
        unaccounted,
        [],
        `${probeCMake.slice(repoRoot.length + 1)} probes for these without REQUIRED, and ` +
            'nothing names them in the packaging lists, so the feature they guard ' +
            `compiles out wherever they happen to be absent:\n  ${unaccounted.join('\n  ')}`,
    );
    for (const module of Object.keys(OPTIONAL_PROBES)) {
        assert.ok(
            probed.includes(module),
            `${module} is in the dependency table but no longer probed — drop the row`,
        );
    }
});
