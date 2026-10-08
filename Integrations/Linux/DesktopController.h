#pragma once

#include <QJSEngine>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocalServer>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariant>

class DesktopController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList providers READ providers NOTIFY settingsChanged)
    Q_PROPERTY(QStringList uniqueProviders READ uniqueProviders NOTIFY changed)
    Q_PROPERTY(bool launchAtLogin READ launchAtLogin NOTIFY settingsChanged)
    Q_PROPERTY(QVariantList entries READ entries NOTIFY changed)
    Q_PROPERTY(QVariantList spending READ spending NOTIFY changed)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString costError READ costError NOTIFY changed)
    Q_PROPERTY(QString configError READ configError NOTIFY settingsChanged)
    Q_PROPERTY(QString summary READ summary NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool costBusy READ costBusy NOTIFY changed)
    Q_PROPERTY(bool stale READ stale NOTIFY changed)
    Q_PROPERTY(QString updated READ updated NOTIFY changed)
    Q_PROPERTY(QVariantList alarms READ alarms NOTIFY alarmsChanged)
    Q_PROPERTY(QVariantMap ringingAlarm READ ringingAlarm NOTIFY ringingAlarmChanged)
    Q_PROPERTY(bool isAlarmRinging READ isAlarmRinging NOTIFY ringingAlarmChanged)

public:
    explicit DesktopController(const QString &cliOverride, QObject *parent = nullptr);
    ~DesktopController() override;
    bool listen(const QString &socket);
    QVariantList providers() const { return m_providers; }
    QStringList uniqueProviders() const;
    bool launchAtLogin() const;
    Q_INVOKABLE bool setLaunchAtLogin(bool enabled);
    Q_INVOKABLE bool accountAction(const QString &provider, const QString &action);
    Q_INVOKABLE bool setTopAccount(const QString &provider, int accountIndex);
    Q_INVOKABLE bool moveAccount(const QString &provider, int fromIndex, int toIndex);
    Q_INVOKABLE bool setStarredModel(const QString &provider, const QString &label, const QString &key = QString());
    Q_INVOKABLE bool isStarredModel(const QString &provider, const QString &label, const QString &key = QString()) const;
    Q_INVOKABLE QVariantMap starredModel() const;
    Q_INVOKABLE bool singleBar() const;
    Q_INVOKABLE bool setSingleBar(bool enabled);
    Q_INVOKABLE void refreshAccount(const QString &provider, int accountIndex = 1);
    Q_INVOKABLE bool isAccountRefreshing(const QString &provider, int accountIndex = 1) const;
    Q_INVOKABLE int providerAccountCount(const QString &provider) const;
    QVariantList alarms() const { return m_alarms; }
    QVariantMap ringingAlarm() const { return m_ringingAlarm; }
    bool isAlarmRinging() const { return m_isAlarmRinging; }
    Q_INVOKABLE void dismissAlarm(const QString &alarmId = QString());
    Q_INVOKABLE void snoozeAlarm(const QString &alarmId = QString(), int minutes = 5);
    Q_INVOKABLE void testAlarm();
    Q_INVOKABLE void stopAlarmSound();
    Q_INVOKABLE bool hasArmedAlarm(const QString &provider, const QString &windowKey, const QString &accountLabel = QString()) const;
    Q_INVOKABLE QVariantMap alarmForWindow(const QString &provider, const QString &windowKey, const QString &accountLabel = QString()) const;
    Q_INVOKABLE void toggleAlarm(const QString &provider, const QString &windowKey, const QString &windowLabel, const QString &accountLabel, const QString &resetsAt);
    QVariantList entries() const { return m_entries; }
    QVariantList spending() const { return m_spending; }
    QVariantMap settings() const { return m_settings; }
    QString error() const { return m_error; }
    QString costError() const { return m_costError; }
    QString configError() const { return m_configError; }
    QString summary() const { return m_summary; }
    bool busy() const { return m_usageBatch || m_usage.state() != QProcess::NotRunning; }
    bool costBusy() const { return m_cost.state() != QProcess::NotRunning; }
    bool stale() const;
    QString updated() const;
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void refreshCosts();
    Q_INVOKABLE void showWindow(const QString &page);
    Q_INVOKABLE int cursorX() const;
    Q_INVOKABLE int cursorY() const;
    Q_INVOKABLE bool saveSettings(const QVariantMap &changes);
    Q_INVOKABLE void copySummary();
    Q_INVOKABLE QString resolvedAccentHex() const;
    QJsonObject snapshot() const;

signals:
    void changed();
    void settingsChanged();
    void windowRequested(const QString &page);
    void accountRefreshingChanged();
    void alarmsChanged();
    void ringingAlarmChanged();

private slots:
    void playAlarmSound();
    void onNotificationAction(uint id, const QString &action);

private:
    QJSEngine m_engine;
    QJSValue m_usageModel, m_noticeModel, m_noticeState;
    QProcess m_usage, m_cost, m_catalog, m_accountProcess;
    QString m_refreshingProvider;
    int m_refreshingAccountIndex = 0;
    QVariantList m_providers, m_batchEntries;
    QStringList m_pendingProviders;
    QString m_currentProvider;
    bool m_usageBatch = false, m_batchFailed = false;
    void nextProvider();
    void loadProviders();
    void updateLabels();
    QTimer m_poll, m_clock, m_alarmCheckTimer, m_alarmSoundTimer;
    QVariantList m_alarms;
    QVariantMap m_ringingAlarm;
    bool m_isAlarmRinging = false;
    void checkAlarms();
    void updateQuotaAlarmsFromEntries();
    void triggerAlarm(QVariantMap &alarm);
    void postAlarmNotification(const QVariantMap &alarm);
    QString makeAlarmId(const QString &provider, const QString &accountLabel, const QString &windowKey) const;
    QLocalServer m_server;
    QVariantMap m_settings;
    QVariantList m_entries, m_spending;
    QJsonArray m_barEntries;
    QString m_configPath, m_error, m_costError, m_configError, m_summary;
    qint64 m_updated = 0, m_costUpdated = 0;
    int m_generation = 0;
    bool m_configBlocked = false;
    void loadSettings(const QString &cliOverride);
    bool validate(QVariantMap &settings);
    void probe(QProcess &process, const QStringList &command, bool cost);
    QMap<QString, double> m_previousQuotas;
    void applyDrainingPriority(const QVariantList &entries);
    void updateNotifications(const QVariantList &entries);
    QJSValue call(const QJSValue &module, const QString &function, const QJSValueList &args) const;
};
