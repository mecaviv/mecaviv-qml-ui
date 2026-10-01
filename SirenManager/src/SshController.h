#ifndef SSHCONTROLLER_H
#define SSHCONTROLLER_H

#include <QObject>
#include <QString>
#include <QHash>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include "Config/MachineType.h"

// Wraps HTTP calls to the Node.js backend (default localhost:8005). The
// backend's /api/ssh/{execute,download,upload} endpoints proxy SSH operations
// to the various sirens. All methods are async — pass a requestId to correlate
// the *Finished signals with the call that produced them.
class SshController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString backendUrl READ backendUrl WRITE setBackendUrl NOTIFY backendUrlChanged)

public:
    explicit SshController(QObject *parent = nullptr);

    QString backendUrl() const { return m_backendUrl; }
    void setBackendUrl(const QString &url);

    Q_INVOKABLE void executeCommand(int machineType, const QString &command, const QString &requestId);
    // One request for several machines: itemsJson is an array of
    // {machineType:int, command:string}. The backend runs them together, logs a
    // single summary, and skips boards it just found unreachable. Emits
    // batchFinished with a JSON array of {machineType (alias), success, output,
    // error, unreachable} in the same order as the items.
    Q_INVOKABLE void executeBatch(const QString &itemsJson, const QString &requestId);
    // Generic POST to a backend route: bodyJson is sent as is, except that an
    // integer machineType is turned into the backend's machine key. Emits
    // backendReply with the response body as JSON.
    Q_INVOKABLE void callBackend(const QString &path, const QString &bodyJson, const QString &requestId);
    Q_INVOKABLE void downloadFile(int machineType, const QString &remotePath, const QString &requestId);
    Q_INVOKABLE void uploadFile(int machineType, const QString &remotePath, const QString &content, const QString &requestId);

    // Upload a local file (binary-safe). localUrl can be either a plain path
    // or a "file://…" URL (e.g. from a QML DropArea drop.urls entry). The
    // remote-side `cat > path` is the same as uploadFile, but we read the
    // file as bytes and ship them as base64 in the JSON body so binary
    // content (MIDI, etc.) doesn't get UTF-8-mangled.
    Q_INVOKABLE void uploadLocalFile(int machineType, const QString &localUrl,
                                     const QString &remotePath, const QString &requestId);

    // Tar a directory from the source machine and untar it onto each of the
    // given targets. Targets is a JSON-encoded array of {machineType, remotePath}.
    // When `mirror` is true, files on each target matching `mirrorPattern` (a
    // shell glob like "*.mid") that don't exist on the source get rm'd before
    // the untar — so the sync acts as a true mirror, not just additive.
    // When `dryRun` is true (only valid with mirror), no rm and no tar happen:
    // the backend just returns the orphan list per target so the UI can show
    // what *would* be deleted. Pass an empty pattern when mirror is false.
    // Emits syncDirFinished with per-target results when done; each result
    // entry includes `removed` count and `orphans` list when mirroring was on.
    Q_INVOKABLE void syncDir(int sourceMachine, const QString &sourcePath,
                             const QString &targetsJson, bool mirror,
                             const QString &mirrorPattern, bool dryRun,
                             const QString &requestId);

    // Build a tar.gz on the backend host bundling ~/.ssh/id_rsa_sirenes(.pub)
    // + the Host blocks from ~/.ssh/config that match the siren aliases, plus
    // an INSTALL.sh and README.txt. The archive lands in ~/Downloads/. Used to
    // clone SSH access onto a second control machine without redoing
    // ssh-copy-id from scratch. Emits keysArchiveExportFinished with the
    // archive path on success.
    Q_INVOKABLE void exportKeysArchive(const QString &requestId);

signals:
    void backendUrlChanged(const QString &url);
    void commandFinished(const QString &requestId, bool success, const QString &output, const QString &error);
    void batchFinished(const QString &requestId, bool success, const QString &resultsJson, const QString &error);
    void backendReply(const QString &requestId, bool success, const QString &bodyJson, const QString &error);
    void downloadFinished(const QString &requestId, bool success, const QString &content, const QString &error);
    void uploadFinished(const QString &requestId, bool success, const QString &error);
    // results is the raw JSON array string from the backend: each entry is
    // { machine: "<alias>", success: bool, error: "<msg if any>" }.
    // QML can JSON.parse() it directly to display per-target outcomes.
    void syncDirFinished(const QString &requestId, bool success, int tarSize,
                         const QString &resultsJson, const QString &error);
    void keysArchiveExportFinished(const QString &requestId, bool success,
                                   const QString &archivePath, int aliasesFound,
                                   const QString &error);

private:
    static QString machineTypeToString(int machineType);
    void postJson(const QString &path, const QByteArray &body,
                  std::function<void(QNetworkReply*)> handler);

    QNetworkAccessManager *m_network;
    QString m_backendUrl;
};

#endif
