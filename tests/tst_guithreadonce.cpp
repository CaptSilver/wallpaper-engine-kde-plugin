#include <QtTest>
#include <QThread>

#include <atomic>
#include <mutex>

#include "GuiThreadOnce.hpp"

// The plugin's process-wide setup (KCrash, KGlobalAccel shortcuts, the C
// numeric locale) must run once, on the GUI thread. Qt may call
// QQmlExtensionPlugin::registerTypes from its QML type-loader thread when a
// page imports the plugin asynchronously, as System Settings does; setup run
// there created QObjects parented to qApp from the wrong thread.
class TestGuiThreadOnce : public QObject {
    Q_OBJECT
private slots:
    void runsImmediatelyOnTheGuiThread() {
        std::once_flag flag;
        QThread*       ranOn = nullptr;
        wekde::RunOnceOnGuiThread(flag, [&ranOn]() {
            ranOn = QThread::currentThread();
        });
        QCOMPARE(ranOn, qApp->thread());
    }

    void deferredToTheGuiThreadFromAWorker() {
        std::once_flag        flag;
        std::atomic<QThread*> ranOn { nullptr };
        QThread*              worker = QThread::create([&]() {
            wekde::RunOnceOnGuiThread(flag, [&ranOn]() {
                ranOn = QThread::currentThread();
            });
        });
        worker->start();
        QVERIFY(worker->wait(5000));
        delete worker;
        QTRY_COMPARE(ranOn.load(), qApp->thread());
    }

    void runsOnlyOnce() {
        std::once_flag flag;
        int            runs = 0;
        for (int i = 0; i < 3; i++)
            wekde::RunOnceOnGuiThread(flag, [&runs]() {
                runs++;
            });
        QCOMPARE(runs, 1);
    }
};

QTEST_GUILESS_MAIN(TestGuiThreadOnce)
#include "tst_guithreadonce.moc"
