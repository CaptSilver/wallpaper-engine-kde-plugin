// Both submodule doctest binaries pull in doctest.h from a vendored, third-party
// path (third_party/nlohmann/tests/thirdparty/doctest/doctest.h). CMake's SYSTEM
// keyword applies per include-directory *entry*, not by filesystem ancestry — a
// -isystem on the parent third_party/ doesn't cover a subdirectory that's listed
// as its own, separate, plain target_include_directories() entry. When that
// happens the compiler resolves #include <doctest.h> against the plain entry and
// reports the header's own diagnostics (a clang-only <ciso646> include, a
// __COUNTER__ extension) as first-party warnings, which -Werror then turns into
// build failures that have nothing to do with our code. This reads the CMake
// text directly (no compiler needed) and checks the include-directory entry that
// carries DOCTEST_INCLUDE_DIR for each submodule test target is a SYSTEM one.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const testCMake = join(repoRoot, 'src', 'backend_scene', 'src', 'Test', 'CMakeLists.txt');

// Returns the body of every target_include_directories(<target> ...) call for
// <target> in this file. Strips CMake's # comments first — a parenthetical
// inside one (e.g. "(e.g. \"Foo.hpp\")") would otherwise close a naive
// paren-depth count early and truncate the call body.
function includeDirCalls(target) {
    const text = readFileSync(testCMake, 'utf8');
    const stripped = text
        .split('\n')
        .map((l) => l.replace(/#.*$/, ''))
        .join('\n');
    const calls = [];
    const opener = new RegExp(`target_include_directories\\(\\s*${target}\\b`, 'g');
    let m;
    while ((m = opener.exec(stripped))) {
        const openIdx = stripped.indexOf('(', m.index);
        let depth = 0;
        let i = openIdx;
        for (; i < stripped.length; i++) {
            if (stripped[i] === '(') depth++;
            else if (stripped[i] === ')') {
                depth--;
                if (depth === 0) break;
            }
        }
        calls.push(stripped.slice(openIdx + 1, i));
    }
    return calls;
}

for (const target of ['backend_scene_tests', 'scenescript_tests']) {
    test(`${target}'s doctest include entry is SYSTEM, not a plain -I`, () => {
        const calls = includeDirCalls(target);
        assert.ok(calls.length > 0, `no target_include_directories(${target} ...) call found`);
        const withDoctest = calls.filter((body) => /DOCTEST_INCLUDE_DIR/.test(body));
        assert.equal(
            withDoctest.length,
            1,
            `expected exactly one target_include_directories(${target} ...) call to list ` +
                `DOCTEST_INCLUDE_DIR, found ${withDoctest.length}`,
        );
        assert.match(
            withDoctest[0],
            /\bSYSTEM\b/,
            `${target}'s DOCTEST_INCLUDE_DIR entry is not in a SYSTEM call — doctest.h's own ` +
                'diagnostics (the clang <ciso646> include, the __COUNTER__ extension) get reported ' +
                "as first-party warnings and fail the target's build under -Werror",
        );
    });
}
