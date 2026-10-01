#include "SirenConfig.h"
#include <QStandardPaths>
#include <QDir>

// File Extensions
const QString SirenConfig::ExtensionPlaylist = QStringLiteral("listlecture");
const QString SirenConfig::ExtensionPlaylistAlt = QStringLiteral("ListLecture");
const QString SirenConfig::ExtensionMIDI = QStringLiteral(".mid");
const QString SirenConfig::ExtensionMIDIAlt = QStringLiteral(".midi");

// Status Messages
const QString SirenConfig::StatusReady = QStringLiteral("Prêt");
const QString SirenConfig::StatusRAMNA = QStringLiteral("RAM: N/A");
const QString SirenConfig::StatusDiskNA = QStringLiteral("Disque: N/A");
const QString SirenConfig::StatusLoading = QStringLiteral("Chargement...");
const QString SirenConfig::StatusErrorConnection = QStringLiteral("Erreur de connexion");
const QString SirenConfig::StatusErrorSSHUnavailable = QStringLiteral("Erreur: Connexion SSH non disponible");
const QString SirenConfig::StatusErrorManagersNotInitialized = QStringLiteral("Erreur: Managers non initialisés");
const QString SirenConfig::StatusErrorPlaylistPathUndefined = QStringLiteral("Erreur: Chemin playlist non défini");

QString SirenConfig::ipAddressForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::LinuxMaitre: return QStringLiteral("192.168.1.101");
        case MachineType::RaspberryClic: return QStringLiteral("192.168.1.104");
        case MachineType::S1: return QStringLiteral("192.168.1.11");
        case MachineType::S2: return QStringLiteral("192.168.1.12");
        case MachineType::S3: return QStringLiteral("192.168.1.13");
        case MachineType::S4: return QStringLiteral("192.168.1.14");
        case MachineType::S5: return QStringLiteral("192.168.1.15");
        case MachineType::S6: return QStringLiteral("192.168.1.16");
        case MachineType::S7: return QStringLiteral("192.168.1.17");
        case MachineType::VoitureA: return QStringLiteral("192.168.1.50");
        case MachineType::VoitureB: return QStringLiteral("192.168.1.51");
        case MachineType::Pavillon1: return QStringLiteral("192.168.1.52");
        case MachineType::Pavillon2: return QStringLiteral("192.168.1.53");
        default: return QStringLiteral("192.168.1.101");
    }
}

QString SirenConfig::nameForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::LinuxMaitre: return QStringLiteral("Linux Maître");
        case MachineType::RaspberryClic: return QStringLiteral("Raspberry Clic");
        case MachineType::S1: return QStringLiteral("Sirène S1");
        case MachineType::S2: return QStringLiteral("Sirène S2");
        case MachineType::S3: return QStringLiteral("Sirène S3");
        case MachineType::S4: return QStringLiteral("Sirène S4");
        case MachineType::S5: return QStringLiteral("Sirène S5");
        case MachineType::S6: return QStringLiteral("Sirène S6");
        case MachineType::S7: return QStringLiteral("Sirène S7");
        case MachineType::VoitureA: return QStringLiteral("Voiture A");
        case MachineType::VoitureB: return QStringLiteral("Voiture B");
        case MachineType::Pavillon1: return QStringLiteral("Pavillon 1");
        case MachineType::Pavillon2: return QStringLiteral("Pavillon 2");
        default: return QStringLiteral("Linux Maître");
    }
}

// Raspberry Clic = Pi 5 deployment (m_seq/pi5 firmware). Pi2 paths are obsolete.
QString SirenConfig::midiPathForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("/home/sirenateur/WorkSpaceSirenes/Midi/");
        default:
            return QStringLiteral("/mnt/disk/home/guest/WorkSpaceSirenes/Midi/");
    }
}

QString SirenConfig::playlistPathForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("/home/sirenateur/WorkSpaceSirenes/liste_de_lecture/");
        default:
            return QStringLiteral("/mnt/disk/home/guest/WorkSpaceSirenes/liste_de_lecture/");
    }
}

QString SirenConfig::derniereListePathForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("/home/sirenateur/WorkSpaceSirenes/derniere_liste");
        default:
            return QStringLiteral("/mnt/disk/home/guest/WorkSpaceSirenes/derniere_liste");
    }
}

QString SirenConfig::sshUsernameForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("sirenateur");
        default:
            return QStringLiteral("root");
    }
}

QString SirenConfig::sshPasswordForMachineType(MachineType machineType)
{
    // No passwords stored — auth happens via ~/.ssh/config keys.
    Q_UNUSED(machineType)
    return QStringLiteral("");
}

QString SirenConfig::ftpUsernameForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("sirenateur");
        default:
            return QStringLiteral("guest");
    }
}

QString SirenConfig::ftpPasswordForMachineType(MachineType machineType)
{
    switch (machineType) {
        case MachineType::RaspberryClic:
            return QStringLiteral("raspberry");
        default:
            return QStringLiteral("guest");
    }
}

QString SirenConfig::sshKeyPath()
{
    QString homeDir = QStandardPaths::writableLocation(QStandardPaths::HomeLocation);
    return QDir(homeDir).filePath(QStringLiteral(".ssh/id_rsa_sirenes"));
}

QStringList SirenConfig::allMachineIPs()
{
    return {
        QStringLiteral("192.168.1.101"),
        QStringLiteral("192.168.1.104"),
        QStringLiteral("192.168.1.11"),
        QStringLiteral("192.168.1.12"),
        QStringLiteral("192.168.1.13"),
        QStringLiteral("192.168.1.14"),
        QStringLiteral("192.168.1.15"),
        QStringLiteral("192.168.1.16"),
        QStringLiteral("192.168.1.17"),
        QStringLiteral("192.168.1.50"),
        QStringLiteral("192.168.1.51"),
        QStringLiteral("192.168.1.52"),
        QStringLiteral("192.168.1.53")
    };
}

QStringList SirenConfig::allMachineNames()
{
    return {
        QStringLiteral("Linux Maître"),
        QStringLiteral("Raspberry Clic"),
        QStringLiteral("Sirène S1"),
        QStringLiteral("Sirène S2"),
        QStringLiteral("Sirène S3"),
        QStringLiteral("Sirène S4"),
        QStringLiteral("Sirène S5"),
        QStringLiteral("Sirène S6"),
        QStringLiteral("Sirène S7"),
        QStringLiteral("Voiture A"),
        QStringLiteral("Voiture B"),
        QStringLiteral("Pavillon 1"),
        QStringLiteral("Pavillon 2")
    };
}


