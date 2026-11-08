// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <QQmlAbstractUrlInterceptor>
#include <QString>
#include <QUrl>

// Qt can discover a second, installed qmldir when mixing versioned and
// unversioned imports, even with _stubs first on the import path. Redirect
// only this module's descriptor; leave Qt/KDE and production QML untouched.
class QmlTestStubs : public QQmlAbstractUrlInterceptor {
public:
    QUrl intercept(const QUrl& url, DataType type) override {
        if (type == QmldirFile &&
            url.path().endsWith("/com/github/captsilver/wallpaperEngineKde/qmldir")) {
            return QUrl::fromLocalFile(QStringLiteral(WEK_QML_STUB_DIR "/qmldir"));
        }
        return url;
    }
};
