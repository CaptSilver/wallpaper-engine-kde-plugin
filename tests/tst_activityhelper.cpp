// ActivityHelper unit tests — KConfig sub-group routing with [General] fallback.
//
// The helper's job is to translate per-Activity reads/writes into the right
// KConfig group (`Activity_<uuid>`) with a fallback to `General` so legacy
// installs (and the "All Activities" affinity) keep resolving.  Each test seeds
// a KConfig in a QTemporaryDir, constructs the helper pointing at it, and
// asserts both the helper's return values and the on-disk group state.

#include <QtTest>
#include <QSignalSpy>
#include <QTemporaryDir>

#include <KConfig>
#include <KConfigGroup>

#include "ActivityHelper.hpp"

class TstActivityHelper : public QObject {
    Q_OBJECT
private slots:
    // ── readPerActivity ──────────────────────────────────────────────────────

    void readPerActivity_returnsValue_whenGroupExists() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";
        // Seed [Activity_test-uuid-A]WallpaperWorkShopId=W1.
        {
            KConfig      cfg(cfgPath, KConfig::SimpleConfig);
            KConfigGroup a(&cfg, "Activity_test-uuid-A");
            a.writeEntry("WallpaperWorkShopId", QStringLiteral("W1"));
            cfg.sync();
        }
        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("test-uuid-A");
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QStringLiteral("W1"));
    }

    void readPerActivity_fallsBackToGeneral_whenActivityGroupAbsent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";
        // Seed [General]WallpaperWorkShopId=W_LEGACY, no [Activity_*] groups.
        {
            KConfig      cfg(cfgPath, KConfig::SimpleConfig);
            KConfigGroup g(&cfg, "General");
            g.writeEntry("WallpaperWorkShopId", QStringLiteral("W_LEGACY"));
            cfg.sync();
        }
        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("brand-new-activity");
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QStringLiteral("W_LEGACY"));
    }

    void readPerActivity_returnsEmpty_whenBothAbsent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString         cfgPath = d.path() + "/wekrc";
        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("any-activity");
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QString());
    }

    // ── setPerActivity ───────────────────────────────────────────────────────

    void setPerActivity_writesToCurrentActivityGroup() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";

        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("test-uuid-B");
        helper.setPerActivity("WallpaperSource", QStringLiteral("/path/to/wp.json"));

        // Verify on disk (read with a fresh KConfig so we exercise the sync()).
        KConfig      cfg(cfgPath, KConfig::SimpleConfig);
        KConfigGroup activity(&cfg, "Activity_test-uuid-B");
        QCOMPARE(activity.readEntry("WallpaperSource", QString()),
                 QStringLiteral("/path/to/wp.json"));
        // [General] must NOT have been touched.
        KConfigGroup general(&cfg, "General");
        QCOMPARE(general.hasKey("WallpaperSource"), false);
    }

    void setPerActivity_roundTripsAcrossActivitySwitch() {
        // Switch between two Activities, write a different value in each,
        // verify each Activity's bucket holds the right value.
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";

        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("A");
        helper.setPerActivity("WallpaperWorkShopId", QStringLiteral("W1"));
        helper.setCurrentActivityForTesting("B");
        helper.setPerActivity("WallpaperWorkShopId", QStringLiteral("W2"));

        helper.setCurrentActivityForTesting("A");
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QStringLiteral("W1"));
        helper.setCurrentActivityForTesting("B");
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QStringLiteral("W2"));
    }

    void setPerActivity_emitsSignal_onCurrentActivityChanged() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";

        wekde::ActivityHelper helper(cfgPath);
        QSignalSpy            spy(&helper, &wekde::ActivityHelper::currentActivityChanged);
        helper.setCurrentActivityForTesting("uuid-1");
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.takeFirst().at(0).toString(), QStringLiteral("uuid-1"));

        // Repeat with the same value — no second emission (debounce).
        helper.setCurrentActivityForTesting("uuid-1");
        QCOMPARE(spy.count(), 0);

        // Different value — emit again.
        helper.setCurrentActivityForTesting("uuid-2");
        QCOMPARE(spy.count(), 1);
        QCOMPARE(spy.takeFirst().at(0).toString(), QStringLiteral("uuid-2"));
    }

    // ── setForActivity (explicit-Activity write + "all" affinity) ────────────

    void setForActivity_all_writesToGeneral() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";

        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("uuid-current");
        helper.setForActivity("all", "WallpaperWorkShopId", QStringLiteral("W_GLOBAL"));

        // On disk, [General] holds the value, no [Activity_uuid-current] group.
        KConfig      cfg(cfgPath, KConfig::SimpleConfig);
        KConfigGroup general(&cfg, "General");
        QCOMPARE(general.readEntry("WallpaperWorkShopId", QString()),
                 QStringLiteral("W_GLOBAL"));
        KConfigGroup activity(&cfg, "Activity_uuid-current");
        QCOMPARE(activity.hasKey("WallpaperWorkShopId"), false);

        // Read falls back to General because Activity_* is empty.
        QCOMPARE(helper.readPerActivity("WallpaperWorkShopId"), QStringLiteral("W_GLOBAL"));
    }

    void setForActivity_namedUuid_writesIndependentOfCurrent() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";

        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("uuid-A");
        helper.setForActivity("uuid-B", "WallpaperSource", QStringLiteral("/foo"));

        // Current Activity unchanged; read of A still falls back to General
        // (which is empty here), B's bucket has the value.
        KConfig      cfg(cfgPath, KConfig::SimpleConfig);
        KConfigGroup b(&cfg, "Activity_uuid-B");
        QCOMPARE(b.readEntry("WallpaperSource", QString()), QStringLiteral("/foo"));
        QCOMPARE(helper.currentActivity(), QStringLiteral("uuid-A"));
    }

    // ── dropActivity ─────────────────────────────────────────────────────────

    void dropActivity_removesTheActivitySubgroup() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";
        {
            KConfig      cfg(cfgPath, KConfig::SimpleConfig);
            KConfigGroup a(&cfg, "Activity_to-be-removed");
            a.writeEntry("WallpaperWorkShopId", QStringLiteral("X"));
            cfg.sync();
        }
        wekde::ActivityHelper helper(cfgPath);
        helper.dropActivity("to-be-removed");

        KConfig      cfg(cfgPath, KConfig::SimpleConfig);
        KConfigGroup a(&cfg, "Activity_to-be-removed");
        QCOMPARE(a.hasKey("WallpaperWorkShopId"), false);
        QCOMPARE(a.keyList().isEmpty(), true);
    }

    void dropActivity_skipsDefaultBucket() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString cfgPath = d.path() + "/wekrc";
        {
            KConfig      cfg(cfgPath, KConfig::SimpleConfig);
            KConfigGroup a(&cfg, "Activity__default");
            a.writeEntry("WallpaperWorkShopId", QStringLiteral("DEF"));
            cfg.sync();
        }
        wekde::ActivityHelper helper(cfgPath);
        helper.dropActivity(""); // empty == unknown — must NOT delete _default

        KConfig      cfg(cfgPath, KConfig::SimpleConfig);
        KConfigGroup a(&cfg, "Activity__default");
        QCOMPARE(a.readEntry("WallpaperWorkShopId", QString()), QStringLiteral("DEF"));
    }

    // ── currentActivity defaults ─────────────────────────────────────────────

    void currentActivity_defaultsTo_underscoreDefault_whenEmpty() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString         cfgPath = d.path() + "/wekrc";
        wekde::ActivityHelper helper(cfgPath);
        QCOMPARE(helper.currentActivity(), QStringLiteral("_default"));
    }

    void currentActivity_emptyStringNormalisesTo_default() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString         cfgPath = d.path() + "/wekrc";
        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("uuid-real");
        helper.setCurrentActivityForTesting(""); // simulate Plasma transition gap
        QCOMPARE(helper.currentActivity(), QStringLiteral("_default"));
    }

    void currentActivity_nullSentinelNormalisesTo_default() {
        QTemporaryDir d;
        QVERIFY(d.isValid());
        const QString         cfgPath = d.path() + "/wekrc";
        wekde::ActivityHelper helper(cfgPath);
        helper.setCurrentActivityForTesting("00000000-0000-0000-0000-000000000000");
        QCOMPARE(helper.currentActivity(), QStringLiteral("_default"));
    }
};

QTEST_MAIN(TstActivityHelper)
#include "tst_activityhelper.moc"
