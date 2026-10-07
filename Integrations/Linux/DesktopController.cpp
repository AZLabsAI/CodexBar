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
    QTimer::singleShot(0, this, &DesktopController::refresh);
}

DesktopController::~DesktopController() {
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
    for (const auto &key : {"allAccounts", "showIdentity", "showCosts", "showStatus", "notifications", "showTray", "refreshOnOpen", "showPace", "warningColors", "followOmarchyTheme", "sidebarPinned", "sidebarCollapsed", "sidebarHoverBrighten"})
        if (values.contains(key)) values[key] = values.value(key).toBool();
    if (values.contains("sidebarOpacity")) {
        bool ok = false;
        double op = values.value("sidebarOpacity").toDouble(&ok);
        if (ok && op >= 0.1 && op <= 1.0) values["sidebarOpacity"] = op;
    }
    if (values.contains("sidebarSide")) {
        const auto side = values.value("sidebarSide").toString();
        if (side == "left" || side == "right") values["sidebarSide"] = side;
    }
    if (values.contains("starredModel")) {
        values["starredModel"] = values.value("starredModel").toMap();
    }
    return true;
}

void DesktopController::loadSettings(const QString &cliOverride) {
    m_settings = {{"executable", "codexbar"}, {"provider", "codex"}, {"source", "auto"},
        {"refreshSeconds", 300}, {"accountIndex", 0}, {"notifyThreshold", 25}, {"allAccounts", false},
        {"showIdentity", false}, {"showCosts", true}, {"showStatus", true}, {"notifications", true}, {"showTray", true}, {"refreshOnOpen", false}, {"providerOrder", QStringList{}},
        {"quotaDisplay", "used"}, {"resetDisplay", "countdown"}, {"showPace", true},
        {"warningColors", true}, {"trayStyle", "meters"}, {"followOmarchyTheme", false}, {"starredModel", QVariantMap{{"provider", "antigravity"}, {"label", "Gemini weekly"}}},
        {"sidebarOpacity", 0.85}, {"sidebarSide", "right"}, {"sidebarPinned", true}, {"sidebarCollapsed", false}, {"sidebarHoverBrighten", true}};
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
            m_entries = m_batchEntries;
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
    if (!m_settings.value("notifications").toBool()) return;
    for (const auto &item : result.property("events").toVariant().toList()) {
        auto event = item.toMap();
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

void DesktopController::updateLabels() {
    const auto rows = m_engine.toScriptValue(m_entries);
    const auto mode = m_settings.value("quotaDisplay").toString();
    const auto starred = m_engine.toScriptValue(m_settings.value("starredModel"));
    m_summary = call(m_usageModel, "summary", {rows, mode, starred}).toString();
    m_barEntries = QJsonArray::fromVariantList(call(m_usageModel, "barSegments", {rows, mode, starred}).toVariant().toList());
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
        QJsonObject entryObj{
            {"provider", row.value("provider").toString()},
            {"accountLabel", row.value("accountLabel").toString()},
            {"plan", row.value("plan").toString()},
            {"windows", windows},
            {"details", QJsonArray::fromVariantList(row.value("details").toList())},
            {"error", row.value("error").toString()}
        };
        if (!row.value("credits").isNull()) {
            entryObj["credits"] = row.value("credits").toLongLong();
        }
        compact.append(entryObj);
    }
    return {{"schemaVersion", 1}, {"pid", QCoreApplication::applicationPid()}, {"summary", m_summary}, {"barEntries", m_barEntries}, {"starredModel", QJsonObject::fromVariantMap(m_settings.value("starredModel").toMap())},
        {"entries", compact}, {"quotaDisplay", m_settings.value("quotaDisplay").toString()}, {"busy", busy()}, {"stale", stale()}, {"error", m_error},
        {"updated", updated()}, {"costBusy", costBusy()}, {"costProviders", m_spending.size()}, {"costError", m_costError}};
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
    if (starred.isEmpty()) {
        if (provider == "antigravity" && label.contains("gemini", Qt::CaseInsensitive) && label.contains("weekly", Qt::CaseInsensitive)) {
            return true;
        }
        return false;
    }
    if (starred.value("provider").toString() != provider) return false;
    if (!key.isEmpty() && !starred.value("key").toString().isEmpty()) {
        if (starred.value("key").toString() == key) return true;
    }
    return starred.value("label").toString() == label;
}

QVariantMap DesktopController::starredModel() const {
    return m_settings.value("starredModel").toMap();
}

void DesktopController::refreshAccount(const QString &provider, int accountIndex) {
    if (m_accountProcess.state() != QProcess::NotRunning || busy()) return;
    m_refreshingProvider = provider;
    m_refreshingAccountIndex = accountIndex;
    emit accountRefreshingChanged();

    auto selection = m_settings;
    selection["provider"] = provider;
    selection["accountIndex"] = accountIndex;
    selection["allAccounts"] = false;
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
