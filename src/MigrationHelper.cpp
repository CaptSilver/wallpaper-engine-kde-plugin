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
constexpr auto kOldUri         = "com.github.catsout.wallpaperEngineKde";
constexpr auto kNewUri         = "com.github.captsilver.wallpaperEngineKde";
constexpr auto kMarkerRel      = "wekde/migrated-from-catsout";
constexpr auto kAppletsrc      = "plasma-org.kde.plasma.desktop-appletsrc";
constexpr auto kScreenLockerRc = "kscreenlockerrc";

// Merge a single `[Wallpaper]` subtree's catsout-named subgroup into the
// captsilver-named subgroup, key by key. Returns the number of keys merged
// (zero is normal when the catsout subgroup is absent — that's the no-op case
// the caller skips). The per-key `hasKey` guard preserves any user edit made
// against the captsilver subgroup post-rename, mirroring the appletsrc
// behaviour codified by runIfNeeded_idempotent_secondRunCopiesNothingNew.
int mergeWallpaperSubtree(KConfigGroup wpRoot) {
    KConfigGroup catsoutRoot = wpRoot.group(QString::fromUtf8(kOldUri));
    if (! catsoutRoot.exists()) return 0;
    KConfigGroup catsoutG = catsoutRoot.group(QStringLiteral("General"));
    if (! catsoutG.exists()) return 0;
    KConfigGroup captsilverG =
        wpRoot.group(QString::fromUtf8(kNewUri)).group(QStringLiteral("General"));
    int               merged = 0;
    const QStringList keys   = catsoutG.keyList();
    for (const QString& key : keys) {
        if (captsilverG.hasKey(key)) continue; // don't overwrite user's post-rename edits
        const QString val = catsoutG.readEntry(key, QString());
        captsilverG.writeEntry(key, val);
        ++merged;
    }
    return merged;
}
} // namespace

MigrationHelper::MigrationHelper(QObject* parent): QObject(parent) {}

bool MigrationHelper::shouldRun() const {
    const QString cfg = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation);
    if (cfg.isEmpty()) return false;
    if (QFileInfo::exists(cfg + "/" + kMarkerRel)) return false;

    // Either file can be the trigger — a user whose ONLY catsout reference is
    // in kscreenlockerrc must still kick off the migration. The shell shim's
    // backup/rewrite loops (scripts/migrate-from-catsout.sh:137,161) iterate
    // both files for the same reason.
    auto fileMentionsOldUri = [&](const QString& rel) {
        QFile f(cfg + "/" + rel);
        if (! f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;
        while (! f.atEnd()) {
            if (f.readLine().contains(kOldUri)) return true;
        }
        return false;
    };
    return fileMentionsOldUri(kAppletsrc) || fileMentionsOldUri(kScreenLockerRc);
}

void MigrationHelper::runIfNeeded() {
    if (m_attempted) return; // already attempted by this instance
    m_attempted = true;
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
            KConfigGroup c      = containments.group(cid);
            KConfigGroup wpRoot = c.group(QStringLiteral("Wallpaper"));
            merged += mergeWallpaperSubtree(wpRoot);
        }
        config.sync();
    }
    qCInfo(lcWek) << "merged" << merged << "key(s) from catsout into captsilver section(s)";

    // Lockscreen wallpaper config: parallel path, anchored at [Greeter] rather
    // than iterating [Containments][<id>]. KConfig CREATES the file on write,
    // so guard with QFileInfo::exists() to avoid manufacturing a stub
    // kscreenlockerrc on machines that never set a lockscreen wallpaper.
    const QString lockerPath = cfg + "/" + kScreenLockerRc;
    if (QFileInfo::exists(lockerPath)) {
        KConfig   locker(lockerPath, KConfig::SimpleConfig);
        const int lockerMerged = mergeWallpaperSubtree(
            locker.group(QStringLiteral("Greeter")).group(QStringLiteral("Wallpaper")));
        locker.sync();
        qCInfo(lcWek) << "merged" << lockerMerged
                      << "key(s) from catsout into captsilver in kscreenlockerrc";
        merged += lockerMerged;
    }

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
