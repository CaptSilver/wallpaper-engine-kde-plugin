// rpm/wek.spec carries per-distro conditionals, and getting one wrong is invisible
// until a build on that distro either fails or — worse — succeeds with a feature
// quietly compiled out. These tests evaluate the spec the way rpm itself will, with
// `rpmspec -q`, for each distro family we build for.
//
// The build host's own macros leak into that evaluation: on a Fedora builder
// %{fedora} is already defined, so a `--define "rhel 10"` alone still takes the
// Fedora branch and every assertion below would pass for the wrong reason. Each
// simulated target therefore undefines the families it is not.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const specPath = join(repoRoot, 'rpm', 'wek.spec');

// rpmspec is not guaranteed on a freshly recreated dev box; skip rather than fail.
function haveRpmspec() {
    try {
        execFileSync('rpmspec', ['--version'], { stdio: 'ignore' });
        return true;
    } catch {
        return false;
    }
}

const ALL_FAMILIES = ['fedora', 'rhel', 'suse_version', 'mageia'];

// Evaluate the spec as the named distro family and nothing else.
function querySpec(kind, family, version) {
    const args = [`-q`, `--${kind}`];
    for (const f of ALL_FAMILIES) {
        if (f !== family) args.push('--undefine', f);
    }
    args.push('--define', `${family} ${version}`, specPath);
    return execFileSync('rpmspec', args, { encoding: 'utf8' })
        .split('\n')
        .map((l) => l.trim())
        .filter(Boolean);
}

const skip = haveRpmspec() ? false : 'rpmspec not available';

test('spec exists', () => {
    assert.ok(existsSync(specPath), `missing ${specPath}`);
});

// src/backend_mpv/CMakeLists.txt reads Qt6Gui_PRIVATE_INCLUDE_DIRS. Fedora splits
// the Qt6 private headers into their own package, and every Fedora-derived
// enterprise distro (RHEL 10, AlmaLinux 10, Rocky 10, CentOS Stream 10) splits them
// the same way — qt6-qtbase-private-devel, in CRB. openSUSE and Mageia ship them
// inside the ordinary Qt6 devel packages, so they must NOT get the extra dependency.
test('Fedora-derived targets BuildRequire the Qt6 private headers', { skip }, () => {
    for (const [family, version] of [['fedora', 44], ['rhel', 10]]) {
        const br = querySpec('buildrequires', family, version);
        assert.ok(
            br.includes('qt6-qtbase-private-devel'),
            `${family} ${version} must BuildRequire qt6-qtbase-private-devel — ` +
                `src/backend_mpv reads Qt6Gui_PRIVATE_INCLUDE_DIRS and this distro ` +
                `splits those headers into their own package. Got:\n${br.join('\n')}`,
        );
    }
});

test('openSUSE and Mageia do not ask for a package they do not have', { skip }, () => {
    for (const [family, version] of [['suse_version', 1600], ['mageia', 10]]) {
        const br = querySpec('buildrequires', family, version);
        assert.ok(
            !br.includes('qt6-qtbase-private-devel'),
            `${family} ships the Qt6 private headers inside its ordinary devel ` +
                `packages; requiring qt6-qtbase-private-devel there is unresolvable`,
        );
    }
});

// The Requires block branches suse -> mageia -> everything-else, so any distro that
// is neither openSUSE nor Mageia inherits the Fedora-shaped names. That is correct
// for RHEL 10 and its rebuilds, whose package names match Fedora's. This pins it, so
// a future edit cannot quietly route enterprise targets into the wrong branch.
test('RHEL 10 inherits the Fedora-shaped runtime Requires', { skip }, () => {
    const req = querySpec('requires', 'rhel', 10);
    for (const pkg of [
        'plasma-workspace',
        'plasma5support',
        'qt6-qtwebchannel',
        'kf6-knotifications',
        'kf6-kcrash',
        'kf6-kglobalaccel',
        'kf6-ki18n',
    ]) {
        assert.ok(req.includes(pkg), `RHEL 10 Requires must include ${pkg}, got:\n${req.join('\n')}`);
    }
    // The openSUSE spellings must not leak in.
    for (const wrong of ['plasma6-workspace', 'plasma5support6', 'qt6-webchannel-imports', 'qtwebchannel6']) {
        assert.ok(!req.includes(wrong), `RHEL 10 must not Require the non-Fedora name ${wrong}`);
    }
});
