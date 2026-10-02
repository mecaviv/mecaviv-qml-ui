#include "SshController.h"
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkRequest>
#include <QUrl>

SshController::SshController(QObject *parent)
    : QObject(parent)
    , m_network(new QNetworkAccessManager(this))
    , m_backendUrl(QStringLiteral("http://localhost:8005"))
{
}

void SshController::setBackendUrl(const QString &url)
{
    if (m_backendUrl != url) {
        m_backendUrl = url;
        emit backendUrlChanged(m_backendUrl);
    }
}

QString SshController::machineTypeToString(int machineType)
{
    // Must match backend/config.json keys (linuxMaitre, raspberryClic, s1..s7, etc.).
    switch (static_cast<MachineType>(machineType)) {
        case MachineType::LinuxMaitre:   return QStringLiteral("linuxMaitre");
        case MachineType::RaspberryClic: return QStringLiteral("raspberryClic");
        case MachineType::S1: return QStringLiteral("s1");
        case MachineType::S2: return QStringLiteral("s2");
        case MachineType::S3: return QStringLiteral("s3");
        case MachineType::S4: return QStringLiteral("s4");
        case MachineType::S5: return QStringLiteral("s5");
        case MachineType::S6: return QStringLiteral("s6");
        case MachineType::S7: return QStringLiteral("s7");
        case MachineType::VoitureA: return QStringLiteral("voitureA");
        case MachineType::VoitureB: return QStringLiteral("voitureB");
        case MachineType::Pavillon1: return QStringLiteral("pavillon1");
        case MachineType::Pavillon2: return QStringLiteral("pavillon2");
        default: return QStringLiteral("linuxMaitre");
    }
}

void SshController::postJson(const QString &path, const QByteArray &body,
                             std::function<void(QNetworkReply*)> handler)
{
    QNetworkRequest req(QUrl(m_backendUrl + path));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_network->post(req, body);
    connect(reply, &QNetworkReply::finished, this, [reply, handler]() {
        handler(reply);
        reply->deleteLater();
    });
}

// Parse the backend's JSON body even on HTTP error — Express's
// res.status(500).json({ success:false, error:"..." }) carries the real SSH
// error message there. Falling back to QNetworkReply::errorString() loses it.
static QJsonObject readReplyBody(QNetworkReply *reply)
{
    return QJsonDocument::fromJson(reply->readAll()).object();
}

void SshController::executeCommand(int machineType, const QString &command, const QString &requestId)
{
    QJsonObject body;
    body[QStringLiteral("machineType")] = machineTypeToString(machineType);
    body[QStringLiteral("command")] = command;
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/execute"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString output = obj.value(QStringLiteral("output")).toString();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit commandFinished(requestId, success, output, errorStr);
    });
}

void SshController::executeBatch(const QString &itemsJson, const QString &requestId)
{
    QJsonArray items;
    for (const QJsonValue &v : QJsonDocument::fromJson(itemsJson.toUtf8()).array()) {
        const QJsonObject o = v.toObject();
        QJsonObject item;
        item[QStringLiteral("machineType")] = machineTypeToString(o.value(QStringLiteral("machineType")).toInt());
        item[QStringLiteral("command")] = o.value(QStringLiteral("command")).toString();
        items.append(item);
    }
    QJsonObject body;
    body[QStringLiteral("items")] = items;
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/batch"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString results = QString::fromUtf8(QJsonDocument(obj.value(QStringLiteral("results")).toArray()).toJson(QJsonDocument::Compact));
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit batchFinished(requestId, success, results, errorStr);
    });
}

void SshController::callBackend(const QString &path, const QString &bodyJson, const QString &requestId)
{
    QJsonObject body = QJsonDocument::fromJson(bodyJson.toUtf8()).object();
    const QJsonValue mt = body.value(QStringLiteral("machineType"));
    if (mt.isDouble())
        body[QStringLiteral("machineType")] = machineTypeToString(mt.toInt());
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(path, json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit backendReply(requestId, success, QString::fromUtf8(QJsonDocument(obj).toJson(QJsonDocument::Compact)), errorStr);
    });
}

void SshController::downloadFile(int machineType, const QString &remotePath, const QString &requestId)
{
    QJsonObject body;
    body[QStringLiteral("machineType")] = machineTypeToString(machineType);
    body[QStringLiteral("remotePath")] = remotePath;
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/download"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString content = obj.value(QStringLiteral("content")).toString();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit downloadFinished(requestId, success, content, errorStr);
    });
}

void SshController::uploadFile(int machineType, const QString &remotePath, const QString &content, const QString &requestId)
{
    QJsonObject body;
    body[QStringLiteral("machineType")] = machineTypeToString(machineType);
    body[QStringLiteral("remotePath")] = remotePath;
    body[QStringLiteral("content")] = content;
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/upload"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit uploadFinished(requestId, success, errorStr);
    });
}

void SshController::syncDir(int sourceMachine, const QString &sourcePath,
                            const QString &targetsJson, bool mirror,
                            const QString &mirrorPattern, bool dryRun,
                            const QString &requestId)
{
    // targetsJson is a JSON array — convert each entry's machineType (int)
    // into the backend's string identifier before forwarding.
    QJsonDocument doc = QJsonDocument::fromJson(targetsJson.toUtf8());
    QJsonArray arr = doc.array();
    QJsonArray rewritten;
    for (const QJsonValue &v : arr) {
        QJsonObject t = v.toObject();
        QJsonObject out;
        out[QStringLiteral("machineType")] = machineTypeToString(t.value(QStringLiteral("machineType")).toInt());
        out[QStringLiteral("remotePath")] = t.value(QStringLiteral("remotePath")).toString();
        rewritten.append(out);
    }

    QJsonObject body;
    body[QStringLiteral("sourceMachine")] = machineTypeToString(sourceMachine);
    body[QStringLiteral("sourcePath")] = sourcePath;
    body[QStringLiteral("targets")] = rewritten;
    body[QStringLiteral("mirror")] = mirror;
    if (mirror && !mirrorPattern.isEmpty()) {
        body[QStringLiteral("mirrorPattern")] = mirrorPattern;
    }
    if (mirror && dryRun) {
        body[QStringLiteral("dryRun")] = true;
    }
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/sync-dir"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        int tarSize = obj.value(QStringLiteral("tarSize")).toInt();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        QJsonArray results = obj.value(QStringLiteral("results")).toArray();
        QString resultsJson = QString::fromUtf8(QJsonDocument(results).toJson(QJsonDocument::Compact));
        emit syncDirFinished(requestId, success, tarSize, resultsJson, errorStr);
    });
}

void SshController::uploadLocalFile(int machineType, const QString &localUrl,
                                    const QString &remotePath, const QString &requestId)
{
    QString localPath = localUrl;
    if (localPath.startsWith(QStringLiteral("file://"))) {
        localPath = QUrl(localPath).toLocalFile();
    }
    QFile f(localPath);
    if (!f.open(QIODevice::ReadOnly)) {
        emit uploadFinished(requestId, false,
            QStringLiteral("Cannot open local file %1: %2").arg(localPath, f.errorString()));
        return;
    }
    QByteArray bytes = f.readAll();
    f.close();

    QJsonObject body;
    body[QStringLiteral("machineType")] = machineTypeToString(machineType);
    body[QStringLiteral("remotePath")] = remotePath;
    body[QStringLiteral("contentBase64")] = QString::fromLatin1(bytes.toBase64());
    QByteArray json = QJsonDocument(body).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/ssh/upload"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit uploadFinished(requestId, success, errorStr);
    });
}

void SshController::exportKeysArchive(const QString &requestId)
{
    // No body needed — the backend reads ~/.ssh on its host.
    QByteArray json = QJsonDocument(QJsonObject{}).toJson(QJsonDocument::Compact);

    postJson(QStringLiteral("/api/keys/export"), json, [this, requestId](QNetworkReply *reply) {
        QJsonObject obj = readReplyBody(reply);
        bool success = obj.value(QStringLiteral("success")).toBool();
        QString archivePath = obj.value(QStringLiteral("path")).toString();
        int aliasesFound = obj.value(QStringLiteral("aliasesFound")).toInt();
        QString errorStr = obj.value(QStringLiteral("error")).toString();
        if (errorStr.isEmpty() && reply->error() != QNetworkReply::NoError) {
            errorStr = reply->errorString();
        }
        emit keysArchiveExportFinished(requestId, success, archivePath, aliasesFound, errorStr);
    });
}

