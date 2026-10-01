// Configuration SirenConsole : les pupitres (adresses et ports).
// Lue par webfiles/server.js (require('../config.js')) et puredata-proxy.js, servie sous
// /config.js, et parcourue par scripts/update-all-pupitres.sh (lignes host: de pupitres).

const config = {
    // Configuration des pupitres - chargée depuis config.json
    // Les pupitres correspondent aux sirènes physiques définies dans config.json
    pupitres: [
        {
            id: "P1",
            name: "Pupitre 1",
            host: "192.168.1.41",
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P2",
            name: "Pupitre 2",
            host: "localhost",
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P3",
            name: "Pupitre 3", 
            host: "192.168.1.43",
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P4",
            name: "Pupitre 4",
            host: "192.168.1.44", 
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P5",
            name: "Pupitre 5",
            host: "192.168.1.45",
            port: 8000, 
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P6",
            name: "Pupitre 6",
            host: "192.168.1.46",
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        },
        {
            id: "P7",
            name: "Pupitre 7",
            host: "192.168.1.47",
            port: 8000,
            websocketPort: 10002,
            enabled: true,
            status: "disconnected"
        }
    ]
}

// Export pour Node.js
if (typeof module !== 'undefined' && module.exports) {
    module.exports = config
}