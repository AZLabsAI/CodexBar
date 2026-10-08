#include "DesktopController.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QCryptographicHash>
#include <QCursor>
#include <QDateTime>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCall>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>
#include <algorithm>
#include <csignal>
#include <memory>
#include <unistd.h>

namespace {
QJSValue module(QJSEngine &engine, const QString &path, const QString &exports) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) qFatal("Missing bundled model");
    auto result = engine.evaluate("(function(){\n" + QString::fromUtf8(file.readAll()) +
        "\nreturn {" + exports + "};})()", path);
    if (result.isError()) qFatal("Unable to load bundled model");
    return result;
}
void stop(QProcess &process) {
    if (process.state() == QProcess::NotRunning) return;
    const auto pid = process.processId();
    if (pid > 0) ::kill(-pid, SIGKILL);
    process.kill();
    process.waitForFinished(1000);
}
}

DesktopController::DesktopController(const QString &cliOverride, QObject *parent) : QObject(parent) {
    m_usageModel = module(m_engine, ":/Shared/Usage.js", "rows:rows, costs:costs, command:command, summary:summary, barSegments:barSegments, resetText:resetText, progressBarColor:progressBarColor");
    m_noticeModel = module(m_engine, ":/Shared/Notifications.js", "transition:transition, summary:summary");
    m_noticeState = m_engine.newObject();
    loadSettings(cliOverride);
    loadProviders();
    connect(&m_poll, &QTimer::timeout, this, &DesktopController::refresh);
    m_poll.start(m_settings.value("refreshSeconds").toInt() * 1000);
    connect(&m_clock, &QTimer::timeout, this, &DesktopController::changed);
    m_clock.start(30000);
    connect(&m_alarmCheckTimer, &QTimer::timeout, this, &DesktopController::checkAlarms);
    m_alarmCheckTimer.start(1000);
    connect(&m_alarmSoundTimer, &QTimer::timeout, this, &DesktopController::playAlarmSound);
    QDBusConnection::sessionBus().connect(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "ActionInvoked",
        this,
        SLOT(onNotificationAction(uint, QString)));
    QTimer::singleShot(0, this, &DesktopController::refresh);
}

DesktopController::~DesktopController() {
    m_alarmSoundTimer.stop();
    m_alarmCheckTimer.stop();
    m_usage.disconnect(this); m_cost.disconnect(this);
    m_accountProcess.disconnect(this); stop(m_usage); stop(m_cost); stop(m_catalog); stop(m_accountProcess);
}

QJSValue DesktopController::call(const QJSValue &model, const QString &function, const QJSValueList &args) const {
    return model.property(function).call(args);
}

bool DesktopController::validate(QVariantMap &values) {
    if (!QRegularExpression("^[a-z0-9-]{1,80}$").match(values.value("provider").toString()).hasMatch()) {
        m_configError = "Enter a provider ID such as codex, claude, both, or enabled."; return false;
    }
    if (!QStringList{"auto", "oauth", "cli", "api", "web"}.contains(values.value("source").toString())) {
        m_configError = "Unsupported provider source."; return false;
    }
    if (values.value("executable").toString().trimmed().isEmpty()) {
        m_configError = "Specify the CodexBar CLI executable."; return false;
    }
    for (const auto &key : {"refreshSeconds", "accountIndex", "notifyThreshold"}) {
        bool ok = false;
        const int number = values.value(key).toInt(&ok);
        const int min = QString(key) == "refreshSeconds" ? 60 : QString(key) == "notifyThreshold" ? 1 : 0;
        const int max = QString(key) == "refreshSeconds" ? 3600 : QString(key) == "notifyThreshold" ? 99 : 999;
        if (!ok || number < min || number > max) { m_configError = QString("Invalid %1.").arg(key); return false; }
        values[key] = number;
    }
    const auto order = values.value("providerOrder").toStringList();
    if (order.size() > 80 || (values.value("provider") == "custom" && order.isEmpty())) {
        m_configError = "Choose at least one provider (maximum 80)."; return false;
    }
    QStringList unique;
    for (const auto &id : order) {
        if (!QRegularExpression("^[a-z0-9-]{1,80}$").match(id).hasMatch() ||
            QStringList{"all", "both", "enabled", "custom"}.contains(id) || unique.contains(id)) {
            m_configError = "The provider list contains an invalid or duplicate ID."; return false;
        }
        unique.append(id);
    }
    values["providerOrder"] = unique;
    if (!QStringList{"remaining", "used"}.contains(values.value("quotaDisplay").toString()) ||
        !QStringList{"countdown", "absolute", "both"}.contains(values.value("resetDisplay").toString()) ||
        !QStringList{"meters", "icon"}.contains(values.value("trayStyle").toString())) {
        m_configError = "Unsupported display preference."; return false;
    }
    for (const auto &key : {"allAccounts", "showIdentity", "showCosts", "showStatus", "notifications", "showTray", "refreshOnOpen", "showPace", "warningColors", "followOmarchyTheme", "sidebarPinned", "sidebarCollapsed", "sidebarHoverBrighten", "alarmEnabled", "alarmSound"})
        if (values.contains(key)) values[key] = values.value(key).toBool();
    for (const auto &key : {"sidebarOpacity", "windowOpacity", "miniOpacity"}) {
        if (values.contains(key)) {
            bool ok = false;
            double op = values.value(key).toDouble(&ok);
            if (ok && op >= 0.20 && op <= 1.0) values[key] = op;
        }
    }
    if (values.contains("sidebarSide")) {
        const auto side = values.value("sidebarSide").toString();
        if (side == "left" || side == "right") values["sidebarSide"] = side;
    }
    if (values.contains("themeMode")) {
        const auto mode = values.value("themeMode").toString();
        if (QStringList{"dark", "light", "system"}.contains(mode)) values["themeMode"] = mode;
    }
    if (values.contains("accentColor")) {
        values["accentColor"] = values.value("accentColor").toString();
    }
    if (values.contains("singleBar")) {
        values["singleBar"] = values.value("singleBar").toBool();
    }
    if (values.contains("starredModel")) {
        values["starredModel"] = values.value("starredModel").toMap();
    }
    return true;
}

void DesktopController::loadSettings(const QString &cliOverride) {
    m_settings = {{"executable", "codexbar"}, {"provider", "codex"}, {"source", "auto"},
        {"refreshSeconds", 300}, {"accountIndex", 0}, {"notifyThreshold", 25}, {"allAccounts", true},
        {"showIdentity", false}, {"showCosts", true}, {"showStatus", true}, {"notifications", true}, {"showTray", true}, {"refreshOnOpen", false}, {"providerOrder", QStringList{}},
        {"quotaDisplay", "remaining"}, {"resetDisplay", "countdown"}, {"showPace", true},
        {"warningColors", true}, {"trayStyle", "meters"}, {"followOmarchyTheme", false}, {"starredModel", QVariantMap{}},
        {"singleBar", true},
        {"sidebarOpacity", 0.85}, {"sidebarSide", "right"}, {"sidebarPinned", true}, {"sidebarCollapsed", false}, {"sidebarHoverBrighten", true},
        {"themeMode", "dark"}, {"accentColor", "violet"}, {"windowOpacity", 0.95}, {"miniOpacity", 0.90},
        {"alarmEnabled", true}, {"alarmSound", true}};
    m_configPath = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/codexbar/linux.json";
    QFile file(m_configPath);
    QVariantMap candidate = m_settings;
    if (file.open(QIODevice::ReadOnly)) {
        QJsonParseError parse;
        const auto document = QJsonDocument::fromJson(file.readAll(), &parse);
        if (parse.error != QJsonParseError::NoError || !document.isObject()) {
            m_configBlocked = true;
            m_configError = "Invalid linux.json. Fix or remove it and restart CodexBar before saving.";
        } else {
            const auto loaded = document.object().toVariantMap();
            for (auto it = loaded.begin(); it != loaded.end(); ++it) if (candidate.contains(it.key())) candidate[it.key()] = it.value();
            if (validate(candidate)) m_settings = candidate;
            else m_configBlocked = true;
        }
    }
    if (file.exists() && !file.isOpen()) {
        m_configBlocked = true;
        m_configError = "Cannot read linux.json. Check permissions and restart CodexBar.";
    }
    if (!cliOverride.isEmpty()) m_settings["executable"] = cliOverride;
}

bool DesktopController::saveSettings(const QVariantMap &changes) {
    if (m_configBlocked) { emit settingsChanged(); return false; }
    QVariantMap next = m_settings;
    for (auto it = changes.begin(); it != changes.end(); ++it) {
        if (!next.contains(it.key())) { m_configError = "Unknown setting: " + it.key(); emit settingsChanged(); return false; }
        next[it.key()] = it.value();
    }
    if (!validate(next)) { emit settingsChanged(); return false; }
    QDir().mkpath(QFileInfo(m_configPath).absolutePath());
    QSaveFile file(m_configPath);
    if (!file.open(QIODevice::WriteOnly)) { m_configError = "Cannot write application settings."; emit settingsChanged(); return false; }
    file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    const auto encoded = QJsonDocument::fromVariant(next).toJson(QJsonDocument::Indented);
    if (file.write(encoded) != encoded.size() || !file.commit()) {
        m_configError = "Cannot save application settings."; emit settingsChanged(); return false;
    }
    bool queryChanged = false;
    for (const auto &key : {"provider", "providerOrder", "source", "executable", "accountIndex", "allAccounts", "showIdentity", "showStatus", "showCosts"})
        queryChanged = queryChanged || next.value(key) != m_settings.value(key);
    m_settings = next; m_configError.clear();
    if (queryChanged) {
        ++m_generation;
        if (m_usage.state() == QProcess::NotRunning) { m_usageBatch = false; m_pendingProviders.clear(); }
        m_entries.clear(); m_spending.clear(); m_updated = 0; m_costUpdated = 0;
    }
    updateLabels();
    m_noticeState = m_engine.newObject();
    m_poll.start(m_settings.value("refreshSeconds").toInt() * 1000);
    emit settingsChanged(); emit changed(); if (queryChanged) refresh();
    return true;
}

bool DesktopController::stale() const {
    return m_updated > 0 && (!m_error.isEmpty() || QDateTime::currentMSecsSinceEpoch() - m_updated >
        qMax(600000, m_settings.value("refreshSeconds").toInt() * 2000));
}

QString DesktopController::updated() const {
    return m_updated ? QDateTime::fromMSecsSinceEpoch(m_updated).toLocalTime().toString("HH:mm") : QString();
}

QStringList DesktopController::uniqueProviders() const {
    QStringList result;
    for (const auto &item : m_entries) {
        const QString p = item.toMap().value("provider").toString();
        if (!p.isEmpty() && !result.contains(p)) result.append(p);
    }
    return result;
}

void DesktopController::refresh() {
    if (busy()) return;
    m_usageBatch = true; m_batchFailed = false; m_batchEntries.clear();
    m_pendingProviders = m_settings.value("provider") == "custom" ? m_settings.value("providerOrder").toStringList() :
        QStringList{m_settings.value("provider").toString()};
    nextProvider();
}

void DesktopController::nextProvider() {
    if (m_usage.state() != QProcess::NotRunning) return;
    if (m_pendingProviders.isEmpty()) return;
    m_currentProvider = m_pendingProviders.takeFirst();
    auto selection = m_settings;
    selection["provider"] = m_currentProvider;
    if (m_settings.value("provider") == "custom") { selection["accountIndex"] = 0; }
    auto args = call(m_usageModel, "command", {m_engine.toScriptValue(selection)}).toVariant().toStringList();
    // Process deadlines and groups are managed here, without a coreutils dependency.
    args = args.mid(3);
    probe(m_usage, args, false);
}

void DesktopController::refreshCosts() {
    if (costBusy() || !m_settings.value("showCosts").toBool()) return;
    probe(m_cost, {m_settings.value("executable").toString(), "cost", "--provider", "both", "--format", "json", "--days", "30"}, true);
}

void DesktopController::probe(QProcess &process, const QStringList &command, bool cost) {
    process.disconnect(this);
    auto output = std::make_shared<QByteArray>();
    auto complete = std::make_shared<bool>(false);
    const int generation = m_generation;
    auto *deadline = new QTimer(&process);
    deadline->setSingleShot(true);
    connect(deadline, &QTimer::timeout, &process, [&process] { stop(process); });
    auto finish = [this, &process, output, complete, generation, cost, deadline](bool failed) {
        if (*complete) return;
        *complete = true; deadline->stop(); deadline->deleteLater();
        if (generation != m_generation) {
            if (!cost) { m_usageBatch = false; m_pendingProviders.clear(); }
            QTimer::singleShot(0, this, cost ? &DesktopController::refreshCosts : &DesktopController::refresh);
            return;
        }
        output->append(process.readAllStandardOutput());
        QJSValueList arguments{QString::fromUtf8(*output)};
        if (!cost) arguments.append(m_settings.value("showIdentity").toBool());
        const auto parsed = call(m_usageModel, cost ? "costs" : "rows", arguments);
        const bool invalid = failed || parsed.isError() || !parsed.isArray() || output->size() > 8 * 1024 * 1024;
        if (cost) {
            if (invalid) m_costError = "Local spending could not be refreshed. Previous data may be stale.";
            else { m_spending = parsed.toVariant().toList(); m_costError.clear(); m_costUpdated = QDateTime::currentMSecsSinceEpoch(); }
        } else {
            if (invalid) {
                m_batchFailed = true;
                for (const auto &entry : m_entries) {
                    if (m_settings.value("provider") != "custom" || entry.toMap().value("provider") == m_currentProvider)
                        m_batchEntries.append(entry);
                }
                if (m_settings.value("provider") == "custom" && !std::any_of(m_batchEntries.begin(), m_batchEntries.end(),
                    [this](const QVariant &entry) { return entry.toMap().value("provider") == m_currentProvider; }))
                    m_batchEntries.append(QVariantMap{{"provider", m_currentProvider}, {"windows", QVariantList{}},
                        {"error", "Usage unavailable"}, {"failed", true}});
            } else m_batchEntries.append(parsed.toVariant().toList());
            if (!m_pendingProviders.isEmpty()) {
                QTimer::singleShot(0, this, &DesktopController::nextProvider);
                return;
            }
            m_usageBatch = false;
            applyDrainingPriority(m_batchEntries);
            updateLabels();
            if (m_batchFailed) {
                m_error = "Some usage could not be refreshed. Previous results may be out of date.";
                m_noticeState = m_engine.newObject();
            } else {
                m_error.clear(); m_updated = QDateTime::currentMSecsSinceEpoch(); updateNotifications(m_entries);
            }
        }
        emit changed();
    };
    connect(&process, &QProcess::readyReadStandardOutput, this, [&process, output] {
        output->append(process.readAllStandardOutput());
        if (output->size() > 8 * 1024 * 1024) stop(process);
    });
    connect(&process, &QProcess::readyReadStandardError, this, [&process] { process.readAllStandardError(); });
    connect(&process, &QProcess::finished, this, [finish](int, QProcess::ExitStatus status) { finish(status != QProcess::NormalExit); });
    connect(&process, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) finish(true);
    });
    process.setChildProcessModifier([] { ::setsid(); });
    process.start(command.first(), command.mid(1));
    deadline->start(60000);
    emit changed();
}

void DesktopController::updateNotifications(const QVariantList &entries) {
    const auto result = call(m_noticeModel, "transition", {m_noticeState, m_engine.toScriptValue(entries),
        m_settings.value("notifyThreshold").toInt()});
    if (result.isError()) return;
    m_noticeState = result.property("state");
    const auto events = result.property("events").toVariant().toList();
    for (const auto &item : events) {
        auto event = item.toMap();
        QString kind = event.value("kind").toString();
        if (kind == "alarm") {
            QVariantMap alarm;
            QString prov = event.value("provider").toString();
            QString acc = event.value("accountLabel").toString();
            QString winKey = event.value("windowKey").toString();
            alarm["id"] = makeAlarmId(prov, acc, winKey);
            alarm["provider"] = prov;
            alarm["accountLabel"] = acc;
            alarm["windowKey"] = winKey;
            alarm["windowLabel"] = event.value("windowLabel").toString();
            alarm["resetsAt"] = event.value("resetsAt").toString();
            alarm["restoredRemaining"] = event.value("remaining", 100).toInt();
            alarm["status"] = "ringing";
            alarm["triggeredAt"] = QDateTime::currentMSecsSinceEpoch();
            triggerAlarm(alarm);
        } else if (kind == "depleted") {
            QString prov = event.value("provider").toString();
            QString acc = event.value("accountLabel").toString();
            QString winKey = event.value("windowKey").toString();
            QString resetsAt = event.value("resetsAt").toString();
            QString id = makeAlarmId(prov, acc, winKey);
            bool exists = false;
            for (const auto &existing : m_alarms) {
                auto a = existing.toMap();
                if (a.value("id").toString() == id && a.value("status").toString() == "armed") {
                    exists = true;
                    break;
                }
            }
            if (!exists && !resetsAt.isEmpty()) {
                QVariantMap alarm;
                alarm["id"] = id;
                alarm["provider"] = prov;
                alarm["accountLabel"] = acc;
                alarm["windowKey"] = winKey;
                alarm["windowLabel"] = event.value("windowLabel").toString();
                alarm["resetsAt"] = resetsAt;
                alarm["resetsAtMs"] = QDateTime::fromString(resetsAt, Qt::ISODate).toMSecsSinceEpoch();
                alarm["status"] = "armed";
                alarm["armedAt"] = QDateTime::currentMSecsSinceEpoch();
                m_alarms.append(alarm);
                emit alarmsChanged();
            }
        }
    }
    if (!m_settings.value("notifications").toBool()) return;
    for (const auto &item : events) {
        auto event = item.toMap();
        if (event.value("kind").toString() == "alarm") continue; // Handled specially by postAlarmNotification
        auto message = QDBusMessage::createMethodCall("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications", "Notify");
        message.setArguments({"CodexBar", uint(0), "codexbar", "CodexBar · " + event.value("provider").toString(),
            event.value("message").toString(), QStringList(), QVariantMap(), 8000});
        QDBusConnection::sessionBus().asyncCall(message);
    }
}

void DesktopController::copySummary() {
    QGuiApplication::clipboard()->setText(call(m_noticeModel, "summary", {m_engine.toScriptValue(m_entries)}).toString());
}

QString DesktopController::resolvedAccentHex() const {
    const QString accent = m_settings.value("accentColor", "violet").toString();
    if (accent == "violet") return "#8b5cf6";
    if (accent == "blue") return "#3b82f6";
    if (accent == "cyan") return "#06b6d4";
    if (accent == "emerald") return "#10b981";
    if (accent == "orange") return "#f97316";
    if (accent == "rose") return "#f43f5e";
    if (accent == "amber") return "#f59e0b";
    if (accent.startsWith("#") && QColor::isValidColorName(accent)) return accent;
    return "#8b5cf6";
}

void DesktopController::showWindow(const QString &page) {
    if (page == "spending" && QDateTime::currentMSecsSinceEpoch() - m_costUpdated > 300000) refreshCosts();
    if ((page == "usage" || page == "mini" || page == "sidebar" || page == "dock") && m_settings.value("refreshOnOpen").toBool()) refresh();
    emit windowRequested(page);
}

int DesktopController::cursorX() const {
    return QCursor::pos().x();
}

int DesktopController::cursorY() const {
    return QCursor::pos().y();
}

void DesktopController::applyDrainingPriority(const QVariantList &entries) {
    QVariantMap prevMap;
    for (auto it = m_previousQuotas.begin(); it != m_previousQuotas.end(); ++it) {
        prevMap[it.key()] = it.value();
    }
    const auto prioritized = call(m_usageModel, "prioritizeDrainingAccounts",
        {m_engine.toScriptValue(entries), m_engine.toScriptValue(prevMap)});
    if (prioritized.isArray()) {
        m_entries = prioritized.toVariant().toList();
    } else {
        m_entries = entries;
    }
    for (const auto &entry : m_entries) {
        const auto map = entry.toMap();
        const auto provider = map.value("provider").toString();
        const int accNum = map.value("accountNumber", 1).toInt();
        const auto accKey = provider + ":" + QString::number(accNum);
        for (const auto &wItem : map.value("windows").toList()) {
            const auto wMap = wItem.toMap();
            const auto wKey = wMap.value("key").toString();
            m_previousQuotas[accKey + "/" + wKey] = wMap.value("remaining").toDouble();
        }
    }
    updateQuotaAlarmsFromEntries();
}

void DesktopController::updateLabels() {
    const auto rows = m_engine.toScriptValue(m_entries);
    const auto mode = m_settings.value("quotaDisplay").toString();
    const auto starred = m_engine.toScriptValue(m_settings.value("starredModel"));
    const bool single = m_settings.value("singleBar", true).toBool();
    QVariantMap prevMap;
    for (auto it = m_previousQuotas.begin(); it != m_previousQuotas.end(); ++it) {
        prevMap[it.key()] = it.value();
    }
    const auto prevValue = m_engine.toScriptValue(prevMap);
    m_summary = call(m_usageModel, "summary", {rows, mode, starred, single, prevValue}).toString();
    m_barEntries = QJsonArray::fromVariantList(call(m_usageModel, "barSegments", {rows, mode, starred, single, prevValue}).toVariant().toList());
}

QJsonObject DesktopController::snapshot() const {
    static const auto extraKeySalt = QUuid::createUuid().toRfc4122();
    QJsonArray compact;
    for (const auto &entry : m_entries) {
        auto row = entry.toMap();
        QJsonArray windows;
        for (const auto &item : row.value("windows").toList()) {
            auto window = item.toMap();
            const auto key = window.value("key").toString();
            if (key.startsWith("extra:")) {
                // Keep provider-controlled IDs opaque over IPC and stable within this backend process.
                const auto identity = row.value("provider").toString() + "/" + key;
                window["key"] = "extra:" + QString::fromLatin1(
                    QCryptographicHash::hash(extraKeySalt + identity.toUtf8(), QCryptographicHash::Sha256).toHex());
            }
            const auto remaining = window.value("remaining").toDouble();
            const auto used = 100.0 - remaining;
            window["displayValue"] = m_settings.value("quotaDisplay") == "used" ? 100 - remaining : remaining;
            window["displaySuffix"] = m_settings.value("quotaDisplay") == "used" ? "used" : "left";
            window["warning"] = m_settings.value("warningColors").toBool() && (used >= 75.0 || remaining <= 25.0);
            window["critical"] = m_settings.value("warningColors").toBool() && (used >= 90.0 || remaining <= 10.0);
            window["barColor"] = (used >= 90.0 || remaining <= 10.0) ? "#ff3b30" : ((used >= 75.0 || remaining <= 25.0) ? "#ff9500" : "");
            // This model contains no identity; display fields keep adapters consistent with native windows.
            window["resetText"] = call(m_usageModel, "resetText",
                {window.value("resetsAt").toString(), double(QDateTime::currentMSecsSinceEpoch()), m_settings.value("resetDisplay").toString()}).toString();
            windows.append(QJsonObject::fromVariantMap(window));
        }
        compact.append(QJsonObject{
            {"provider", row.value("provider").toString()},
            {"windows", windows},
            {"error", row.value("error").toString()}
        });
    }
    return {{"schemaVersion", 1}, {"pid", QCoreApplication::applicationPid()}, {"summary", m_summary}, {"barEntries", m_barEntries}, {"starredModel", QJsonObject::fromVariantMap(m_settings.value("starredModel").toMap())}, {"singleBar", m_settings.value("singleBar", true).toBool()},
        {"entries", compact}, {"quotaDisplay", m_settings.value("quotaDisplay").toString()}, {"busy", busy()}, {"stale", stale()}, {"error", m_error},
        {"updated", updated()}, {"costBusy", costBusy()}, {"costProviders", m_spending.size()}, {"costError", m_costError},
        {"isAlarmRinging", m_isAlarmRinging}, {"ringingAlarm", QJsonObject::fromVariantMap(m_ringingAlarm)}, {"alarmsCount", m_alarms.size()}};
}

bool DesktopController::listen(const QString &socketPath) {
    m_server.setSocketOptions(QLocalServer::UserAccessOption);
    QLocalServer::removeServer(socketPath); // Caller holds the exclusive application lock.
    if (!m_server.listen(socketPath)) return false;
    connect(&m_server, &QLocalServer::newConnection, this, [this] {
        while (auto *socket = m_server.nextPendingConnection()) {
            socket->setReadBufferSize(65537);
            auto input = std::make_shared<QByteArray>();
            connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
            QTimer::singleShot(3000, socket, [socket] { socket->disconnectFromServer(); });
            connect(socket, &QLocalSocket::readyRead, this, [this, socket, input] {
                input->append(socket->readAll());
                if (input->size() > 65536) { socket->disconnectFromServer(); return; }
                if (!input->contains('\n')) return;
                const auto request = QJsonDocument::fromJson(input->left(input->indexOf('\n'))).object();
                const auto command = request.value("command").toString();
                QJsonObject response{{"ok", true}};
                if (command == "snapshot" || command == "background") response = snapshot();
                else if (command == "autostart") {
                    const auto action = request.value("action").toString();
                    const bool ok = action == "status" || ((action == "enable" || action == "disable") && setLaunchAtLogin(action == "enable"));
                    response = {{"ok", ok}, {"enabled", launchAtLogin()}};
                }
                else if (command == "refresh") { refresh(); refreshCosts(); }
                else if (command == "refresh-account") {
                    const auto provider = request.value("provider").toString();
                    const int account = request.value("account").toInt(1);
                    refreshAccount(provider, account);
                    response = {{"ok", true}, {"provider", provider}, {"account", account}};
                }
                else if (command == "settings" || command == "usage" || command == "spending" || command == "mini" || command == "sidebar" || command == "dock") showWindow(command);
                else if (command == "configure" && request.value("settings").isObject()) {
                    const bool ok = saveSettings(request.value("settings").toObject().toVariantMap());
                    response = {{"ok", ok}, {"error", m_configError}};
                } else if (command == "quit") QTimer::singleShot(100, qApp, &QCoreApplication::quit);
                else response = {{"ok", false}, {"error", "Unknown command"}};
                socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact) + '\n');
                socket->disconnectFromServer();
            });
        }
    });
    return true;
}

void DesktopController::loadProviders() {
    for (const auto &id : {"codex", "claude", "cursor", "gemini", "copilot", "antigravity"})
        m_providers.append(QVariantMap{{"provider", id}, {"displayName", QString(id)}});
    auto output = std::make_shared<QByteArray>();
    auto *deadline = new QTimer(&m_catalog);
    deadline->setSingleShot(true);
    connect(deadline, &QTimer::timeout, &m_catalog, [this] { stop(m_catalog); });
    connect(&m_catalog, &QProcess::readyReadStandardOutput, this, [this, output] {
        output->append(m_catalog.readAllStandardOutput());
        if (output->size() > 1024 * 1024) stop(m_catalog);
    });
    connect(&m_catalog, &QProcess::readyReadStandardError, this, [this] { m_catalog.readAllStandardError(); });
    connect(&m_catalog, &QProcess::finished, this, [this, output, deadline](int code, QProcess::ExitStatus status) {
        deadline->stop();
        if (code || status != QProcess::NormalExit || output->size() > 1024 * 1024) return;
        const auto document = QJsonDocument::fromJson(*output);
        if (!document.isArray()) return;
        QVariantList providers;
        for (const auto &item : document.array()) {
            const auto row = item.toObject();
            const auto id = row.value("provider").toString();
            const auto name = row.value("displayName").toString();
            if (QRegularExpression("^[a-z0-9-]{1,80}$").match(id).hasMatch() && !name.isEmpty())
                providers.append(QVariantMap{{"provider", id}, {"displayName", name.left(100)}});
        }
        if (!providers.isEmpty()) { m_providers = providers; emit settingsChanged(); }
    });
    m_catalog.setChildProcessModifier([] { ::setsid(); });
    m_catalog.start(m_settings.value("executable").toString(), {"config", "providers", "--format", "json"});
    deadline->start(10000);
}

bool DesktopController::launchAtLogin() const {
    QFile file(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
        "/autostart/com.steipete.CodexBar.desktop");
    if (!file.open(QIODevice::ReadOnly)) return false;
    return !QString::fromUtf8(file.readAll()).contains(QRegularExpression("(^|\n)Hidden\\s*=\\s*true(\n|$)"));
}

bool DesktopController::setLaunchAtLogin(bool enabled) {
    const auto path = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) +
        "/autostart/com.steipete.CodexBar.desktop";
    QDir().mkpath(QFileInfo(path).absolutePath());
    QString executable = QCoreApplication::applicationFilePath();
    if (executable.contains('\n') || executable.contains('\r')) return false;
    executable.replace("%", "%%");
    for (const auto &character : {QString("\\"), QString("\""), QString("`"), QString("$")})
        executable.replace(character, "\\" + character);
    const auto content = QString("[Desktop Entry]\nType=Application\nName=CodexBar\nExec=\"%1\" --background\nIcon=codexbar\nTerminal=false\nHidden=%2\n")
        .arg(executable, enabled ? "false" : "true").toUtf8();
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(content) != content.size() || !file.commit()) {
        m_configError = "Cannot update login startup."; emit settingsChanged(); return false;
    }
    m_configError.clear(); emit settingsChanged(); return true;
}

bool DesktopController::accountAction(const QString &provider, const QString &action) {
    if (!QStringList{"codex", "claude"}.contains(provider) || !QStringList{"login", "logout"}.contains(action)) return false;
    const auto terminal = QStandardPaths::findExecutable("xdg-terminal-exec");
    const auto cli = QStandardPaths::findExecutable(provider);
    if (terminal.isEmpty() || cli.isEmpty()) {
        m_configError = "Install xdg-terminal-exec and the provider CLI to manage sign-in.";
        emit settingsChanged(); return false;
    }
    QStringList arguments{"--hold", "--", cli};
    if (provider == "claude") arguments.append("auth");
    arguments.append(action);
    if (!QProcess::startDetached(terminal, arguments)) {
        m_configError = "Could not open the sign-in terminal."; emit settingsChanged(); return false;
    }
    m_configError.clear(); emit settingsChanged(); return true;
}

namespace {
// Auto-generated labels follow the account's position; user-chosen labels are left alone.
QString renumberedLabel(const QString &label, int position) {
    static const QRegularExpression pattern("^Account \\d+ \\((.*)\\)$");
    const auto match = pattern.match(label);
    return match.hasMatch() ? QString("Account %1 (%2)").arg(position).arg(match.captured(1)) : label;
}
}

bool DesktopController::setTopAccount(const QString &provider, int accountIndex) {
    return moveAccount(provider, accountIndex, 0);
}

bool DesktopController::moveAccount(const QString &provider, int fromIndex, int toIndex) {
    if (fromIndex == toIndex || fromIndex < 0 || toIndex < 0) return false;
    const QString configPath = QDir::homePath() + "/.codexbar/config.json";
    QFile file(configPath);
    if (!file.open(QIODevice::ReadOnly)) return false;
    const auto doc = QJsonDocument::fromJson(file.readAll());
    file.close();
    if (!doc.isObject()) return false;
    auto rootObj = doc.object();
    auto providersArray = rootObj.value("providers").toArray();
    bool found = false;
    for (int pIdx = 0; pIdx < providersArray.size(); ++pIdx) {
        auto provObj = providersArray[pIdx].toObject();
        if (provObj.value("id").toString() == provider) {
            auto tokenAccounts = provObj.value("tokenAccounts").toObject();
            auto accountsArray = tokenAccounts.value("accounts").toArray();
            if (fromIndex >= accountsArray.size() || toIndex >= accountsArray.size()) return false;
            auto item = accountsArray.takeAt(fromIndex);
            accountsArray.insert(toIndex, item);
            for (int i = 0; i < accountsArray.size(); ++i) {
                auto acc = accountsArray[i].toObject();
                const QString label = acc.value("label").toString();
                const QString renumbered = renumberedLabel(label, i + 1);
                if (renumbered != label) {
                    acc["label"] = renumbered;
                    accountsArray[i] = acc;
                }
            }
            tokenAccounts["accounts"] = accountsArray;
            provObj["tokenAccounts"] = tokenAccounts;
            providersArray[pIdx] = provObj;
            found = true;
            break;
        }
    }
    if (!found) return false;
    rootObj["providers"] = providersArray;
    // The file holds provider tokens and is shared with the CLI: keep a private copy before rewriting it.
    const QString backupPath = configPath + ".bak";
    QFile::remove(backupPath);
    if (!QFile::copy(configPath, backupPath)) return false;
    QFile::setPermissions(backupPath, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QSaveFile saveFile(configPath);
    if (!saveFile.open(QIODevice::WriteOnly)) return false;
    const auto encoded = QJsonDocument(rootObj).toJson(QJsonDocument::Indented);
    if (saveFile.write(encoded) != encoded.size() || !saveFile.commit()) return false;

    // Immediately update in-memory entries for instant UI feedback
    QVariantList providerEntries;
    QVariantList otherEntries;
    for (const auto &entry : m_entries) {
        if (entry.toMap().value("provider").toString() == provider)
            providerEntries.append(entry);
        else
            otherEntries.append(entry);
    }
    if (fromIndex < providerEntries.size() && toIndex < providerEntries.size()) {
        auto moved = providerEntries.takeAt(fromIndex);
        providerEntries.insert(toIndex, moved);
        for (int i = 0; i < providerEntries.size(); ++i) {
            auto map = providerEntries[i].toMap();
            map["accountNumber"] = i + 1;
            map["accountLabel"] = renumberedLabel(map.value("accountLabel").toString(), i + 1);
            providerEntries[i] = map;
        }
        m_entries = providerEntries + otherEntries;
        updateLabels();
        emit changed();
    }
    refresh();
    return true;
}

bool DesktopController::setStarredModel(const QString &provider, const QString &label, const QString &key) {
    QVariantMap starred;
    starred["provider"] = provider;
    starred["label"] = label;
    if (!key.isEmpty()) starred["key"] = key;
    return saveSettings({{"starredModel", starred}});
}

bool DesktopController::isStarredModel(const QString &provider, const QString &label, const QString &key) const {
    const auto starred = m_settings.value("starredModel").toMap();
    if (starred.isEmpty()) return false;
    if (starred.value("provider").toString() != provider) return false;
    if (!key.isEmpty() && !starred.value("key").toString().isEmpty()) {
        if (starred.value("key").toString() == key) return true;
    }
    return starred.value("label").toString() == label;
}

QVariantMap DesktopController::starredModel() const {
    return m_settings.value("starredModel").toMap();
}

bool DesktopController::singleBar() const {
    return m_settings.value("singleBar", true).toBool();
}

bool DesktopController::setSingleBar(bool enabled) {
    return saveSettings({{"singleBar", enabled}});
}

void DesktopController::refreshAccount(const QString &provider, int accountIndex) {
    if (m_accountProcess.state() != QProcess::NotRunning || busy()) return;
    m_refreshingProvider = provider;
    m_refreshingAccountIndex = accountIndex;
    emit accountRefreshingChanged();

    auto selection = m_settings;
    selection["provider"] = provider;
    selection["accountIndex"] = accountIndex;
    selection["allAccounts"] = (provider == "codex" || provider == "antigravity");
    auto args = call(m_usageModel, "command", {m_engine.toScriptValue(selection)}).toVariant().toStringList();
    args = args.mid(3);

    auto output = std::make_shared<QByteArray>();
    auto complete = std::make_shared<bool>(false);
    auto *deadline = new QTimer(&m_accountProcess);
    deadline->setSingleShot(true);
    connect(deadline, &QTimer::timeout, &m_accountProcess, [this] { stop(m_accountProcess); });

    auto finish = [this, output, complete, deadline, provider, accountIndex](bool failed) {
        if (*complete) return;
        *complete = true;
        deadline->stop();
        deadline->deleteLater();
        m_accountProcess.disconnect(this);
        output->append(m_accountProcess.readAllStandardOutput());

        QJSValueList arguments{QString::fromUtf8(*output), m_settings.value("showIdentity").toBool()};
        const auto parsed = call(m_usageModel, "rows", arguments);
        if (!failed && !parsed.isError() && parsed.isArray()) {
            const auto refreshedList = parsed.toVariant().toList();
            if (!refreshedList.isEmpty()) {
                if (provider == "codex" || provider == "antigravity") {
                    for (int r = 0; r < refreshedList.size(); ++r) {
                        auto refreshedMap = refreshedList[r].toMap();
                        int accNum = r + 1;
                        refreshedMap["accountNumber"] = accNum;
                        for (int i = 0; i < m_entries.size(); ++i) {
                            auto map = m_entries[i].toMap();
                            if (map.value("provider").toString() == provider &&
                                map.value("accountNumber").toInt() == accNum) {
                                m_entries[i] = refreshedMap;
                                break;
                            }
                        }
                    }
                } else {
                    auto newEntryMap = refreshedList.first().toMap();
                    newEntryMap["accountNumber"] = accountIndex;

                    bool found = false;
                    for (int i = 0; i < m_entries.size(); ++i) {
                        auto map = m_entries[i].toMap();
                        if (map.value("provider").toString() == provider &&
                            map.value("accountNumber").toInt() == accountIndex) {
                            m_entries[i] = newEntryMap;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        for (int i = 0; i < m_entries.size(); ++i) {
                            auto map = m_entries[i].toMap();
                            if (map.value("provider").toString() == provider) {
                                m_entries[i] = newEntryMap;
                                break;
                            }
                        }
                    }
                }
                applyDrainingPriority(m_entries);
                updateLabels();
                updateNotifications(m_entries);
            }
        }
        m_refreshingProvider.clear();
        m_refreshingAccountIndex = 0;
        emit accountRefreshingChanged();
        emit changed();
    };

    connect(&m_accountProcess, &QProcess::readyReadStandardOutput, this, [&, output] {
        output->append(m_accountProcess.readAllStandardOutput());
        if (output->size() > 8 * 1024 * 1024) stop(m_accountProcess);
    });
    connect(&m_accountProcess, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), this,
        [finish](int code, QProcess::ExitStatus status) {
            finish(code != 0 || status != QProcess::NormalExit);
        });
    connect(&m_accountProcess, &QProcess::errorOccurred, this, [finish] { finish(true); });

    deadline->start(15000);
    const auto binary = args.takeFirst();
    m_accountProcess.start(binary, args);
}

bool DesktopController::isAccountRefreshing(const QString &provider, int accountIndex) const {
    if (m_refreshingProvider.isEmpty() || m_refreshingAccountIndex == 0) return false;
    if (accountIndex == 0) return m_refreshingProvider == provider;
    return m_refreshingProvider == provider && m_refreshingAccountIndex == accountIndex;
}

int DesktopController::providerAccountCount(const QString &provider) const {
    int count = 0;
    for (const auto &entry : m_entries) {
        if (entry.toMap().value("provider").toString() == provider) ++count;
    }
    return count;
}

QString DesktopController::makeAlarmId(const QString &provider, const QString &accountLabel, const QString &windowKey) const {
    return provider.toLower() + "/" + (accountLabel.isEmpty() ? "default" : accountLabel) + "/" + (windowKey.isEmpty() ? "primary" : windowKey);
}

void DesktopController::updateQuotaAlarmsFromEntries() {
    if (!m_settings.value("alarmEnabled", true).toBool()) return;
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    bool modified = false;

    for (const auto &entryVal : m_entries) {
        auto entry = entryVal.toMap();
        QString provider = entry.value("provider").toString();
        QString accountLabel = entry.value("accountLabel").toString();
        auto windows = entry.value("windows").toList();

        for (const auto &winVal : windows) {
            auto win = winVal.toMap();
            double remaining = win.value("remaining").toDouble();
            QString resetsAt = win.value("resetsAt").toString();
            QString windowKey = win.value("key").toString();
            QString windowLabel = win.value("label").toString();

            // When quota runs out: remaining <= 0 and resetsAt is present
            if (remaining <= 0 && !resetsAt.isEmpty()) {
                QString id = makeAlarmId(provider, accountLabel, windowKey);
                bool exists = false;
                for (const auto &existing : m_alarms) {
                    auto a = existing.toMap();
                    if (a.value("id").toString() == id && 
                        (a.value("status").toString() == "armed" || a.value("status").toString() == "ringing")) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    QVariantMap newAlarm;
                    newAlarm["id"] = id;
                    newAlarm["provider"] = provider;
                    newAlarm["accountLabel"] = accountLabel;
                    newAlarm["windowKey"] = windowKey;
                    newAlarm["windowLabel"] = windowLabel;
                    newAlarm["resetsAt"] = resetsAt;
                    newAlarm["resetsAtMs"] = QDateTime::fromString(resetsAt, Qt::ISODate).toMSecsSinceEpoch();
                    newAlarm["status"] = "armed";
                    newAlarm["armedAt"] = now;
                    m_alarms.append(newAlarm);
                    modified = true;
                }
            }
        }
    }
    if (modified) emit alarmsChanged();
}

void DesktopController::checkAlarms() {
    if (!m_settings.value("alarmEnabled", true).toBool()) return;
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    bool changedAlarms = false;

    for (int i = 0; i < m_alarms.size(); ++i) {
        auto alarm = m_alarms[i].toMap();
        if (alarm.value("status").toString() != "armed") continue;

        qint64 resetsAtMs = alarm.value("resetsAtMs").toLongLong();
        QString provider = alarm.value("provider").toString();
        QString windowKey = alarm.value("windowKey").toString();
        QString accountLabel = alarm.value("accountLabel").toString();

        bool shouldTrigger = false;
        int restoredRemaining = 100;

        // Condition A: Reset timestamp elapsed
        if (resetsAtMs > 0 && now >= resetsAtMs) {
            shouldTrigger = true;
        }

        // Condition B: Polled quota returned to > 0
        for (const auto &entryVal : m_entries) {
            auto entry = entryVal.toMap();
            if (entry.value("provider").toString().toLower() != provider.toLower()) continue;
            if (!accountLabel.isEmpty() && entry.value("accountLabel").toString() != accountLabel) continue;

            auto windows = entry.value("windows").toList();
            for (const auto &winVal : windows) {
                auto win = winVal.toMap();
                if (win.value("key").toString() == windowKey) {
                    double rem = win.value("remaining").toDouble();
                    if (rem > 0) {
                        shouldTrigger = true;
                        restoredRemaining = int(rem);
                    }
                    break;
                }
            }
        }

        if (shouldTrigger) {
            alarm["status"] = "ringing";
            alarm["triggeredAt"] = now;
            alarm["restoredRemaining"] = restoredRemaining;
            m_alarms[i] = alarm;
            changedAlarms = true;
            triggerAlarm(alarm);
            break; // Trigger one alarm at a time
        }
    }

    if (changedAlarms) emit alarmsChanged();
}

void DesktopController::triggerAlarm(QVariantMap &alarm) {
    m_ringingAlarm = alarm;
    m_isAlarmRinging = true;
    emit ringingAlarmChanged();

    // Start persistent sound playback loop
    playAlarmSound();
    if (!m_alarmSoundTimer.isActive()) {
        m_alarmSoundTimer.start(1800);
    }

    // Post D-Bus notification
    postAlarmNotification(alarm);

    // Request window display
    emit windowRequested("usage");
}

void DesktopController::playAlarmSound() {
    if (!m_settings.value("alarmSound", true).toBool()) return;

    if (QFile::exists("/usr/bin/canberra-gtk-play")) {
        QProcess::startDetached("/usr/bin/canberra-gtk-play", QStringList{"-i", "alarm-clock-elapsed", "--description", "CodexBar Quota Reset Alarm"});
        return;
    }

    if (QFile::exists("/usr/bin/pw-play") && QFile::exists("/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga")) {
        QProcess::startDetached("/usr/bin/pw-play", QStringList{"/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"});
        return;
    }

    if (QFile::exists("/usr/bin/aplay") && QFile::exists("/usr/share/sounds/alsa/Front_Center.wav")) {
        QProcess::startDetached("/usr/bin/aplay", QStringList{"-q", "/usr/share/sounds/alsa/Front_Center.wav"});
        return;
    }

    fprintf(stderr, "\a");
    fflush(stderr);
}

void DesktopController::postAlarmNotification(const QVariantMap &alarm) {
    if (!m_settings.value("notifications", true).toBool()) return;
    auto message = QDBusMessage::createMethodCall("org.freedesktop.Notifications", "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications", "Notify");
    QString provider = alarm.value("provider").toString().toUpper();
    QString account = alarm.value("accountLabel").toString();
    QString windowLabel = alarm.value("windowLabel").toString();
    int remaining = alarm.value("restoredRemaining", 100).toInt();

    QString title = QString("CodexBar · Quota Restored (%1)").arg(provider);
    QString body = QString("%1 quota has returned%2!\nNow %3% available.")
        .arg(windowLabel.isEmpty() ? "Session" : windowLabel)
        .arg(account.isEmpty() ? "" : (" for " + account))
        .arg(remaining);

    QVariantMap hints;
    hints["urgency"] = uchar(2); // critical
    hints["sound-name"] = "alarm-clock-elapsed";

    QStringList actions = {"dismiss", "Dismiss Alarm"};
    message.setArguments({"CodexBar", uint(0), "codexbar", title, body, actions, hints, 0});
    QDBusConnection::sessionBus().asyncCall(message);
}

void DesktopController::onNotificationAction(uint, const QString &action) {
    if (action == "dismiss") {
        dismissAlarm();
    }
}

void DesktopController::dismissAlarm(const QString &alarmId) {
    m_alarmSoundTimer.stop();
    m_isAlarmRinging = false;
    m_ringingAlarm.clear();

    for (int i = 0; i < m_alarms.size(); ++i) {
        auto a = m_alarms[i].toMap();
        if (alarmId.isEmpty() || a.value("id").toString() == alarmId || a.value("status").toString() == "ringing") {
            a["status"] = "dismissed";
            a["dismissedAt"] = QDateTime::currentMSecsSinceEpoch();
            m_alarms[i] = a;
        }
    }
    emit ringingAlarmChanged();
    emit alarmsChanged();
    emit changed();
}

void DesktopController::snoozeAlarm(const QString &alarmId, int minutes) {
    m_alarmSoundTimer.stop();
    m_isAlarmRinging = false;
    m_ringingAlarm.clear();
    qint64 now = QDateTime::currentMSecsSinceEpoch();
    qint64 snoozeUntil = now + (minutes > 0 ? minutes : 5) * 60 * 1000;

    for (int i = 0; i < m_alarms.size(); ++i) {
        auto a = m_alarms[i].toMap();
        if (alarmId.isEmpty() || a.value("id").toString() == alarmId || a.value("status").toString() == "ringing") {
            a["status"] = "armed";
            a["resetsAtMs"] = snoozeUntil;
            a["snoozedAt"] = now;
            m_alarms[i] = a;
        }
    }
    emit ringingAlarmChanged();
    emit alarmsChanged();
    emit changed();
}

void DesktopController::testAlarm() {
    QVariantMap alarm;
    alarm["id"] = "test/alarm";
    alarm["provider"] = "codex";
    alarm["accountLabel"] = "aubrey.zemba@dyedurham.com";
    alarm["windowKey"] = "primary";
    alarm["windowLabel"] = "5-hour quota";
    alarm["resetsAt"] = QDateTime::currentDateTime().toString(Qt::ISODate);
    alarm["resetsAtMs"] = QDateTime::currentMSecsSinceEpoch();
    alarm["status"] = "ringing";
    alarm["triggeredAt"] = QDateTime::currentMSecsSinceEpoch();
    alarm["restoredRemaining"] = 100;

    for (int i = m_alarms.size() - 1; i >= 0; --i) {
        if (m_alarms[i].toMap().value("id").toString() == "test/alarm") {
            m_alarms.removeAt(i);
        }
    }
    m_alarms.append(alarm);
    emit alarmsChanged();
    triggerAlarm(alarm);
}

void DesktopController::stopAlarmSound() {
    m_alarmSoundTimer.stop();
}

bool DesktopController::hasArmedAlarm(const QString &provider, const QString &windowKey, const QString &accountLabel) const {
    QString id = makeAlarmId(provider, accountLabel, windowKey);
    for (const auto &val : m_alarms) {
        auto a = val.toMap();
        if (a.value("id").toString() == id && a.value("status").toString() == "armed") {
            return true;
        }
    }
    return false;
}

QVariantMap DesktopController::alarmForWindow(const QString &provider, const QString &windowKey, const QString &accountLabel) const {
    QString id = makeAlarmId(provider, accountLabel, windowKey);
    for (const auto &val : m_alarms) {
        auto a = val.toMap();
        if (a.value("id").toString() == id) {
            return a;
        }
    }
    return QVariantMap();
}

void DesktopController::toggleAlarm(const QString &provider, const QString &windowKey, const QString &windowLabel, const QString &accountLabel, const QString &resetsAt) {
    QString id = makeAlarmId(provider, accountLabel, windowKey);
    for (int i = 0; i < m_alarms.size(); ++i) {
        auto a = m_alarms[i].toMap();
        if (a.value("id").toString() == id) {
            if (a.value("status").toString() == "armed") {
                a["status"] = "dismissed";
                m_alarms[i] = a;
                emit alarmsChanged();
                return;
            } else if (a.value("status").toString() == "ringing") {
                dismissAlarm(id);
                return;
            }
        }
    }

    // Arm new alarm
    QVariantMap newAlarm;
    newAlarm["id"] = id;
    newAlarm["provider"] = provider;
    newAlarm["accountLabel"] = accountLabel;
    newAlarm["windowKey"] = windowKey;
    newAlarm["windowLabel"] = windowLabel;
    newAlarm["resetsAt"] = resetsAt;
    newAlarm["resetsAtMs"] = QDateTime::fromString(resetsAt, Qt::ISODate).toMSecsSinceEpoch();
    newAlarm["status"] = "armed";
    newAlarm["armedAt"] = QDateTime::currentMSecsSinceEpoch();
    m_alarms.append(newAlarm);
    emit alarmsChanged();
}

