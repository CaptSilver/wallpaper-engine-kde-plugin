#include "MigrationHelper.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QStandardPaths>
#include <QStringList>

#include <KConfig>
#include <KConfigGroup>

Q_LOGGING_CATEGORY(lcWek, "wekde.migration")

namespace wekde
{

namespace
{
constexpr auto kOldUri    = "com.github.catsout.wallpaperEngineKde";
constexpr auto kNewUri    = "com.github.captsilver.wallpaperEngineKde";
constexpr auto kMarkerRel = "wekde/migrated-from-catsout";
constexpr auto kAppletsrc = "plasma-org.kde.plasma.desktop-appletsrc";
} // namespace

MigrationHelper::MigrationHelper(QObject* parent): QObject(parent) {}

bool MigrationHelper::shouldRun() const {
    const QString cfg = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (cfg.isEmpty()) return false;
    if (QFileInfo::exists(cfg + "/" + kMarkerRel)) return false;

    QFile a(cfg + "/" + kAppletsrc);
    if (! a.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
    while (! a.atEnd()) {
        const QByteArray line = a.readLine();
        if (line.contains(kOldUri)) return true;
    }
    return false;
}

void MigrationHelper::runIfNeeded() {
    if (! shouldRun()) return;

    // Migration runs in-process via KConfig — no plasmashell stop/start, no
    // child process, no cgroup-kill window. The script-based predecessor
    // (scripts/migrate-from-catsout.sh) was unreliable: spawning it from
    // QProcess::startDetached and then having the script call
    // `systemctl --user stop plasma-plasmashell.service` killed every PID in
    // plasmashell's control-group, including the script itself. The marker
    // never got written and migration re-fired on every plasma start.

    const QString cfg = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (cfg.isEmpty()) return;
    const QString appletsrcPath = cfg + "/" + kAppletsrc;
    const QString markerPath    = cfg + "/" + kMarkerRel;

    qCInfo(lcWek) << "in-process migration starting; appletsrc:" << appletsrcPath;

    int merged = 0;
    {
        // KConfig::SimpleConfig — no merging with /etc defaults; we want the
        // user's appletsrc verbatim.
        KConfig config(appletsrcPath, KConfig::SimpleConfig);

        KConfigGroup      containments = config.group(QStringLiteral("Containments"));
        const QStringList cids         = containments.groupList();
        for (const QString& cid : cids) {
            KConfigGroup c           = containments.group(cid);
            KConfigGroup wpRoot      = c.group(QStringLiteral("Wallpaper"));
            KConfigGroup catsoutRoot = wpRoot.group(QString::fromUtf8(kOldUri));
            if (! catsoutRoot.exists()) continue;
            KConfigGroup catsoutG = catsoutRoot.group(QStringLiteral("General"));
            KConfigGroup captsilverG =
                wpRoot.group(QString::fromUtf8(kNewUri)).group(QStringLiteral("General"));
            if (! catsoutG.exists()) continue;
            const QStringList keys = catsoutG.keyList();
            for (const QString& key : keys) {
                if (captsilverG.hasKey(key)) continue; // don't overwrite user's post-rename edits
                const QString val = catsoutG.readEntry(key, QString());
                captsilverG.writeEntry(key, val);
                ++merged;
            }
        }
        config.sync();
    }
    qCInfo(lcWek) << "merged" << merged << "key(s) from catsout into captsilver section(s)";

    // Mark migration as done. Even if we merged 0 keys (e.g. there was a
    // catsout-named section with no [General] subgroup), we still consider
    // migration "attempted" — the marker prevents the next plasmashell start
    // from re-entering this code path. Stale catsout sections in appletsrc
    // remain as harmless leftovers; Plasma uses the captsilver wallpaper
    // plugin selected by the containment's `wallpaperplugin=` line.
    QDir().mkpath(QFileInfo(markerPath).absolutePath());
    QFile m(markerPath);
    if (m.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        m.write("ok\n");
        m.close();
        qCInfo(lcWek) << "marker written:" << markerPath;
    } else {
        qCWarning(lcWek) << "failed to write marker:" << markerPath;
    }
}

} // namespace wekde
