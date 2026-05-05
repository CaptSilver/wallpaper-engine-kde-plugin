#include "MigrationHelper.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLoggingCategory>
#include <QProcess>
#include <QStandardPaths>
#include <QStringList>

Q_LOGGING_CATEGORY(lcWek, "wekde.migration")

namespace wekde
{

namespace
{
constexpr auto kOldUri    = "com.github.catsout.wallpaperEngineKde";
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
    const QString exe = QStandardPaths::findExecutable(QStringLiteral("wek-migrate-from-catsout"));
    if (exe.isEmpty()) {
        qCWarning(lcWek) << "wek-migrate-from-catsout not on PATH; "
                            "manual migration required";
        return;
    }
    qCInfo(lcWek) << "triggering" << exe << "--auto";
    QProcess::startDetached(exe, QStringList { QStringLiteral("--auto") });
}

} // namespace wekde
