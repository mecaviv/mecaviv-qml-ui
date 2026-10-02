const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

// Importer l'API des presets
const presetAPI = require('./api-presets.js');
let currentPresetId = null;

// Initialiser le preset courant dès le démarrage si possible
// (sera exécuté après la définition de getOrCreateCurrentPreset)

// Importer l'API MIDI
const midiAPI = require('./api-midi.js');

// Importer le proxy PureData
const PureDataProxy = require('./puredata-proxy.js');

// Importer l'analyseur MIDI
const { analyzeMidiFile, createFileInfoBuffer, createTempoBuffer, createTimeSigBuffer } = require('./midi-analyzer.js');

// Importer le séquenceur MIDI
const MidiSequencer = require('./midi-sequencer.js');

// Variables globales
let lastVolantData = null; // Stocker les dernières données du volant

// Gestionnaire d'état de synchronisation
const syncState = new Map(); // pupitreId -> { isSynced: bool, lastSync: timestamp }

// Suivi des demandes de download en cours
const pendingConfigRequests = new Map(); // pupitreId -> { timestamp, timeout }

function setSyncEnabled(pupitreId, enabled) {
    const current = syncState.get(pupitreId) || { isSynced: false, lastSync: null };
    syncState.set(pupitreId, { isSynced: enabled, lastSync: enabled ? Date.now() : current.lastSync });
    
    // Diffuser le changement via WebSocket
    broadcastToClients({
        type: 'SYNC_STATUS_CHANGED',
        pupitreId: pupitreId,
        isSynced: enabled,
        timestamp: Date.now()
    });
}

function isSynced(pupitreId) {
    return syncState.get(pupitreId)?.isSynced || false;
}

function getAllSyncedPupitres() {
    const synced = [];
    for (const [pupitreId, state] of syncState.entries()) {
        if (state.isSynced) {
            synced.push(pupitreId);
        }
    }
    return synced;
}

// Fonctions de mapping Preset ↔ PureData Path
function convertPresetToParamUpdates(preset, pupitreId) {
    const updates = [];
    if (!preset || !preset.config || !preset.config.pupitres) return updates;
    
    const pupitreConfig = preset.config.pupitres.find(p => p.id === pupitreId);
    if (!pupitreConfig) return updates;
    
    // assignedSirenes → ["sirenConfig", "currentSirens"] (ids sirène = nombres)
    if (Array.isArray(pupitreConfig.assignedSirenes)) {
        updates.push({
            type: "PARAM_UPDATE",
            path: ["sirenConfig", "currentSirens"],
            value: pupitreConfig.assignedSirenes.map(n => (typeof n === 'number' ? n : parseInt(String(n), 10))).filter(n => !isNaN(n)),
            source: "console"
        });
    }
    
    // sirenes[sireneN].ambitusRestricted → ["sirenConfig", "sirens", N, "ambitus", "restricted"]
    // sirenes[sireneN].frettedMode → ["sirenConfig", "sirens", N, "frettedMode", "enabled"]
    if (pupitreConfig.sirenes) {
        for (const [key, sireneConfig] of Object.entries(pupitreConfig.sirenes)) {
            const sireneNum = parseInt(key.replace('sirene', ''), 10);
            if (isNaN(sireneNum)) continue;
            const sireneIndex = sireneNum - 1; // 0-based index
            
            if (sireneConfig.ambitusRestricted !== undefined) {
                updates.push({
                    type: "PARAM_UPDATE",
                    path: ["sirenConfig", "sirens", sireneIndex, "ambitus", "restricted"],
                    value: sireneConfig.ambitusRestricted ? 1 : 0,
                    source: "console"
                });
            }
            
            if (sireneConfig.frettedMode !== undefined) {
                updates.push({
                    type: "PARAM_UPDATE",
                    path: ["sirenConfig", "sirens", sireneIndex, "frettedMode", "enabled"],
                    value: sireneConfig.frettedMode ? 1 : 0,
                    source: "console"
                });
            }
        }
    }
    
    // vstEnabled/udpEnabled/rtpMidiEnabled → ["outputConfig", "..."]
    if (pupitreConfig.vstEnabled !== undefined) {
        updates.push({
            type: "PARAM_UPDATE",
            path: ["outputConfig", "vstEnabled"],
            value: pupitreConfig.vstEnabled ? 1 : 0,
            source: "console"
        });
    }
    if (pupitreConfig.udpEnabled !== undefined) {
        updates.push({
            type: "PARAM_UPDATE",
            path: ["outputConfig", "udpEnabled"],
            value: pupitreConfig.udpEnabled ? 1 : 0,
            source: "console"
        });
    }
    if (pupitreConfig.rtpMidiEnabled !== undefined) {
        updates.push({
            type: "PARAM_UPDATE",
            path: ["outputConfig", "rtpMidiEnabled"],
            value: pupitreConfig.rtpMidiEnabled ? 1 : 0,
            source: "console"
        });
    }
    
    // controllerMapping[ctrl].cc/curve → ["controllerMapping", ctrl, "cc/curve"]
    if (pupitreConfig.controllerMapping) {
        for (const [ctrl, mapping] of Object.entries(pupitreConfig.controllerMapping)) {
            if (mapping.cc !== undefined) {
                updates.push({
                    type: "PARAM_UPDATE",
                    path: ["controllerMapping", ctrl, "cc"],
                    value: mapping.cc,
                    source: "console"
                });
            }
            if (mapping.curve) {
                updates.push({
                    type: "PARAM_UPDATE",
                    path: ["controllerMapping", ctrl, "curve"],
                    value: mapping.curve,
                    source: "console"
                });
            }
        }
    }
    
    // gameMode → ["gameMode", "enabled"]
    if (pupitreConfig.gameMode !== undefined) {
        updates.push({
            type: "PARAM_UPDATE",
            path: ["gameMode", "enabled"],
            value: pupitreConfig.gameMode ? 1 : 0,
            source: "console"
        });
    }
    
    return updates;
}

function ensureCurrentPreset(data) {
    // Si pas de données ou structure invalide, retourner null (sera géré par l'appelant)
    if (!data || !Array.isArray(data.presets) || data.presets.length === 0) {
        return null;
    }

    if (currentPresetId) {
        const existing = data.presets.find(p => p.id === currentPresetId);
        if (existing) {
            return existing;
        }
    }

    const fallback = data.presets[0] || null;
    if (fallback) {
        currentPresetId = fallback.id || fallback.name || null;
    } else {
        currentPresetId = null;
    }
    return fallback;
}

// Fonction helper pour obtenir ou créer un preset courant (async)
async function getOrCreateCurrentPreset() {
    try {
        const data = await presetAPI.readPresets();
        let preset = ensureCurrentPreset(data);
        
        // Si aucun preset, créer un preset par défaut
        if (!preset) {
            const defaultPresets = presetAPI.createDefaultPresets();
            if (defaultPresets.presets && defaultPresets.presets.length > 0) {
                await presetAPI.writePresets(defaultPresets);
                preset = ensureCurrentPreset(defaultPresets);
            }
        }
        
        return preset;
    } catch (error) {
        return null;
    }
}

// Initialiser le preset courant après la définition de getOrCreateCurrentPreset
(async () => {
    try {
        await getOrCreateCurrentPreset();
    } catch (err) {
        // Ignorer les erreurs silencieusement
    }
})();

// Le preset tel qu'il est dans `data`, les données qu'on va écrire. Les routes PATCH lisaient
// le preset courant puis relisaient le fichier : elles modifiaient la première copie et
// écrivaient la seconde, si bien que rien n'était enregistré (mesuré sur /outputs).
function presetIn(data, preset) {
    let target = data.presets.find(p => p.id === preset.id);
    if (!target) {
        data.presets.push(preset);
        target = preset;
    }
    return target;
}

function getOrCreatePupitreEntry(preset, pupitreId) {
    if (!preset || !pupitreId) {
        return null;
    }

    if (!preset.config) {
        preset.config = {};
    }

    if (!Array.isArray(preset.config.pupitres)) {
        preset.config.pupitres = [];
    }

    let entry = preset.config.pupitres.find(p => p.id === pupitreId);
    if (!entry) {
        entry = {
            id: pupitreId,
            assignedSirenes: [],
            controllerMapping: {},
            sirenes: {},
            gameMode: false
        };
        preset.config.pupitres.push(entry);
    }

    return entry;
}

function convertParamUpdateToPreset(path, value, pupitreId, preset) {
    if (!path || !Array.isArray(path) || path.length === 0) return preset;
    if (!preset || !preset.config) preset = { config: { pupitres: [] } };
    if (!preset.config.pupitres) preset.config.pupitres = [];
    
    let pupitreConfig = preset.config.pupitres.find(p => p.id === pupitreId);
    if (!pupitreConfig) {
        pupitreConfig = { id: pupitreId };
        preset.config.pupitres.push(pupitreConfig);
    }
    
    // assignedSirenes
    if (path.length === 2 && path[0] === "sirenConfig" && path[1] === "assignedSirenes") {
        pupitreConfig.assignedSirenes = Array.isArray(value) ? value : [];
    }
    // NEW: currentSirens -> assignedSirenes
    else if (path.length === 2 && path[0] === "sirenConfig" && path[1] === "currentSirens") {
        pupitreConfig.assignedSirenes = Array.isArray(value)
            ? value.map(v => (typeof v === 'string' ? parseInt(v, 10) : v)).filter(v => !isNaN(v))
            : [];
    }
    // sirenes[sireneN].ambitus.restricted
    else if (path.length === 5 && path[0] === "sirenConfig" && path[1] === "sirens" && path[3] === "ambitus" && path[4] === "restricted") {
        const sireneIndex = parseInt(path[2], 10);
        if (!isNaN(sireneIndex)) {
            const sireneNum = sireneIndex + 1;
            const key = 'sirene' + sireneNum;
            if (!pupitreConfig.sirenes) pupitreConfig.sirenes = {};
            if (!pupitreConfig.sirenes[key]) pupitreConfig.sirenes[key] = {};
            pupitreConfig.sirenes[key].ambitusRestricted = value ? true : false;
        }
    }
    // sirenes[sireneN].frettedMode.enabled
    else if (path.length === 5 && path[0] === "sirenConfig" && path[1] === "sirens" && path[3] === "frettedMode" && path[4] === "enabled") {
        const sireneIndex = parseInt(path[2], 10);
        if (!isNaN(sireneIndex)) {
            const sireneNum = sireneIndex + 1;
            const key = 'sirene' + sireneNum;
            if (!pupitreConfig.sirenes) pupitreConfig.sirenes = {};
            if (!pupitreConfig.sirenes[key]) pupitreConfig.sirenes[key] = {};
            pupitreConfig.sirenes[key].frettedMode = value ? true : false;
        }
    }
    // outputConfig.*
    else if (path.length === 2 && path[0] === "outputConfig") {
        if (path[1] === "vstEnabled") pupitreConfig.vstEnabled = value ? true : false;
        else if (path[1] === "udpEnabled") pupitreConfig.udpEnabled = value ? true : false;
        else if (path[1] === "rtpMidiEnabled") pupitreConfig.rtpMidiEnabled = value ? true : false;
    }
    // gameMode.enabled
    else if (path.length === 2 && path[0] === "gameMode" && path[1] === "enabled") {
        pupitreConfig.gameMode = value ? true : false;
    }
    // controllerMapping[ctrl].cc/curve
    else if (path.length === 3 && path[0] === "controllerMapping") {
        const ctrl = path[1];
        if (!pupitreConfig.controllerMapping) pupitreConfig.controllerMapping = {};
        if (!pupitreConfig.controllerMapping[ctrl]) pupitreConfig.controllerMapping[ctrl] = {};
        if (path[2] === "cc") {
            pupitreConfig.controllerMapping[ctrl].cc = parseInt(value, 10);
        } else if (path[2] === "curve") {
            pupitreConfig.controllerMapping[ctrl].curve = String(value);
        }
    }
    
    return preset;
}

// Charger la configuration depuis config.json
const { loadConfig } = require('../../config-loader.js');
const config = loadConfig();

// Charger aussi la configuration SirenConsole pour les pupitres
const sirenConsoleConfig = require('../config.js');

// Chemin du répertoire MIDI
const MIDI_REPO_PATH = process.env.MECAVIV_COMPOSITIONS_PATH || config.paths.midiRepository;

// Configuration du serveur
const PORT = 8001; // Port différent de SirenePupitre (8000)
const HOST = '0.0.0.0';

// Configuration SSL
const SSL_KEY_PATH = process.env.SSL_KEY_PATH || path.join(__dirname, 'ssl', 'key.pem');
const SSL_CERT_PATH = process.env.SSL_CERT_PATH || path.join(__dirname, 'ssl', 'cert.pem');
const USE_HTTPS = process.env.USE_HTTPS !== 'false'; // Par défaut HTTPS activé

// Initialiser le proxy PureData et le séquenceur
let pureDataProxy = null;
let midiSequencer = null;

// Serveur WebSocket pour les connexions clients
let wss = null;
let connectedClients = new Set();

// Middleware pour les headers CORS et sécurité
function setSecurityHeaders(response) {
    // Headers CORS basiques
    response.setHeader('Access-Control-Allow-Origin', '*');
    response.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
    response.setHeader('Access-Control-Allow-Headers', 'Origin, X-Requested-With, Content-Type, Accept, Authorization, Sec-WebSocket-Protocol, Sec-WebSocket-Version');
    response.setHeader('Vary', 'Origin');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    
    // Headers spécifiques pour WebSocket
    response.setHeader('Sec-WebSocket-Protocol', 'websocket');
    response.setHeader('Sec-WebSocket-Version', '13');
}

// Fonctions pour gérer les WebSockets
function broadcastToClients(message) {
    const messageStr = typeof message === 'string' ? message : JSON.stringify(message);
    connectedClients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            try {
                client.send(messageStr);
            } catch (error) {
                console.error('❌ Erreur envoi WebSocket client:', error);
                connectedClients.delete(client);
            }
        }
    });
}

// Fonction pour broadcaster des buffers binaires aux clients UI
function broadcastBinaryToUIClients(buffer) {
    // console.log('📡 broadcastBinaryToUIClients appelé, clients connectés:', connectedClients.size, 'buffer[0]=0x' + buffer[0].toString(16).padStart(2, '0'));
    let sentCount = 0;
    connectedClients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            try {
                client.send(buffer);
                sentCount++;
            } catch (error) {
                console.error('❌ Erreur envoi binaire WebSocket client:', error);
                connectedClients.delete(client);
            }
        }
    });
    // console.log('📡 Message binaire envoyé à', sentCount, 'clients UI');
}

// Convertir note MIDI + pitchbend → fréquence (Hz)
function midiToFrequency(note, pitchbend, transposition = 0) {
    // Appliquer la transposition (octaves)
    const transposedNote = note + (transposition * 12)
    
    // Formule MIDI standard : f = 440 * 2^((note - 69) / 12)
    const baseFrequency = 440 * Math.pow(2, (transposedNote - 69) / 12)
    
    // Appliquer le pitchbend (0-16383, centre = 8192)
    const pitchbendFactor = (pitchbend - 8192) / 8192 // -1 à +1
    const pitchbendSemitones = pitchbendFactor * 0.5 // ±0.5 demi-ton max
    
    return baseFrequency * Math.pow(2, pitchbendSemitones / 12)
}

// Convertir fréquence → RPM pour chaque sirène
function frequencyToRpm(frequency, outputs) {
    // RPM = Fréquence × 60 / Nombre de sorties
    return frequency * 60 / outputs
}

function handleWebSocketConnection(ws, request) {
    // console.log('🔌 Nouvelle connexion WebSocket'); // Désactivé pour éviter le spam
    
    // Attendre un message d'identification pour déterminer le type de client
    ws.on('message', (message) => {
        // Vérifier si c'est un message binaire
        if (Buffer.isBuffer(message)) {
            // Essayer de convertir en string pour voir si c'est du JSON
            try {
                const text = message.toString('utf8')
                const data = JSON.parse(text)
                
                // Traiter comme un message JSON
                if (data.type === 'PING') {
                    // PING reçu, renvoyer PONG (sans log pour éviter le spam)
                    ws.send(JSON.stringify({ 
                        type: 'PONG', 
                        source: 'SERVER_NODEJS',
                        timestamp: Date.now() 
                    }))
                } else if (data.type === 'SIRENCONSOLE_IDENTIFICATION') {
                    // Ajouter le client à la liste des clients connectés
                    connectedClients.add(ws);
                    
                    // Envoyer le statut initial avec informations de synchronisation
                    if (pureDataProxy) {
                        const status = pureDataProxy.getStatus();
                        // Ajouter les informations de synchronisation à chaque connexion
                        if (status.connections) {
                            status.connections = status.connections.map(conn => {
                                const syncInfo = syncState.get(conn.pupitreId);
                                return {
                                    ...conn,
                                    isSynced: syncInfo?.isSynced || false,
                                    lastSync: syncInfo?.lastSync || null
                                };
                            });
                        }
                        ws.send(JSON.stringify({
                            type: 'INITIAL_STATUS',
                            data: status
                        }));
                    }
                }
            } catch (e) {
                // Ignorer les messages binaires qui ne sont pas du JSON
            }
            
            if (message.length === 8) {
                const magic = message.readUInt16BE(0)
                
                if (magic === 0x5353) { // Magic "SS"
                    const type = message.readUInt8(2)
                    const pupitreId = message.readUInt8(3)
                    const note = message.readUInt8(4)
                    const velocity = message.readUInt8(5)
                    const pitchbend = message.readUInt16BE(6)
                    
                    if (type === 0x01 && pupitreId === 3) { // VOLANT_STATE pour P3
                        // Convertir note MIDI → fréquence → RPM (S3: transposition +1 octave, 8 sorties)
                        const frequency = midiToFrequency(note, pitchbend, 1) // +1 octave pour S3
                        const rpm = frequencyToRpm(frequency, 8) // 8 sorties pour S3
                        
                        // Stocker les dernières données du volant
                        lastVolantData = {
                            pupitreId: pupitreId,
                            note: note,
                            velocity: velocity,
                            pitchbend: pitchbend,
                            frequency: frequency,
                            rpm: rpm,
                            timestamp: Date.now()
                        };
                        
                        // Diffuser aux clients UI, sous la même forme que puredata-proxy.js
                        // (noteFloat, pupitreId "P3") : le client ignore VOLANT_DATA sans noteFloat
                        if (pureDataProxy) {
                            pureDataProxy.broadcastVolantData(`P${pupitreId}`, note, velocity, pitchbend, frequency, rpm)
                        }
                    }
                }
            }
            return
        }
        
        try {
            const data = JSON.parse(message);
            // console.log('📥 Message WebSocket reçu:', data.type); // Désactivé pour éviter le spam
            
            // Vérifier si c'est un pupitre qui se connecte
            if (data.type === 'PUPITRE_IDENTIFICATION' && data.pupitreId) {
                // console.log(`🎛️ Pupitre ${data.pupitreId} identifié`); // Désactivé pour éviter le spam
                
                // Gérer la connexion du pupitre via le proxy PureData
                if (pureDataProxy) {
                    const pupitreInfo = {
                        id: data.pupitreId,
                        name: data.pupitreName || `Pupitre ${data.pupitreId}`,
                        host: request.socket.remoteAddress,
                        port: 8000,
                        websocketPort: 10002,
                        enabled: true
                    };
                    
                    pureDataProxy.handleIncomingConnection(ws, data.pupitreId, pupitreInfo);
                }
                
                // Envoyer confirmation au pupitre
                ws.send(JSON.stringify({
                    type: 'PUPITRE_CONNECTED',
                    pupitreId: data.pupitreId,
                    timestamp: Date.now()
                }));
                
            } else {
                // C'est un client SirenConsole (interface web)
                // console.log('🌐 Client SirenConsole connecté'); // Désactivé pour éviter le spam
                
                // Traiter les messages des clients SirenConsole
                ws.on('message', (message) => {
                    try {
                        const data = JSON.parse(message);
                        // console.log('📥 Message SirenConsole reçu:', data.type); // Désactivé pour éviter le spam
                        
                        switch (data.type) {
                            case 'PING':
                                // PING reçu, renvoyer PONG (sans log pour éviter le spam)
                                ws.send(JSON.stringify({ 
                                    type: 'PONG', 
                                    source: 'SERVER_NODEJS',
                                    timestamp: Date.now() 
                                }));
                                break;
                            case 'SIRENCONSOLE_IDENTIFICATION':
                                // console.log('🔑 Client SirenConsole QML identifié');
                                // Ajouter le client à la liste des clients connectés
                                connectedClients.add(ws);
                                
                                // Envoyer le statut initial
                                if (pureDataProxy) {
                                    const status = pureDataProxy.getStatus();
                                    ws.send(JSON.stringify({
                                        type: 'INITIAL_STATUS',
                                        data: status
                                    }));
                                }
                                break;
                            default:
                                // console.log('⚠️ Type message SirenConsole inconnu:', data.type);
                        }
                    } catch (error) {
                        console.error('❌ Erreur parsing message SirenConsole:', error);
                    }
                });
                
                // Les messages sont maintenant traités par le gestionnaire ws.on('message') ci-dessus
            }
        } catch (error) {
            console.error('❌ Erreur parsing message WebSocket:', error);
        }
    });
    
    ws.on('close', (code, reason) => {
        // console.log('❌ WebSocket déconnecté:', code, reason.toString());
        connectedClients.delete(ws);
    });
    
    ws.on('error', (error) => {
        console.error('❌ Erreur WebSocket:', error);
        connectedClients.delete(ws);
    });
}

// Fonction de gestion des requêtes (utilisée par HTTP et HTTPS)
function requestHandler(request, response) {
    // Logs uniquement pour les requêtes intéressantes (pas les GET polling)
    if (request.method !== 'GET' || !request.url.includes('/api/puredata/playback')) {
        // Requête reçue
    }
    
    // Appliquer les headers de sécurité
    setSecurityHeaders(response);
    
    // Gestion des requêtes OPTIONS (CORS preflight)
    if (request.method === 'OPTIONS') {
        response.writeHead(200);
        response.end();
        return;
    }

    // Gestion des routes
    let filePath = '.' + request.url;
    
    // Route pour config.js (dans le répertoire parent)
    if (request.url === '/config.js') {
        filePath = '../config.js';
    }
    
    // --- Current preset endpoints ---
    if (request.url === '/api/presets/current' || (request.url.startsWith('/api/presets/current') && request.method === 'GET')) {
        (async () => {
            try {
                const preset = await getOrCreateCurrentPreset();
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ preset, currentId: currentPresetId }));
            } catch (e) {
                response.writeHead(500, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ error: e.message }));
            }
        })();
        return;
    }
    
    // Routes API pour les presets (générique) - exclure explicitement /api/presets/current...
    if (request.url.startsWith('/api/presets')
        && !request.url.startsWith('/api/presets/current')) {
        // Rediriger vers l'API des presets
        presetAPI.app(request, response);
        return;
    }
    if ((request.url === '/api/presets/current' || request.url.startsWith('/api/presets/current')) && request.method === 'PUT') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const updatedPreset = JSON.parse(body);
                const data = await presetAPI.readPresets();
                const idx = data.presets.findIndex(p => p.id === updatedPreset.id);
                if (idx === -1) data.presets.push(updatedPreset); else data.presets[idx] = updatedPreset;
                currentPresetId = updatedPreset.id;
                await presetAPI.writePresets(data);
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ preset: updatedPreset, currentId: currentPresetId }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }
    if ((request.url === '/api/presets/current/assigned-sirenes' || request.url.startsWith('/api/presets/current/assigned-sirenes')) && request.method === 'PATCH') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const { pupitreId, assignedSirenes } = JSON.parse(body);
                if (!pupitreId) throw new Error('Missing pupitreId');
                const preset = await getOrCreateCurrentPreset();
                if (!preset) throw new Error('Impossible de créer un preset par défaut');
                const data = await presetAPI.readPresets();
                const p = getOrCreatePupitreEntry(presetIn(data, preset), pupitreId);
                p.assignedSirenes = Array.isArray(assignedSirenes) ? assignedSirenes : [];
                await presetAPI.writePresets(data);
                
                // Envoyer PARAM_UPDATE si synchronisé (ids sirène numériques)
                if (isSynced(pupitreId) && pureDataProxy) {
                    const update = {
                        type: "PARAM_UPDATE",
                        path: ["sirenConfig", "currentSirens"],
                        value: p.assignedSirenes.map(n => (typeof n === 'number' ? n : parseInt(String(n), 10))).filter(n => !isNaN(n)),
                        source: "console"
                    };
                    pureDataProxy.sendToPupitre(pupitreId, update);
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, presetId: preset.id, pupitreId, assignedSirenes: p.assignedSirenes }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    if ((request.url === '/api/presets/current/sirene-config' || request.url.startsWith('/api/presets/current/sirene-config')) && request.method === 'PATCH') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const { pupitreId, sireneId, changes } = JSON.parse(body);
                if (!pupitreId) throw new Error('Missing pupitreId');
                if (!sireneId) throw new Error('Missing sireneId');
                const preset = await getOrCreateCurrentPreset();
                if (!preset) throw new Error('Impossible de créer un preset par défaut');
                const data = await presetAPI.readPresets();
                const p = getOrCreatePupitreEntry(presetIn(data, preset), pupitreId);
                if (!p.sirenes) p.sirenes = {};
                const key = 'sirene' + (typeof sireneId === 'number' ? sireneId : parseInt(sireneId, 10));
                if (!p.sirenes[key]) p.sirenes[key] = { ambitusRestricted: false, frettedMode: false };
                const ch = changes || {};
                Object.keys(ch).forEach(k => { p.sirenes[key][k] = ch[k]; });
                await presetAPI.writePresets(data);
                
                // Envoyer PARAM_UPDATE si synchronisé
                if (isSynced(pupitreId) && pureDataProxy) {
                    const sireneIndex = (typeof sireneId === 'number' ? sireneId : parseInt(sireneId, 10)) - 1;
                    for (const k in ch) {
                        if (k === 'ambitusRestricted') {
                            pureDataProxy.sendToPupitre(pupitreId, {
                                type: "PARAM_UPDATE",
                                path: ["sirenConfig", "sirens", sireneIndex, "ambitus", "restricted"],
                                value: ch[k] ? 1 : 0,
                                source: "console"
                            });
                        } else if (k === 'frettedMode') {
                            pureDataProxy.sendToPupitre(pupitreId, {
                                type: "PARAM_UPDATE",
                                path: ["sirenConfig", "sirens", sireneIndex, "frettedMode", "enabled"],
                                value: ch[k] ? 1 : 0,
                                source: "console"
                            });
                        }
                    }
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, presetId: preset.id, pupitreId, sireneId, sirene: p.sirenes[key] }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    if ((request.url === '/api/presets/current/outputs' || request.url.startsWith('/api/presets/current/outputs')) && request.method === 'PATCH') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const { pupitreId, changes } = JSON.parse(body);
                if (!pupitreId) throw new Error('Missing pupitreId');
                const preset = await getOrCreateCurrentPreset();
                if (!preset) throw new Error('Impossible de créer un preset par défaut');
                const data = await presetAPI.readPresets();
                const p = getOrCreatePupitreEntry(presetIn(data, preset), pupitreId);
                const ch = changes || {};
                ['vstEnabled','udpEnabled','rtpMidiEnabled'].forEach(k => { if (k in ch) p[k] = !!ch[k]; });
                await presetAPI.writePresets(data);
                
                // Envoyer PARAM_UPDATE si synchronisé
                if (isSynced(pupitreId) && pureDataProxy) {
                    if ('vstEnabled' in ch) {
                        pureDataProxy.sendToPupitre(pupitreId, {
                            type: "PARAM_UPDATE",
                            path: ["outputConfig", "vstEnabled"],
                            value: ch.vstEnabled ? 1 : 0,
                            source: "console"
                        });
                    }
                    if ('udpEnabled' in ch) {
                        pureDataProxy.sendToPupitre(pupitreId, {
                            type: "PARAM_UPDATE",
                            path: ["outputConfig", "udpEnabled"],
                            value: ch.udpEnabled ? 1 : 0,
                            source: "console"
                        });
                    }
                    if ('rtpMidiEnabled' in ch) {
                        pureDataProxy.sendToPupitre(pupitreId, {
                            type: "PARAM_UPDATE",
                            path: ["outputConfig", "rtpMidiEnabled"],
                            value: ch.rtpMidiEnabled ? 1 : 0,
                            source: "console"
                        });
                    }
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, presetId: preset.id, pupitreId, outputs: { vstEnabled: p.vstEnabled, udpEnabled: p.udpEnabled, rtpMidiEnabled: p.rtpMidiEnabled } }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    if ((request.url === '/api/presets/current/controller-mapping' || request.url.startsWith('/api/presets/current/controller-mapping')) && request.method === 'PATCH') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const { pupitreId, controller, cc, curve } = JSON.parse(body);
                if (!pupitreId) throw new Error('Missing pupitreId');
                if (!controller) throw new Error('Missing controller');
                const preset = await getOrCreateCurrentPreset();
                if (!preset) throw new Error('Impossible de créer un preset par défaut');
                const data = await presetAPI.readPresets();
                const p = getOrCreatePupitreEntry(presetIn(data, preset), pupitreId);
                if (!p.controllerMapping) p.controllerMapping = {};
                if (!p.controllerMapping[controller]) p.controllerMapping[controller] = {};
                if (cc !== undefined) p.controllerMapping[controller].cc = parseInt(cc, 10);
                if (curve) p.controllerMapping[controller].curve = String(curve);
                await presetAPI.writePresets(data);
                
                // Envoyer PARAM_UPDATE si synchronisé
                if (isSynced(pupitreId) && pureDataProxy) {
                    if (cc !== undefined) {
                        pureDataProxy.sendToPupitre(pupitreId, {
                            type: "PARAM_UPDATE",
                            path: ["controllerMapping", controller, "cc"],
                            value: parseInt(cc, 10),
                            source: "console"
                        });
                    }
                    if (curve) {
                        pureDataProxy.sendToPupitre(pupitreId, {
                            type: "PARAM_UPDATE",
                            path: ["controllerMapping", controller, "curve"],
                            value: String(curve),
                            source: "console"
                        });
                    }
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, presetId: preset.id, pupitreId, controller, mapping: p.controllerMapping[controller] }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    if ((request.url === '/api/presets/current/game-mode' || request.url.startsWith('/api/presets/current/game-mode')) && request.method === 'PATCH') {
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', async () => {
            try {
                const { pupitreId, gameMode } = JSON.parse(body);
                if (!pupitreId) throw new Error('Missing pupitreId');
                const preset = await getOrCreateCurrentPreset();
                if (!preset) throw new Error('Impossible de créer un preset par défaut');
                const data = await presetAPI.readPresets();
                const p = getOrCreatePupitreEntry(presetIn(data, preset), pupitreId);
                p.gameMode = gameMode !== undefined ? !!gameMode : false;
                await presetAPI.writePresets(data);
                
                // Envoyer PARAM_UPDATE si synchronisé
                if (isSynced(pupitreId) && pureDataProxy) {
                    pureDataProxy.sendToPupitre(pupitreId, {
                        type: "PARAM_UPDATE",
                        path: ["gameMode", "enabled"],
                        value: p.gameMode ? 1 : 0,
                        source: "console"
                    });
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, presetId: preset.id, pupitreId, gameMode: p.gameMode }));
            } catch (e) {
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    
    // Endpoint GET /api/pupitres/:id/sync-status
    if (request.method === 'GET' && request.url.startsWith('/api/pupitres/') && request.url.endsWith('/sync-status')) {
        const pupitreId = request.url.split('/')[3];
        const state = syncState.get(pupitreId) || { isSynced: false, lastSync: null };
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ pupitreId, isSynced: state.isSynced, lastSync: state.lastSync }));
        return;
    }
    
    // Endpoint POST /api/presets/current/upload - Envoyer preset vers tous pupitres connectés
    if ((request.url === '/api/presets/current/upload' || request.url.startsWith('/api/presets/current/upload')) && request.method === 'POST') {
        (async () => {
            try {
                const preset = await getOrCreateCurrentPreset();
                if (!preset) {
                    response.writeHead(500, { 'Content-Type': 'application/json' });
                    response.end(JSON.stringify({ success: false, error: 'Impossible de créer un preset par défaut' }));
                    return;
                }
                
                const results = {};
                const status = pureDataProxy.getStatus();
                
                for (const conn of status.connections) {
                    if (conn.connected) {
                        const pupitreId = conn.pupitreId;
                        try {
                            // Activer sync si pas déjà activé
                            if (!isSynced(pupitreId)) {
                                setSyncEnabled(pupitreId, true);
                            }
                            
                            // Envoyer CONSOLE_CONNECT d'abord
                            pureDataProxy.sendToPupitre(pupitreId, {
                                type: "CONSOLE_CONNECT",
                                source: "console"
                            });
                            
                            // Convertir preset en PARAM_UPDATE
                            const updates = convertPresetToParamUpdates(preset, pupitreId);
                            
                            // Envoyer tous les updates
                            let successCount = 0;
                            for (const update of updates) {
                                if (pureDataProxy.sendToPupitre(pupitreId, update)) {
                                    successCount++;
                                }
                            }
                            
                            results[pupitreId] = {
                                success: true,
                                updatesSent: successCount,
                                totalUpdates: updates.length
                            };
                        } catch (e) {
                            results[pupitreId] = {
                                success: false,
                                error: e.message
                            };
                        }
                    } else {
                        results[conn.pupitreId] = {
                            success: false,
                            error: 'Pupitre not connected'
                        };
                    }
                }
                
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: true, results }));
            } catch (e) {
                response.writeHead(500, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        })();
        return;
    }
    
    // Endpoint POST /api/presets/current/download - Récupérer config depuis tous pupitres connectés
    if ((request.url === '/api/presets/current/download' || request.url.startsWith('/api/presets/current/download')) && request.method === 'POST') {
        (async () => {
            try {
                const preset = await getOrCreateCurrentPreset();
                if (!preset) {
                    response.writeHead(500, { 'Content-Type': 'application/json' });
                    response.end(JSON.stringify({ success: false, error: 'Impossible de créer un preset par défaut' }));
                    return;
                }
                
                const status = pureDataProxy.getStatus();
                const results = {};
                const pendingRequests = new Map();
                
                // console.log('📥 Download demandé - Status:', {
                //     totalConnections: status.totalConnections,
                //     connectedCount: status.connectedCount,
                //     connections: status.connections.map(c => ({ 
                //         pupitreId: c.pupitreId, 
                //         connected: c.connected, 
                //         synced: isSynced(c.pupitreId) 
                //     })),
                //     syncState: Array.from(syncState.entries()).map(([id, state]) => ({ id, state }))
                // });
                
                // IMPORTANT: Pour le Download, on peut envoyer même si pas synchronisé (c'est une demande de lecture)
                // Envoyer REQUEST_PUPITRE_CONFIG à PureData (source de vérité) pour tous les pupitres connectés
                let requestsSent = 0;
                for (const conn of status.connections) {
                    if (conn.connected) {
                        // Activer sync temporairement si pas déjà fait (pour le download)
                        if (!isSynced(conn.pupitreId)) {
                            // console.log(`ℹ️ Activation sync temporaire pour ${conn.pupitreId} (download)`);
                            setSyncEnabled(conn.pupitreId, true);
                        }
                        
                        const pupitreId = conn.pupitreId;
                        const requestTimestamp = Date.now();
                        pendingRequests.set(pupitreId, { timestamp: requestTimestamp });
                        
                        // Marquer qu'une demande est en cours (timeout 10 secondes)
                        pendingConfigRequests.set(pupitreId, { 
                            timestamp: requestTimestamp, 
                            timeout: setTimeout(() => {
                                pendingConfigRequests.delete(pupitreId);
                            }, 10000)
                        });
                        
                        // Demander la config à PureData (source de vérité)
                        const sent = pureDataProxy.requestPupitreConfig(pupitreId);
                        if (sent) {
                            requestsSent++;
                        }
                    } else {
                        // console.log(`⏭️ Pupitre ${conn.pupitreId} ignoré - connected: ${conn.connected}, synced: ${isSynced(conn.pupitreId)}`);
                    }
                }
                
                
                // Attendre les réponses (timeout 5s)
                const timeout = 5000;
                const startTime = Date.now();
                
                while (pendingRequests.size > 0 && (Date.now() - startTime) < timeout) {
                    await new Promise(resolve => setTimeout(resolve, 100));
                    // Les réponses seront traitées via handleMessage dans PureDataProxy
                    // Pour simplifier, on attend ici mais en pratique il faudrait un système de callbacks
                }
                
                // Retourner un statut - les réponses CONFIG_FULL depuis PureData seront traitées via handlePupitreConfigFromPupitre
                response.writeHead(200, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ 
                    success: true, 
                    message: 'Download initiated. PureData will send CONFIG_FULL responses via existing connections.',
                    requestedFrom: Array.from(pendingRequests.keys())
                }));
            } catch (e) {
                response.writeHead(500, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        })();
        return;
    }
    
    // Routes API MIDI
    if (request.url === '/api/midi/files') {
        midiAPI.getMidiFiles(request, response);
        return;
    }

    // Endpoint GET /api/puredata/playback - État du playback séquenceur
    if (request.url === '/api/puredata/playback' && request.method === 'GET') {
        try {
            const state = midiSequencer && typeof midiSequencer.getState === 'function' ? midiSequencer.getState() : null;
            const payload = state ? {
                playing: !!state.playing,
                bar: state.bar || 0,
                beatInBar: state.beatInBar || 0,
                beat: state.beat || 0,
                position: state.position || Math.floor(((state.beat || 0) / (state.tempo || 120)) * 60000),
                tempo: state.tempo || 120,
                duration: state.duration || 0,
                totalBeats: state.totalBeats || 0,
                timeSignature: state.timeSignature || { numerator: 4, denominator: 4 },
                file: state.file || ""
            } : {
                playing: false, bar: 0, beatInBar: 0, beat: 0, position: 0, tempo: 120,
                duration: 0, totalBeats: 0, timeSignature: { numerator: 4, denominator: 4 }, file: ""
            };
            response.writeHead(200, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify(payload));
        } catch (e) {
            response.writeHead(500, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify({ error: e.message }));
        }
        return;
    }
    
    if (request.url === '/api/midi/categories') {
        midiAPI.getMidiCategories(request, response);
        return;
    }
    
    // Route API pour les données du volant
    if (request.url === '/api/volant-data') {
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ volantData: lastVolantData }));
        return;
    }
    
    // Routes API PureData Proxy
    if (request.url === '/api/puredata/command' && request.method === 'POST') {
        let body = '';
        request.on('data', chunk => { body += chunk; });
        request.on('end', () => {
            try {
                const command = JSON.parse(body);
                
                // Traiter les commandes MIDI
                let success = false;
                let message = '';
                
                if (command.type === 'MIDI_FILE_LOAD' && command.path) {
                    // console.log('📁 MIDI_FILE_LOAD:', command.path);
                    
                    // Construire le chemin complet
                    const fullPath = path.resolve(MIDI_REPO_PATH, command.path);
                    
                    // Analyser le fichier MIDI
                    const midiInfo = analyzeMidiFile(fullPath);
                    
                    // Charger dans le séquenceur
                    success = midiSequencer.loadFile(fullPath);
                    
                    if (success) {
                        // Mettre à jour le playbackState
                        pureDataProxy.updatePlaybackFile(command.path);
                        
                        // Envoyer le message MIDI_FILE_LOAD à PureData
                        pureDataProxy.sendCommand(command);
                        // console.log('📤 MIDI_FILE_LOAD envoyé à PureData:', command.path);
                        
                        // Pas d'envoi binaire: PureData lit localement; la Console n'envoie que JSON
                        
                        // console.log('✅ Fichier MIDI chargé et métadonnées envoyées');
                        message = 'Fichier chargé';
                    } else {
                        message = 'Erreur chargement fichier';
                    }
                    
                } else if (command.type === 'MIDI_TRANSPORT') {
                    // console.log('🎵 MIDI_TRANSPORT reçu:', command.action, 'de', command.source || 'unknown');
                    
                    switch (command.action) {
                        case 'play':
                            success = midiSequencer.play();
                            message = success ? 'Lecture démarrée' : 'Impossible de démarrer';
                            break;
                        case 'pause':
                            success = midiSequencer.pause();
                            message = 'Pause';
                            break;
                        case 'stop':
                            // console.log('⏹ Appel midiSequencer.stop()...');
                            success = midiSequencer.stop();
                            message = 'Stop';
                            // console.log('⏹ Stop terminé, success:', success);
                            break;
                        default:
                            message = 'Action inconnue: ' + command.action;
                    }
                    
                    // Relayer aussi à PureData en JSON pour synchronisation
                    if (success) {
                        const state = midiSequencer.getState();
                        command.position = Math.floor(state.beat * midiSequencer.ppq);
                        pureDataProxy.sendCommand(command);
                    }
                    
                } else if (command.type === 'GAME_MODE') {
                    // console.log('🎮 GAME_MODE reçu:', command.enabled ? 'ACTIVÉ' : 'DÉSACTIVÉ', 'de', command.source || 'unknown');
                    
                    // Relayer à PureData pour qu'il adapte son comportement
                    pureDataProxy.sendCommand(command);
                    
                    success = true;
                    message = command.enabled ? 'Mode jeu activé' : 'Mode jeu désactivé';
                    
                } else if (command.type === 'MIDI_SEEK' && command.position !== undefined) {
                    // console.log('⏩ MIDI_SEEK:', command.position, 'ms');
                    success = midiSequencer.seek(command.position);
                    
                    // Envoyer aussi à PureData
                    if (success) {
                        pureDataProxy.sendCommand(command);
                        // console.log('📤 Seek envoyé à PureData:', command.position, 'ms');
                    }
                    
                    message = 'Position mise à jour';
                    
                } else if (command.type === 'TEMPO_CHANGE' && command.tempo) {
                    // console.log('🎼 TEMPO_CHANGE:', command.tempo, 'BPM');
                    success = midiSequencer.setTempo(command.tempo);
                    
                    // Envoyer aussi à PureData pour qu'il soit au courant
                    pureDataProxy.sendCommand(command);
                    // console.log('📤 Tempo envoyé à PureData:', command.tempo, 'BPM');
                    
                    message = 'Tempo changé';
                    
                } else if (command.type === 'UI_CONTROLS') {
                    // Commande pour contrôler l'affichage UI d'un pupitre
                    const pupitreId = command.pupitreId;
                    const enabled = command.enabled !== undefined ? command.enabled : true;
                    
                    // Format PARAM_UPDATE - comme les autres paramètres
                    const relayCommand = {
                        type: "PARAM_UPDATE",
                        path: ["uiControls", "enabled"],
                        value: enabled ? 1 : 0,
                        source: "console"
                    };
                    
                    // Log dans un fichier séparé pour éviter le spam
                    const fs = require('fs');
                    const logMsg = `[${new Date().toISOString()}] UI_CONTROLS -> PARAM_UPDATE: ${JSON.stringify(relayCommand)}, pupitreId: ${pupitreId || 'all'}\n`;
                    fs.appendFileSync('/tmp/ui-controls.log', logMsg);
                    
                    // Utiliser sendToPupitre() avec pupitreId comme les autres PARAM_UPDATE
                    if (pupitreId) {
                        const sendResult = pureDataProxy.sendToPupitre(pupitreId, relayCommand);
                        fs.appendFileSync('/tmp/ui-controls.log', `[${new Date().toISOString()}] UI_CONTROLS sendToPupitre result: ${sendResult} pour ${pupitreId}\n`);
                        success = sendResult;
                    } else {
                        // Si pas de pupitreId, envoyer à tous via sendCommand()
                        const sendResult = pureDataProxy.sendCommand(relayCommand);
                        fs.appendFileSync('/tmp/ui-controls.log', `[${new Date().toISOString()}] UI_CONTROLS sendCommand result: ${sendResult}\n`);
                        success = sendResult;
                    }
                    message = 'Commande UI envoyée';
                } else if (command.type === 'AUTONOMY_MODE') {
                    const pupitreId = command.pupitreId;
                    let sent = false;
                    if (pupitreId) {
                        sent = pureDataProxy.sendToPupitre(pupitreId, command);
                    } else {
                        sent = pureDataProxy.sendCommand(command);
                    }
                    // Toujours retourner success=true pour permettre la mise à jour de l'état local
                    // même si le pupitre n'est pas connecté (la commande sera envoyée quand il se connectera)
                    success = true;
                    message = sent ? 'Commande autonomie envoyée' : 'État mis à jour (pupitre non connecté)';
                } else {
                    // Commande inconnue, envoyer à PureData
                    success = pureDataProxy.sendCommand(command);
                    message = success ? 'Commande envoyée à PureData' : 'PureData non connecté';
                }
                
                response.writeHead(success ? 200 : 400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success, message }));
            } catch (e) {
                console.error('❌ Erreur traitement commande:', e);
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    
    if (request.url === '/api/puredata/status') {
        const status = pureDataProxy.getStatus();
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify(status));
        return;
    }
    
    if (request.url.startsWith('/api/puredata/events')) {
        const url = new URL(request.url, `http://${request.headers.host}`);
        const since = parseInt(url.searchParams.get('since') || '0');
        const events = pureDataProxy.getEvents(since);
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify({ events }));
        return;
    }
    
    if (request.url === '/api/puredata/playback') {
        const playbackState = pureDataProxy.getPlaybackState();
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify(playbackState));
        return;
    }
    
    // Endpoint de test temporaire pour simuler PUPITRE_CONNECTED
    if (request.url === '/api/test/pupitre-connected' && request.method === 'POST') {
        console.log('[TEST] Endpoint /api/test/pupitre-connected appelé');
        let body = '';
        request.on('data', chunk => body += chunk);
        request.on('end', () => {
            try {
                const { pupitreId } = JSON.parse(body);
                console.log(`[TEST] Envoi PUPITRE_CONNECTED pour ${pupitreId}, clients connectés: ${connectedClients.size}`);
                if (pupitreId) {
                    broadcastToClients({
                        type: 'PUPITRE_CONNECTED',
                        pupitreId: pupitreId,
                        pupitreName: `Pupitre ${pupitreId}`,
                        connected: true,
                        timestamp: Date.now()
                    });
                    response.writeHead(200, { 'Content-Type': 'application/json' });
                    response.end(JSON.stringify({ success: true, message: `PUPITRE_CONNECTED envoyé pour ${pupitreId}`, clients: connectedClients.size }));
                } else {
                    response.writeHead(400, { 'Content-Type': 'application/json' });
                    response.end(JSON.stringify({ success: false, error: 'Missing pupitreId' }));
                }
            } catch (e) {
                console.error('[TEST] Erreur:', e.message);
                response.writeHead(400, { 'Content-Type': 'application/json' });
                response.end(JSON.stringify({ success: false, error: e.message }));
            }
        });
        return;
    }
    
    // API pour obtenir le statut des pupitres (pour les LEDs)
    if (request.url === '/api/pupitres/status') {
        const status = pureDataProxy.getStatus();
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(JSON.stringify(status));
        return;
    }
    
    // API pour obtenir le statut d'un pupitre spécifique
    if (request.url.startsWith('/api/pupitres/') && request.url.endsWith('/status')) {
        const pupitreId = request.url.split('/')[3];
        const status = pureDataProxy.getStatus();
        const pupitreStatus = status.connections.find(conn => conn.pupitreId === pupitreId);
        
        if (pupitreStatus) {
            response.writeHead(200, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify(pupitreStatus));
        } else {
            response.writeHead(404, { 'Content-Type': 'application/json' });
            response.end(JSON.stringify({ error: 'Pupitre non trouvé' }));
        }
        return;
    }
    
    // Route principale
    if (request.url === '/' || request.url === '') {
        filePath = './appSirenConsole.html';
    }
    
    // Gestion des répertoires
    try {
        const stats = fs.statSync(filePath);
        if (stats.isDirectory()) {
            const indexPath = path.join(filePath, 'index.html');
            if (fs.existsSync(indexPath)) {
                filePath = indexPath;
            } else {
                response.writeHead(403);
                response.end('Directory listing not allowed');
                return;
            }
        }
    } catch (err) {
        // Le fichier/répertoire n'existe pas, continuer avec le traitement normal
    }

    // Types MIME
    const extname = String(path.extname(filePath)).toLowerCase();
    const mimeTypes = {
        '.html': 'text/html',
        '.js': 'text/javascript',
        '.css': 'text/css',
        '.json': 'application/json',
        '.png': 'image/png',
        '.jpg': 'image/jpg',
        '.wasm': 'application/wasm',
        '.svg': 'image/svg+xml'
    };

    const contentType = mimeTypes[extname] || 'application/octet-stream';

    // Lecture et envoi du fichier
    fs.readFile(filePath, function(error, content) {
        if (error) {
            console.error('❌ Erreur:', error.code, filePath);
            if(error.code == 'ENOENT'){
                response.writeHead(404);
                response.end('File Not Found');
            } else {
                response.writeHead(500);
                response.end('Server Error: ' + error.code);
            }
        } else {
            // console.log('✅ Fichier servi:', filePath);
            response.writeHead(200, { 'Content-Type': contentType });
            response.end(content, 'utf-8');
        }
    });
}

// Créer le serveur HTTP ou HTTPS selon la configuration
let server;
if (USE_HTTPS) {
    // Vérifier que les certificats existent
    if (!fs.existsSync(SSL_KEY_PATH) || !fs.existsSync(SSL_CERT_PATH)) {
        console.error('❌ Certificats SSL introuvables.');
        console.error(`   Clé: ${SSL_KEY_PATH}`);
        console.error(`   Cert: ${SSL_CERT_PATH}`);
        console.error('   Créez-les avec:');
        console.error('   openssl req -x509 -newkey rsa:4096 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes -subj "/CN=localhost"');
        process.exit(1);
    }
    
    try {
        const options = {
            key: fs.readFileSync(SSL_KEY_PATH),
            cert: fs.readFileSync(SSL_CERT_PATH)
        };
        
        server = https.createServer(options, requestHandler);
    } catch (error) {
        console.error('❌ Erreur chargement certificats SSL:', error.message);
        process.exit(1);
    }
} else {
    server = http.createServer(requestHandler);
}

// Handler pour configuration complète depuis pupitres
async function handlePupitreConfigFromPupitre(pupitreId, configData, isRequested = false) {
    
    // Seulement si synchronisé
    if (!isSynced(pupitreId)) {
        setSyncEnabled(pupitreId, true);
    }
    
    // Si c'est un PUPITRE_STATUS périodique (heartbeat), ne traiter que si une demande est en cours
    // MAIS pour CONFIG_FULL, toujours traiter car c'est une réponse explicite à REQUEST_CONFIG
    if (!isRequested && !pendingConfigRequests.has(pupitreId) && !configData) {
        return;
    }
    
    // Si c'est une réponse à une demande, retirer de la liste des demandes
    if (pendingConfigRequests.has(pupitreId)) {
        const pending = pendingConfigRequests.get(pupitreId);
        if (pending && pending.timeout) {
            clearTimeout(pending.timeout);
        }
        pendingConfigRequests.delete(pupitreId);
    }
    
    try {
        const data = await presetAPI.readPresets();
        let preset = ensureCurrentPreset(data);
        if (!preset) return;
        
        if (!preset.config) preset.config = { pupitres: [] };
        if (!preset.config.pupitres) preset.config.pupitres = [];
        
        let pupitreConfig = preset.config.pupitres.find(p => p.id === pupitreId);
        if (!pupitreConfig) {
            pupitreConfig = { id: pupitreId };
            preset.config.pupitres.push(pupitreConfig);
        }
        
        // Convertir la config du pupitre (format PUPITRE_STATUS ou CONFIG_FROM_PUPITRE) vers format preset
        if (configData.assignedSirenes !== undefined) {
            pupitreConfig.assignedSirenes = Array.isArray(configData.assignedSirenes) ? configData.assignedSirenes : [];
        }

        // NEW: map sirenConfig.currentSirens -> assignedSirenes (normaliser en nombres)
        if (configData.sirenConfig && Array.isArray(configData.sirenConfig.currentSirens)) {
            const mapped = configData.sirenConfig.currentSirens
                .map(v => (typeof v === 'string' ? parseInt(v, 10) : v))
                .filter(v => !isNaN(v));
            pupitreConfig.assignedSirenes = mapped;
        }
        if (configData.vstEnabled !== undefined) pupitreConfig.vstEnabled = !!configData.vstEnabled;
        if (configData.udpEnabled !== undefined) pupitreConfig.udpEnabled = !!configData.udpEnabled;
        if (configData.rtpMidiEnabled !== undefined) pupitreConfig.rtpMidiEnabled = !!configData.rtpMidiEnabled;
        if (configData.controllerMapping !== undefined) pupitreConfig.controllerMapping = configData.controllerMapping;
        if (configData.gameMode !== undefined) pupitreConfig.gameMode = !!configData.gameMode;
        
        // Traiter sirens si présent dans configData (format PureData ou format direct)
        if (configData.sirens && Array.isArray(configData.sirens)) {
            if (!pupitreConfig.sirenes) pupitreConfig.sirenes = {};
            for (let i = 0; i < configData.sirens.length; i++) {
                const sirene = configData.sirens[i];
                const sireneNum = i + 1;
                const key = 'sirene' + sireneNum;
                if (!pupitreConfig.sirenes[key]) pupitreConfig.sirenes[key] = {};
                
                // Format PureData : sirene.ambitus.restricted
                if (sirene.ambitus && sirene.ambitus.restricted !== undefined) {
                    pupitreConfig.sirenes[key].ambitusRestricted = !!sirene.ambitus.restricted;
                }
                // Format alternatif direct
                else if (sirene.ambitusRestricted !== undefined) {
                    pupitreConfig.sirenes[key].ambitusRestricted = !!sirene.ambitusRestricted;
                }
                
                // Format PureData : sirene.frettedMode.enabled
                if (sirene.frettedMode && sirene.frettedMode.enabled !== undefined) {
                    pupitreConfig.sirenes[key].frettedMode = !!sirene.frettedMode.enabled;
                }
                // Format alternatif direct
                else if (sirene.frettedMode !== undefined) {
                    pupitreConfig.sirenes[key].frettedMode = !!sirene.frettedMode;
                }
            }
        }
        
        // Mettre à jour dans data.presets
        const presetIndex = data.presets.findIndex(p => p.id === preset.id);
        if (presetIndex !== -1) {
            data.presets[presetIndex] = preset;
        }
        
        // Sauvegarder
        await presetAPI.writePresets(data);
        
        // Forcer refresh UI via WebSocket
        broadcastToClients({
            type: 'PRESET_UPDATED_FROM_PUPITRE',
            pupitreId: pupitreId,
            configUpdated: true,
            timestamp: Date.now()
        });
    } catch (e) {
        console.error('❌ Erreur traitement config complète pupitre:', e);
    }
}

// Handler pour PARAM_CHANGED depuis pupitres
async function handleParamChangedFromPupitre(pupitreId, paramPath, value) {
    // Seulement si synchronisé
    if (!isSynced(pupitreId)) return;
    
    try {
        const data = await presetAPI.readPresets();
        let preset = ensureCurrentPreset(data);
        if (!preset) return;
        
        // Convertir PARAM_UPDATE en structure preset
        preset = convertParamUpdateToPreset(paramPath, value, pupitreId, preset);
        
        // Mettre à jour dans data.presets
        const presetIndex = data.presets.findIndex(p => p.id === preset.id);
        if (presetIndex !== -1) {
            data.presets[presetIndex] = preset;
        }
        
        // Sauvegarder
        await presetAPI.writePresets(data);
        
        // Forcer refresh UI via WebSocket
        broadcastToClients({
            type: 'PRESET_UPDATED_FROM_PUPITRE',
            pupitreId: pupitreId,
            path: paramPath,
            value: value,
            timestamp: Date.now()
        });
    } catch (e) {
        console.error('❌ Erreur traitement PARAM_CHANGED:', e);
    }
}

// Initialiser l'API des presets et démarrer le serveur
presetAPI.initializePresetAPI().then(() => {
    // Initialiser le proxy PureData avec la configuration SirenConsole et les handlers
    pureDataProxy = new PureDataProxy(sirenConsoleConfig, this, broadcastToClients, handleParamChangedFromPupitre, handlePupitreConfigFromPupitre, broadcastBinaryToUIClients);
    
    // Initialiser le séquenceur MIDI
    midiSequencer = new MidiSequencer(pureDataProxy);
    
    // Créer le serveur WebSocket
    wss = new WebSocket.Server({ 
        server: server,
        path: '/ws',
        perMessageDeflate: false
    });
    
    // Gérer les connexions WebSocket
    wss.on('connection', handleWebSocketConnection);
    
    // Intégrer avec le proxy PureData pour diffuser les événements
    if (pureDataProxy) {
        // Écouter les changements de statut des pupitres
           setInterval(() => {
               const status = pureDataProxy.getStatus();
               // Ajouter les informations de synchronisation à chaque connexion
               if (status.connections) {
                   status.connections = status.connections.map(conn => {
                       const syncInfo = syncState.get(conn.pupitreId);
                       return {
                           ...conn,
                           isSynced: syncInfo?.isSynced || false,
                           lastSync: syncInfo?.lastSync || null
                       };
                   });
               }
               broadcastToClients({
                   type: 'PUPITRE_STATUS_UPDATE',
                   data: status,
                   timestamp: Date.now()
               });
           }, 1000); // Diffuser toutes les secondes
        
        // Le proxy PureData gère les connexions vers les pupitres
        // Désactiver tous les logs du proxy pour éviter le spam
        // pureDataProxy.setLogLevel('ERROR'); // Cette méthode n'existe pas
        
        // Rediriger tous les logs du proxy vers /dev/null
        const originalConsoleLog = console.log;
        const originalConsoleError = console.error;
        
        console.log = (...args) => {
            // Ignorer TOUS les logs du proxy sauf les connexions réussies
            if (args[0] && typeof args[0] === 'string') {
                // Ignorer tous les logs de connexion, erreur, statut, reconnexion
                if (args[0].includes('🔌 Connexion à') ||
                    args[0].includes('❌ Erreur WebSocket') ||
                    args[0].includes('📊 Statut mis à jour') ||
                    args[0].includes('❌ Déconnecté de') ||
                    args[0].includes('🔄 Reconnexion') ||
                    args[0].includes('Statut') ||
                    args[0].includes('Reconnexion') ||
                    args[0].includes('Erreur WebSocket')) {
                    return; // Ignorer ces logs
                }
                // GARDER SEULEMENT le log "Connecté à"
                if (args[0].includes('✅ Connecté à')) {
                    originalConsoleLog.apply(console, args);
                    return;
                }
            }
            originalConsoleLog.apply(console, args);
        };
       
        console.error = (...args) => {
            // Ignorer TOUS les logs d'erreur du proxy
            if (args[0] && typeof args[0] === 'string') {
                if (args[0].includes('🔌 Connexion à') ||
                    args[0].includes('❌ Erreur WebSocket') ||
                    args[0].includes('📊 Statut mis à jour') ||
                    args[0].includes('❌ Déconnecté de') ||
                    args[0].includes('🔄 Reconnexion') ||
                    args[0].includes('Statut') ||
                    args[0].includes('Reconnexion') ||
                    args[0].includes('Erreur WebSocket')) {
                    return; // Ignorer ces logs
                }
                // GARDER SEULEMENT le log "Connecté à"
                if (args[0].includes('✅ Connecté à')) {
                    originalConsoleError.apply(console, args);
                    return;
                }
            }
            originalConsoleError.apply(console, args);
        };
    }
    
    server.listen(PORT, HOST, () => {
        const protocol = USE_HTTPS ? 'https' : 'http';
        const wsProtocol = USE_HTTPS ? 'wss' : 'ws';
        console.log(`🚀 Serveur SirenConsole démarré sur ${protocol}://${HOST}:${PORT}`);
        console.log(`🌐 Application principale sur ${protocol}://localhost:${PORT}/appSirenConsole.html`);
        console.log(`🔌 WebSocket serveur sur ${wsProtocol}://localhost:${PORT}/ws`);
    });
}).catch((error) => {
    console.error('❌ Erreur initialisation:', error);
    process.exit(1);
});