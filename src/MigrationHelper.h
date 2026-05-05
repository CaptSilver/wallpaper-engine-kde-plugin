#pragma once
#include <QObject>

namespace wekde {

class MigrationHelper : public QObject {
    Q_OBJECT
public:
    explicit MigrationHelper(QObject* parent = nullptr);

    /// True iff a migration script invocation should be triggered.
    /// Public for testing; runIfNeeded() uses it internally.
    bool shouldRun() const;

    /// Trigger conditions: marker absent + appletsrc contains old catsout URI
    /// + script binary on PATH. Spawns wek-migrate-from-catsout via
    /// QProcess::startDetached when all conditions hold. Idempotent and safe
    /// to call multiple times — concurrent invocations dedupe at the script
    /// level via flock.
    Q_INVOKABLE void runIfNeeded();
};

} // namespace wekde
