#pragma once
#include <QObject>
#include <QString>
#include <QVariant>

#include <memory>

class KConfig;

namespace wekde
{

// Per-Activity KConfig accessor.  Plasma 6 ships KActivities (libPlasmaActivities)
// for the current-activity UUID stream; this helper wraps it for QML.  Reads
// route to the `Activity_<uuid>` subgroup with a `General` fallback so existing
// installs without per-Activity entries continue to resolve.  Writes target the
// current Activity's bucket (or an explicit Activity via setForActivity, used by
// "All Activities" affinity + the boot-time migration).
//
// The Consumer dependency is taken via a virtual hook (currentActivity()) so the
// production build can plug in `Plasma::Activities::Consumer` (devel package
// `plasma-activities-devel`) while unit tests inject a fixed activity string and
// drive the KConfig surface directly without needing a live KActivityManagerd.
// Production wiring is enabled at build time by setting the CMake option
// `WEK_HAS_PLASMA_ACTIVITIES`; absent that, currentActivity() returns the
// `"_default"` bucket so the read/write path stays well-defined.
class ActivityHelper : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString currentActivity READ currentActivity NOTIFY currentActivityChanged)
public:
    explicit ActivityHelper(QObject* parent = nullptr);
    // Test-only constructor: inject an absolute config-file path so the helper
    // talks to a temp file instead of the user's shared appletsrc/wekrc.
    ActivityHelper(const QString& configFile, QObject* parent = nullptr);
    ~ActivityHelper() override;

    QString currentActivity() const;

    // Per-Activity read.  Resolution order: [Activity_<currentActivity>] →
    // [General] → empty.  Returns the value as a QString (KConfigGroup's
    // readEntry default).  Callers casting to other types should use the QML
    // map's implicit conversions.
    Q_INVOKABLE QString readPerActivity(const QString& key) const;

    // Write to [Activity_<currentActivity>].  Empty-activity caller drops into
    // the "_default" bucket (matches the read-fallback rule).  The value is
    // serialised through KConfigGroup::writeEntry so a QVariant carrying an int
    // round-trips identically to KCfg-generated writes.
    Q_INVOKABLE void setPerActivity(const QString& key, const QVariant& value);

    // Explicit-Activity write — used by MigrationHelper to seed the boot
    // Activity's bucket from [General] and by the WallpaperPage combo's
    // "All Activities" branch (which targets [General] via empty-activity =
    // "all", i.e. the caller sets activity == QStringLiteral("all") and we
    // route to [General] directly).
    Q_INVOKABLE void setForActivity(const QString& activity, const QString& key,
                                    const QVariant& value);

    // Drop a stale Activity sub-group (called on Consumer::activityRemoved).
    Q_INVOKABLE void dropActivity(const QString& activity);

    // Test seam: override the value currentActivity() returns.  Production
    // wiring (when WEK_HAS_PLASMA_ACTIVITIES is on) drives this from the
    // Consumer signal; tests call it directly to simulate Activity switches.
    Q_INVOKABLE void setCurrentActivityForTesting(const QString& activity);

signals:
    void currentActivityChanged(const QString& activity);

private:
    QString groupNameFor(const QString& activity) const;
    KConfig* config() const;

    QString                 m_configFile; // empty → user's default Plasma config
    mutable std::unique_ptr<KConfig> m_config;
    QString                 m_currentActivity; // mirrors Consumer; "" → "_default"
};

} // namespace wekde
