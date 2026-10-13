#pragma once
#include <QCoreApplication>
#include <QMetaObject>
#include <QThread>

#include <functional>
#include <mutex>
#include <utility>

namespace wekde
{

// Runs `fn` once per `flag`, on the application's GUI thread: right away when
// called there, otherwise queued to it. For process-wide setup a QML plugin
// does, which Qt may reach from its QML type-loader thread when a page
// imports the plugin asynchronously (System Settings loads its pages that
// way). Setup that runs on that thread creates QObjects for a parent in
// another thread -- qApp, KGlobalAccel -- which Qt refuses and warns about.
inline void RunOnceOnGuiThread(std::once_flag& flag, std::function<void()> fn) {
    std::call_once(flag, [&fn]() {
        QCoreApplication* app = QCoreApplication::instance();
        if (app == nullptr || QThread::currentThread() == app->thread()) {
            fn();
            return;
        }
        QMetaObject::invokeMethod(app, std::move(fn), Qt::QueuedConnection);
    });
}

} // namespace wekde
