#pragma once
#include <QObject>

namespace wekde
{

class MigrationHelper : public QObject {
    Q_OBJECT
public:
    explicit MigrationHelper(QObject* parent = nullptr);

    /// True iff a one-shot catsout->captsilver migration should run: the
    /// migration marker (<config>/wekde/migrated-from-catsout) is absent AND the
    /// Plasma appletsrc still references the old catsout plugin URI. No
    /// PATH/process checks — migration is performed in-process. Public for
    /// testing; runIfNeeded() calls it internally.
    bool shouldRun() const;

    /// One-shot migration of wallpaper settings from the old catsout plugin
    /// section to the captsilver section, performed IN-PROCESS via KConfig (no
    /// subprocess, no plasmashell restart). For each containment it copies the
    /// catsout [General] keys into the captsilver [General] group, never
    /// overwriting keys the user already set post-rename, then writes a marker
    /// so subsequent plasma starts skip migration. The per-key merge is
    /// idempotent, so re-entry is harmless; a per-instance guard (m_attempted)
    /// additionally makes a single helper a no-op on repeat calls. Callers are
    /// NOT cross-process serialized and the marker write is unsynchronized, but
    /// that is moot — there is one plasmashell per session. Safe to call on
    /// every plasmoid construction.
    ///
    /// NOTE: scripts/migrate-from-catsout.sh still ships as
    /// /usr/bin/wek-migrate-from-catsout for manual/CLI migration, but
    /// runIfNeeded() does NOT invoke it — the two paths are independent.
    Q_INVOKABLE void runIfNeeded();

private:
    // Per-instance re-entrancy guard: set on the first runIfNeeded() so a single
    // helper never redoes the merge within its lifetime. NOT process-static (that
    // would defeat per-instance unit tests; the plasmoid creates one helper per
    // construction anyway). Cross-process locking is unnecessary — one plasmashell
    // per session.
    bool m_attempted { false };
};

} // namespace wekde
