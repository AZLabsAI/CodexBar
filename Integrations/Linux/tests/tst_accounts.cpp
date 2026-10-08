#include "../DesktopController.h"

#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

class AccountActionsTest : public QObject {
    Q_OBJECT
private slots:
    void onlySupportedActionsReachTheTerminal() {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());
        const QByteArray originalPath = qgetenv("PATH");
        qputenv("HOME", temporary.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (temporary.path() + "/config").toUtf8());
        qputenv("PATH", temporary.path().toUtf8());
        const auto writeExecutable = [&](const QString &name, const QByteArray &content) {
            QFile file(temporary.filePath(name));
            if (!file.open(QIODevice::WriteOnly) || file.write(content) != content.size()) return false;
            return file.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        };
        QVERIFY(writeExecutable("codex", "#!/bin/sh\nexit 0\n"));
        QVERIFY(writeExecutable("claude", "#!/bin/sh\nexit 0\n"));
        QVERIFY(writeExecutable("fake-cli", "#!/bin/sh\nprintf '[]'\n"));
        qputenv("ACCOUNT_TEST_LOG", temporary.filePath("arguments").toUtf8());
        // Make the create-before-write race deterministic, including on fast runners.
        QVERIFY(writeExecutable("xdg-terminal-exec",
            "#!/bin/sh\nexec > \"$ACCOUNT_TEST_LOG\"\n/bin/sleep 0.2\nprintf '%s\\n' \"$@\"\n"));
        DesktopController controller(temporary.filePath("fake-cli"));
        QVERIFY(!controller.accountAction("codex;anything", "login"));
        QVERIFY(!controller.accountAction("codex", "unrecognized"));
        QVERIFY(!QFile::exists(temporary.filePath("arguments")));
        // The shell's redirect creates the log before printf fills it, so wait for the contents,
        // not just the file.
        const auto logged = [&] {
            QFile file(temporary.filePath("arguments"));
            return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
        };
        QVERIFY(controller.accountAction("claude", "login"));
        QTRY_COMPARE(logged(), QByteArray("--hold\n--\n") + temporary.filePath("claude").toUtf8() + "\nauth\nlogin\n");
        QVERIFY(QFile::remove(temporary.filePath("arguments")));
        QVERIFY(controller.accountAction("codex", "logout"));
        QTRY_COMPARE(logged(), QByteArray("--hold\n--\n") + temporary.filePath("codex").toUtf8() + "\nlogout\n");
        qputenv("PATH", originalPath);
    }

    void quotaResetAlarmsCanBeArmedTriggeredAndDismissed() {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());
        const auto writeExecutable = [&](const QString &name, const QByteArray &content) {
            QFile file(temporary.filePath(name));
            if (!file.open(QIODevice::WriteOnly) || file.write(content) != content.size()) return false;
            return file.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        };
        QVERIFY(writeExecutable("fake-cli", "#!/bin/sh\nprintf '[]'\n"));
        DesktopController controller(temporary.filePath("fake-cli"));

        // Initially no alarms
        QVERIFY(!controller.isAlarmRinging());
        QVERIFY(!controller.hasArmedAlarm("codex", "primary", "aubrey.zemba@dyedurham.com"));

        // Arm an alarm
        controller.toggleAlarm("codex", "primary", "5-hour", "aubrey.zemba@dyedurham.com", "2026-10-08T05:35:00Z");
        QVERIFY(controller.hasArmedAlarm("codex", "primary", "aubrey.zemba@dyedurham.com"));
        auto armed = controller.alarmForWindow("codex", "primary", "aubrey.zemba@dyedurham.com");
        QCOMPARE(armed.value("windowLabel").toString(), QString("5-hour"));
        QCOMPARE(armed.value("accountLabel").toString(), QString("aubrey.zemba@dyedurham.com"));
        QCOMPARE(armed.value("status").toString(), QString("armed"));

        // Trigger test alarm
        controller.testAlarm();
        QVERIFY(controller.isAlarmRinging());
        auto ringing = controller.ringingAlarm();
        QCOMPARE(ringing.value("status").toString(), QString("ringing"));
        QCOMPARE(ringing.value("provider").toString(), QString("codex"));
        QCOMPARE(ringing.value("accountLabel").toString(), QString("aubrey.zemba@dyedurham.com"));
        QCOMPARE(ringing.value("restoredRemaining").toInt(), 100);

        // Dismiss alarm
        controller.dismissAlarm();
        QVERIFY(!controller.isAlarmRinging());
        QVERIFY(controller.ringingAlarm().isEmpty());

        // Snooze functionality
        controller.testAlarm();
        QVERIFY(controller.isAlarmRinging());
        controller.snoozeAlarm("test/alarm", 5);
        QVERIFY(!controller.isAlarmRinging());
    }
};

QTEST_GUILESS_MAIN(AccountActionsTest)
#include "tst_accounts.moc"
