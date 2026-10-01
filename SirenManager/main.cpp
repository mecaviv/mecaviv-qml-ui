#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QDir>
#include <QStandardPaths>
#include <QQuickStyle>
#include <QtQml>
#ifdef BUNDLED_BACKEND
#include <QProcess>
#endif
#include "src/UdpController.h"
#include "src/SshController.h"
#include "src/PlaylistManager.h"
#include "src/Models/PlaylistModel.h"

int main(int argc, char *argv[])
{
    // QML reads its tooltip CSV (a qrc resource) with XMLHttpRequest, which Qt
    // blocks for local files unless this is set before the engine is created.
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");

    QGuiApplication app(argc, argv);

    // Configuration de l'application
    app.setApplicationName("SirenManager");
    app.setApplicationVersion("1.0.0");
    app.setOrganizationName("Mecaviv");
    app.setOrganizationDomain("mecaviv.com");

    // Style Controls explicite : sans ça, macOS utilise le style natif qui rend
    // les boutons "nus" (sans background/contentItem custom) illisibles sur le
    // thème sombre (texte clair sur bezel clair — cf. onglet SYSTÈME). Fusion est
    // intégré (pas de plugin séparé à déployer) et respecte la palette ; les
    // boutons déjà stylés ailleurs gardent leur apparence.
    QQuickStyle::setStyle(QStringLiteral("Fusion"));

#ifdef BUNDLED_BACKEND
    // Démarre le backend Node embarqué (exécutable autonome placé à côté de
    // l'app dans le bundle). Le backend fournit le proxy SSH (HTTP 8005) requis
    // par les vues SystemMaintenance / PlaylistComposer. Il résout son
    // config.json relativement à son propre exécutable (cf. backend/server.js).
    auto *backend = new QProcess(&app);
    backend->setProcessChannelMode(QProcess::MergedChannels);
    backend->setProgram(QCoreApplication::applicationDirPath() + "/sirenmanager-backend");
    backend->start();
    // Ne laisse jamais d'orphelin : on tue le backend à la fermeture de l'app.
    QObject::connect(&app, &QGuiApplication::aboutToQuit, backend, [backend]() {
        backend->terminate();
        if (!backend->waitForFinished(3000))
            backend->kill();
    });
#endif

    // Enregistrer les types QML
    qmlRegisterType<UdpController>("SirenManager", 1, 0, "UdpController");
    qmlRegisterType<PlaylistManager>("SirenManager", 1, 0, "PlaylistManager");
    qmlRegisterType<PlaylistModel>("SirenManager", 1, 0, "PlaylistModel");

    // Single shared UDP controller across all views — only one process can
    // bind the receive port (8000), and switching destination per call works
    // because sendCommandToMachine updates the address before each send.
    auto *udpManager = new UdpController();
    udpManager->connectToHost(QStringLiteral("192.168.1.101"), 8001);
    qmlRegisterSingletonInstance("SirenManager", 1, 0, "UdpManager", udpManager);

    // SSH controller — proxies through the Node.js backend on localhost:8005.
    // Backend must be running for SystemMaintenance / PlaylistComposer views.
    auto *sshManager = new SshController();
    qmlRegisterSingletonInstance("SirenManager", 1, 0, "SshManager", sshManager);

    // Créer le moteur QML
    QQmlApplicationEngine engine;
    // Debug builds pad the System tab's plots with random past data, so they can
    // be styled without waiting for samples.
#ifdef QT_DEBUG
    engine.rootContext()->setContextProperty(QStringLiteral("isDebugBuild"), true);
#else
    engine.rootContext()->setContextProperty(QStringLiteral("isDebugBuild"), false);
#endif

    // Ajouter le chemin des ressources
    const QUrl url(QStringLiteral("qrc:/SirenManager/QML/Main.qml"));

    // Connexion pour gérer les erreurs de chargement
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreated,
                     &app, [url](QObject *obj, const QUrl &objUrl) {
        if (!obj && url == objUrl)
            QCoreApplication::exit(-1);
    }, Qt::QueuedConnection);

    // Charger le fichier QML principal
    engine.load(url);

    return app.exec();
}

