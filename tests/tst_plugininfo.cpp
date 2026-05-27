#include <QtTest>
#include <QMetaObject>
#include <QMetaProperty>

// Pull in the header directly so version() is available as a pure-header
// inline.  PluginInfo.cpp is NOT compiled into this binary because it
// includes SceneBackend.hpp which transitively links the full Vulkan backend.
// cache_path() is stub-implemented below; it is not called by any test case —
// only its declared type is inspected via QMetaProperty.
#include "PluginInfo.hpp"

// Minimal stub so the linker is satisfied without pulling in SceneBackend.hpp.
// No test case calls cache_path(); the meta-object type check (QUrl) does not
// invoke the getter.
namespace wekde
{
QUrl PluginInfo::cache_path() const { return QUrl(); }
} // namespace wekde

using namespace wekde;

class TstPluginInfo : public QObject {
    Q_OBJECT
private slots:
    // The meta-object regression: catches any future type-declaration mismatch
    // between the Q_PROPERTY type annotation and the getter return type.
    void version_typeIsString() {
        const QMetaObject* mo  = &PluginInfo::staticMetaObject;
        const int          idx = mo->indexOfProperty("version");
        QVERIFY2(idx >= 0, "Q_PROPERTY 'version' not found in PluginInfo meta-object");
        QMetaProperty prop = mo->property(idx);
        QCOMPARE(QString(prop.typeName()), QStringLiteral("QString"));
        QVERIFY2(prop.isConstant(),
                 "'version' must be declared CONSTANT (it has no NOTIFY signal)");
    }

    // Locks that the getter returns the exact value baked in by the build
    // system — no silent truncation, no re-encoding.
    void version_matchesBuildVersion() {
        PluginInfo pi;
        QCOMPARE(pi.version(), QStringLiteral(WEK_VERSION));
    }

    // Pinning that the stale sentinel is gone.  Would have failed against the
    // old hardcoded literal even before the VERSION file was updated.
    void version_isNotStaleSentinel() {
        PluginInfo pi;
        QVERIFY2(pi.version() != QStringLiteral("0.6.0"),
                 "version() still returns the stale '0.6.0' sentinel — "
                 "WEK_VERSION was not injected by CMake");
    }

    // cache_path() is in the .cpp so calling it here would force linking the
    // full Vulkan backend.  Instead verify the meta-object declares it with
    // type QUrl — confirming the cache_path property contract is intact.
    void cachePath_declaredAsQUrl() {
        const QMetaObject* mo  = &PluginInfo::staticMetaObject;
        const int          idx = mo->indexOfProperty("cache_path");
        QVERIFY2(idx >= 0, "Q_PROPERTY 'cache_path' not found");
        QMetaProperty prop = mo->property(idx);
        QCOMPARE(QString(prop.typeName()), QStringLiteral("QUrl"));
    }

    // PluginInfo::cache_path is synthesised from XDG env + build-time submodule
    // name — both fixed at process start. The Q_PROPERTY must be marked CONSTANT
    // so QML doesn't subscribe to a NOTIFY signal that never fires. Mirrors the
    // sibling 'version' contract pinned in version_typeIsString().
    void cachePath_isMarkedConstant() {
        const QMetaObject* mo  = &PluginInfo::staticMetaObject;
        const int          idx = mo->indexOfProperty("cache_path");
        QVERIFY2(idx >= 0, "Q_PROPERTY 'cache_path' not found");
        QMetaProperty prop = mo->property(idx);
        QVERIFY2(prop.isConstant(),
                 "'cache_path' must be declared CONSTANT (process-lifetime invariant)");
        QCOMPARE(prop.notifySignalIndex(), -1);
    }
};

QTEST_GUILESS_MAIN(TstPluginInfo)
#include "tst_plugininfo.moc"
