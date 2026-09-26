// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QByteArray>
#include <clocale>
#include <cstring>

// KLocalizedString's real .mo-catalog lookup runs through glibc gettext
// underneath, and gettext refuses to translate anything while the process's
// LC_MESSAGES category is the "C" (or POSIX) locale -- it never even looks at
// the language KLocalizedString::setLanguages() asked for. A container with
// no locale packages installed only has the synthetic "C"/"C.utf8" locales,
// so LC_MESSAGES sits on "C" for the whole test process and every i18nc()
// call under test comes back untranslated, no matter what catalog is on
// disk.
//
// Force LC_MESSAGES to a real, installed locale for the duration of a
// translation test. Try the environment's own locale first
// (setlocale(LC_MESSAGES, "") reads LC_ALL/LC_MESSAGES/LANG) so a developer
// whose machine only has, say, de_DE.UTF-8 installed doesn't also need
// en_US -- only fall back to en_US.UTF-8 when the environment resolves to
// one of gettext's untranslatable synthetic locales ("C", "POSIX",
// "C.utf8", "C.UTF-8") or isn't installed at all. That's why the CI job
// installs glibc-langpack-en: it's the fallback of last resort, not the
// only locale this guard will accept. appliedLocale() reports whichever
// locale actually ended up active, so a failing QVERIFY2 can say what was
// tried instead of assuming one hardcoded name.
namespace wek
{
namespace test_i18n
{

class ScopedGettextLocale {
public:
    ScopedGettextLocale(): m_saved(std::setlocale(LC_MESSAGES, nullptr)) {
        if (const char* envLocale = std::setlocale(LC_MESSAGES, ""); isRealLocale(envLocale)) {
            m_applied = QByteArray(envLocale);
            m_ok      = true;
            return;
        }

        if (const char* fallback = std::setlocale(LC_MESSAGES, "en_US.UTF-8");
            isRealLocale(fallback)) {
            m_applied = QByteArray(fallback);
            m_ok      = true;
            return;
        }

        // Neither worked. Report whatever LC_MESSAGES ended up holding so the
        // caller's failure message can say what was tried.
        m_applied = QByteArray(std::setlocale(LC_MESSAGES, nullptr));
        m_ok      = false;
    }

    ~ScopedGettextLocale() { std::setlocale(LC_MESSAGES, m_saved.constData()); }

    ScopedGettextLocale(const ScopedGettextLocale&)            = delete;
    ScopedGettextLocale& operator=(const ScopedGettextLocale&) = delete;

    // False means neither the environment's own locale nor the en_US.UTF-8
    // fallback is installed on this system -- the caller should fail loudly
    // rather than silently test against the untranslated "C" locale.
    bool ok() const { return m_ok; }

    // Whatever LC_MESSAGES got set to, whether or not ok() is true -- lets a
    // failing QVERIFY2 name what was actually tried.
    const QByteArray& appliedLocale() const { return m_applied; }

private:
    // gettext treats all of these as "untranslatable" -- same as never
    // calling setlocale at all -- so picking one up from the environment is
    // no better than the C locale we're trying to escape.
    static bool isRealLocale(const char* locale) {
        if (locale == nullptr) {
            return false;
        }
        return std::strcmp(locale, "C") != 0 && std::strcmp(locale, "POSIX") != 0 &&
               std::strcmp(locale, "C.utf8") != 0 && std::strcmp(locale, "C.UTF-8") != 0;
    }

    QByteArray m_saved;
    QByteArray m_applied;
    bool       m_ok;
};

} // namespace test_i18n
} // namespace wek
