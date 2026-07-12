#include "ActivityHelper.hpp"

#include <QLoggingCategory>
#include <QStandardPaths>

#include <KConfig>
#include <KConfigGroup>

#ifdef WEK_HAS_PLASMA_ACTIVITIES
#    include <PlasmaActivities/Consumer>
#endif

Q_LOGGING_CATEGORY(lcWekActivity, "wekde.activity")

namespace wekde
{

namespace
{
// Fallback bucket when no Activity is yet known (boot-time race, or build
// without KActivities link).  Reads still resolve through General if absent.
constexpr auto kDefaultActivity = "_default";
constexpr auto kGeneralGroup    = "General";
constexpr auto kActivityPrefix  = "Activity_";

// Sentinel UUID some Plasma builds return when KActivityManagerd is not
// running yet — treat as "no activity known yet" so we never write a stub
// `[Activity_00000000-…]` group.
constexpr auto kNullActivityUuid = "00000000-0000-0000-0000-000000000000";

bool isUnknownActivity(const QString& a) {
    return a.isEmpty() || a == QLatin1String(kNullActivityUuid);
}
} // namespace

ActivityHelper::ActivityHelper(QObject* parent)
    : QObject(parent), m_currentActivity(kDefaultActivity) {
#ifdef WEK_HAS_PLASMA_ACTIVITIES
    // Production path: own a KActivities::Consumer (the class name is kept for
    // source compat even though the package/target is plasma-activities /
    // Plasma::Activities), seed the current activity, and follow it live.  The
    // test ctor skips this so unit tests stay bus-free — no live
    // KActivityManagerd required.
    m_consumer = std::make_unique<KActivities::Consumer>();
    applyCurrentActivity(m_consumer->currentActivity());
    connect(m_consumer.get(),
            &KActivities::Consumer::currentActivityChanged,
            this,
            &ActivityHelper::onConsumerCurrentActivityChanged);
    connect(m_consumer.get(),
            &KActivities::Consumer::activityRemoved,
            this,
            &ActivityHelper::dropActivity);
#endif
}

ActivityHelper::ActivityHelper(const QString& configFile, QObject* parent)
    : QObject(parent), m_configFile(configFile), m_currentActivity(kDefaultActivity) {}

ActivityHelper::~ActivityHelper() = default;

QString ActivityHelper::currentActivity() const { return m_currentActivity; }

QString ActivityHelper::groupNameFor(const QString& activity) const {
    const QString a = isUnknownActivity(activity) ? QString::fromUtf8(kDefaultActivity) : activity;
    return QString::fromUtf8(kActivityPrefix) + a;
}

KConfig* ActivityHelper::config() const {
    if (! m_config) {
        // Test ctor passes an absolute path; the default ctor would, in a real
        // plasmashell deployment, locate the wallpaper plugin's `wekrc` (or
        // appletsrc subkey) via KSharedConfig.  Tests are the only consumer of
        // this code path today (no QML reader is wired to it yet), so we keep
        // the default branch a best-effort guess rather than resolve the real
        // containment config.
        if (m_configFile.isEmpty()) {
            const QString cfg =
                QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
            // Best-effort default; safe to write because KConfig only creates
            // the file on first sync().
            m_config =
                std::make_unique<KConfig>(cfg + QStringLiteral("/wekrc"), KConfig::SimpleConfig);
        } else {
            m_config = std::make_unique<KConfig>(m_configFile, KConfig::SimpleConfig);
        }
    }
    return m_config.get();
}

QString ActivityHelper::readPerActivity(const QString& key) const {
    KConfig*     cfg = config();
    KConfigGroup activityGroup(cfg, groupNameFor(m_currentActivity));
    if (activityGroup.hasKey(key)) {
        return activityGroup.readEntry(key, QString());
    }
    KConfigGroup generalGroup(cfg, QString::fromUtf8(kGeneralGroup));
    if (generalGroup.hasKey(key)) {
        return generalGroup.readEntry(key, QString());
    }
    return QString();
}

void ActivityHelper::setPerActivity(const QString& key, const QVariant& value) {
    KConfig*     cfg = config();
    KConfigGroup group(cfg, groupNameFor(m_currentActivity));
    group.writeEntry(key, value);
    cfg->sync();
}

void ActivityHelper::setForActivity(const QString& activity, const QString& key,
                                    const QVariant& value) {
    KConfig* cfg = config();
    // "all" is the affinity sentinel for "All Activities" — target [General].
    const QString groupName = (activity == QLatin1String("all")) ? QString::fromUtf8(kGeneralGroup)
                                                                 : groupNameFor(activity);
    KConfigGroup  group(cfg, groupName);
    group.writeEntry(key, value);
    cfg->sync();
}

void ActivityHelper::dropActivity(const QString& activity) {
    if (isUnknownActivity(activity)) return; // never drop _default
    KConfig*     cfg = config();
    KConfigGroup group(cfg, groupNameFor(activity));
    group.deleteGroup();
    cfg->sync();
}

void ActivityHelper::applyCurrentActivity(const QString& activity) {
    const QString next =
        isUnknownActivity(activity) ? QString::fromUtf8(kDefaultActivity) : activity;
    if (next == m_currentActivity) return;
    m_currentActivity = next;
    Q_EMIT currentActivityChanged(m_currentActivity);
}

void ActivityHelper::onConsumerCurrentActivityChanged(const QString& activity) {
    applyCurrentActivity(activity);
}

void ActivityHelper::setCurrentActivityForTesting(const QString& activity) {
    applyCurrentActivity(activity);
}

} // namespace wekde
