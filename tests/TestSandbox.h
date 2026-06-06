// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QStandardPaths>
#include <QString>
#include <QTemporaryDir>

// Per-process HOME isolation for tests that use
// QStandardPaths::setTestModeEnabled(true).
//
// setTestModeEnabled hardcodes its sandbox at ~/.qttest/ — a single
// filesystem path shared by every process running the test binary.  When
// tools/scripts/mutation.sh runs Mull with --workers > 1, many parallel mutant
// invocations of the same test binary race on that shared path: one process
// is mid-write while another is mid-read, files get half-written, and
// QVERIFY(f.open(QIODevice::WriteOnly)) starts failing.
//
// Wrap setTestModeEnabled with this helper to give each process its own
// HOME -> ~/.qttest/ then resolves to a per-process tmp dir, no race.
//
// The sandbox base must be on disk (not tmpfs/`/tmp`) — the cache-quota
// tests use QFile::setFileTime(...) to age fixtures and rely on
// QFileInfo::lastRead() returning the explicitly-set atime. tmpfs ignores
// explicit atime updates under relatime, which breaks the eviction
// ordering.  Base: $XDG_CACHE_HOME/wek-test-sandbox (typically
// $HOME/.cache/wek-test-sandbox).  Fallback when XDG_CACHE_HOME missing:
// $HOME/.cache.  Last-resort fallback: /tmp (best effort, may flake cache
// tests on tmpfs).  The static QTemporaryDir is process-local and
// auto-cleaned at exit.
namespace wek
{
namespace test_sandbox
{

inline QString sandboxBase() {
    const QByteArray xdgCacheEnv = qgetenv("XDG_CACHE_HOME");
    if (! xdgCacheEnv.isEmpty()) {
        return QString::fromLocal8Bit(xdgCacheEnv) + QLatin1String("/wek-test-sandbox");
    }
    const QByteArray homeEnv = qgetenv("HOME");
    if (! homeEnv.isEmpty()) {
        return QString::fromLocal8Bit(homeEnv) + QLatin1String("/.cache/wek-test-sandbox");
    }
    return QStringLiteral("/tmp/wek-test-sandbox");
}

inline void enableIsolated() {
    const QString base = sandboxBase();
    QDir().mkpath(base);
    static QTemporaryDir s_dir(base + QLatin1String("/proc-XXXXXX"));
    if (s_dir.isValid()) {
        qputenv("HOME", s_dir.path().toLocal8Bit());
    }
    QStandardPaths::setTestModeEnabled(true);
}

} // namespace test_sandbox
} // namespace wek
