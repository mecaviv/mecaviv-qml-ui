const WebSocket = require('ws');

// Proxy WebSocket vers PureData - Gestion des connexions multiples
class PureDataProxy {
    constructor(config, server = null, broadcastToClients = null, handleParamChanged = null, handlePupitreConfig = null, broadcastBinaryToUIClients = null) {
        this.config = config;
        this.server = server; // Référence au serveur pour diffusion
        this.broadcastToClients = broadcastToClients; // Fonction de diffusion directe (JSON)
        this.broadcastBinaryToUIClients = broadcastBinaryToUIClients; // Fonction de diffusion binaire aux clients UI
        this.handleParamChanged = handleParamChanged; // Callback pour PARAM_CHANGED depuis pupitres
        this.handlePupitreConfig = handlePupitreConfig; // Callback pour configuration complète depuis pupitres
        this.connections = new Map(); // Map des connexions par pupitre
        this.eventBuffer = []; // Buffer global pour événements temps réel
        this.maxBufferSize = 100;
        this.playbackStates = new Map(); // États de lecture par pupitre
        this.reconnectInterval = 1000; // 1 seconde pour une reconnexion rapide
        this.reconnectTimers = new Map(); // Timers de reconnexion par pupitre
        this.sequencerPlayback = null; // État global fourni par le séquenceur Node (pour l'UI)
        this.binaryChunkStates = new Map(); // Accumulation binaire (format SirenePupitre) par pupitre
        this.errorThrottle = new Map(); // Throttling des erreurs par pupitre: { lastError: timestamp, count: number }
        this.messageQueues = new Map(); // File d'attente de messages par pupitre (pour messages critiques)
        
        // console.log('🎛️ PureDataProxy initialisé pour connexions multiples');
        
        // Initialiser les connexions vers tous les pupitres (via PureData qui fait le routage)
        this.initializeConnections();
        
        // Vérifier périodiquement l'état des connexions
        setInterval(() => {
            this.checkConnectionsHealth();
        }, 2000); // Vérifier toutes les 2 secondes
        
        // Afficher l'état initial des connexions après un court délai
        setTimeout(() => {
            this.logConnectionStatus();
        }, 2000);
        
        // Retry périodique pour les messages en file d'attente
        setInterval(() => {
            this.retryQueuedMessages();
        }, 1000); // Essayer toutes les secondes
    }

    // Mettre à jour l'état de lecture depuis le séquenceur (sans envoyer aux pupitres)
    updatePlaybackFromSequencer(playback) {
        // playback: { playing, bar, beatInBar, beat }
        // Mettre à jour un état global séquenceur
        this.sequencerPlayback = {
            type: 'MIDI_PLAYBACK_STATE',
            playing: !!playback.playing,
            bar: playback.bar || 0,
            beatInBar: playback.beatInBar || 0,
            beat: playback.beat || 0,
        };

        // Mettre à jour toutes les entrées playbackStates existantes (pour API / UI)
        for (const [pupitreId, state] of this.playbackStates) {
            state.playing = this.sequencerPlayback.playing;
            state.bar = this.sequencerPlayback.bar;
            state.beatInBar = this.sequencerPlayback.beatInBar;
            state.beat = this.sequencerPlayback.beat;
            // position (ms) dérivée si tempo connu
            const bpm = state.tempo || 120;
            state.position = Math.floor((state.beat / bpm) * 60000);
            this.playbackStates.set(pupitreId, state);
        }
    }
    
    // Convertir config PureData vers format pupitre pour le preset
    convertPureDataConfigToPupitreConfig(pureDataConfig, pupitreId) {
        const config = {
            assignedSirenes: [],
            vstEnabled: false,
            udpEnabled: false,
            rtpMidiEnabled: false,
            controllerMapping: {},
            sirens: []
        };
        
        // Extraire assignedSirenes depuis sirenConfig
        if (pureDataConfig.sirenConfig && pureDataConfig.sirenConfig.assignedSirenes) {
            config.assignedSirenes = Array.isArray(pureDataConfig.sirenConfig.assignedSirenes) 
                ? pureDataConfig.sirenConfig.assignedSirenes 
                : [];
        }
        // NEW: si currentSirens présent, l'utiliser comme source des assignedSirenes
        if (pureDataConfig.sirenConfig && Array.isArray(pureDataConfig.sirenConfig.currentSirens)) {
            config.assignedSirenes = pureDataConfig.sirenConfig.currentSirens
                .map(v => (typeof v === 'string' ? parseInt(v, 10) : v))
                .filter(v => !isNaN(v));
        }
        
        // Extraire sirens
        if (pureDataConfig.sirenConfig && Array.isArray(pureDataConfig.sirenConfig.sirens)) {
            config.sirens = pureDataConfig.sirenConfig.sirens;
        }
        
        // Extraire outputConfig
        if (pureDataConfig.outputConfig) {
            config.vstEnabled = !!pureDataConfig.outputConfig.vstEnabled;
            config.udpEnabled = !!pureDataConfig.outputConfig.udpEnabled;
            config.rtpMidiEnabled = !!pureDataConfig.outputConfig.rtpMidiEnabled;
        }
        
        // Extraire controllerMapping
        if (pureDataConfig.controllerMapping) {
            config.controllerMapping = pureDataConfig.controllerMapping;
        }
        
        return config;
    }
    
    // Envoyer REQUEST_PUPITRE_CONFIG à PureData via sendCommand (routage via pupitre)
    // PureData doit intercepter ce message et répondre avec CONFIG_FULL
    requestPupitreConfig(pupitreId) {
        const result = this.sendCommand({
            type: "REQUEST_CONFIG",
            pupitreId: pupitreId,
            source: "console"
        }, pupitreId);
        return result;
    }
    
    // Initialiser les connexions vers tous les pupitres
    initializeConnections() {
        if (!this.config.pupitres || !Array.isArray(this.config.pupitres)) {
            console.error('❌ Configuration pupitres manquante');
            return;
        }
        
        this.config.pupitres.forEach(pupitre => {
            if (pupitre.enabled) {
                this.connectToPupitre(pupitre);
            }
        });
    }
    
    // Connexion à un pupitre spécifique
    connectToPupitre(pupitre) {
        const pupitreId = pupitre.id;
        const host = pupitre.host;
        const port = pupitre.websocketPort || 10002;
        const url = `ws://${host}:${port}`;
        
        try {
            const options = {
                perMessageDeflate: false,
                handshakeTimeout: 5000,
                protocolVersion: 13
            };
            
            const ws = new WebSocket(url, options);
            
            // Stocker la connexion
            this.connections.set(pupitreId, {
                websocket: ws,
                pupitre: pupitre,
                url: url,
                connected: false,
                lastSeen: null
            });
            
            // Gestionnaires d'événements
            ws.on('open', () => {
                const connection = this.connections.get(pupitreId);
                if (connection) {
                    connection.connected = true;
                    connection.lastSeen = new Date();
                    
                    console.log(`✅ Pupitre ${pupitreId} (${pupitre.name}) connecté sur ${url}`);
                    
                    // Informer l'interface de la connexion
                    if (this.broadcastToClients) {
                        this.broadcastToClients({
                            type: 'PUPITRE_CONNECTED',
                            pupitreId: pupitreId,
                            pupitreName: pupitre.name,
                            connected: true,
                            timestamp: Date.now()
                        });
                    }
                    
                    // Traiter la file d'attente de messages
                    setTimeout(() => {
                        this.flushMessageQueue(pupitreId);
                    }, 50);
                    
                    // Envoyer automatiquement REQUEST_CONFIG après la connexion
                    setTimeout(() => {
                        this.requestPupitreConfig(pupitreId);
                    }, 100);
                }
                
                // Nettoyer le timer de reconnexion
                if (this.reconnectTimers.has(pupitreId)) {
                    clearTimeout(this.reconnectTimers.get(pupitreId));
                    this.reconnectTimers.delete(pupitreId);
                }
            });
            
            ws.on('close', (code, reason) => {
                const connection = this.connections.get(pupitreId);
                if (connection) {
                    connection.connected = false;
                    connection.lastSeen = null;
                    
                    // console.log(`❌ Pupitre ${pupitreId} (${pupitre.name}) déconnecté (code: ${code})`);
                    
                    // Informer l'interface de la déconnexion
                    if (this.broadcastToClients) {
                        this.broadcastToClients({
                            type: 'PUPITRE_DISCONNECTED',
                            pupitreId: pupitreId,
                            pupitreName: pupitre.name,
                            connected: false,
                            timestamp: Date.now()
                        });
                    }
                }
                
                // Reconnexion immédiate pour les déconnexions inattendues
                this.scheduleReconnect(pupitreId);
            });
            
            ws.on('error', (error) => {
                const connection = this.connections.get(pupitreId);
                if (connection) {
                    connection.connected = false;
                    connection.lastSeen = null;
                }
            });
            
            ws.on('message', (data, isBinary) => {
                this.handleMessage(pupitreId, data);
            });
            
        } catch (error) {
            console.error(`❌ Exception connexion ${pupitre.name} (${pupitreId}):`, error);
            this.scheduleReconnect(pupitreId);
        }
    }
    
    // Gérer les messages d'un pupitre spécifique
    handleMessage(pupitreId, message) {
        const connection = this.connections.get(pupitreId);
        if (!connection) return;
        
        // Détecter si binaire (Buffer) ou texte (string)
        if (Buffer.isBuffer(message)) {
            this.handleBinaryMessage(pupitreId, message);
        } else {
            try {
                const data = JSON.parse(message);
                
                // Traiter PARAM_CHANGED depuis pupitres (source: "pupitre")
                if (data.type === 'PARAM_CHANGED' && data.source === 'pupitre' && this.handleParamChanged) {
                    this.handleParamChanged(pupitreId, data.path, data.value);
                }
                
                // Traiter CONFIG_FULL depuis PureData (réponse à REQUEST_PUPITRE_CONFIG)
                if (data.type === 'CONFIG_FULL') {
                    if (data.config && this.handlePupitreConfig) {
                        const configData = this.convertPureDataConfigToPupitreConfig(data.config, data.pupitreId || pupitreId);
                        this.handlePupitreConfig(data.pupitreId || pupitreId, configData, true);
                    }
                }
                
                // Traiter PUPITRE_STATUS qui contient la configuration complète du pupitre
                if (data.type === 'PUPITRE_STATUS' && data.data && this.handlePupitreConfig) {
                    const isRequested = data.isRequested || false;
                    this.handlePupitreConfig(pupitreId, data.data, isRequested);
                }
                
                // Traiter les messages d'état de lecture MIDI
                if (data.type === 'MIDI_PLAYBACK_STATE') {
                    this.playbackStates.set(pupitreId, data);
                }
                
                // Traiter les messages GAME_MODE de PureData et les broadcaster à tous les pupitres
                if (data.type === 'GAME_MODE' && this.broadcastToClients) {
                    this.broadcastToClients({
                        type: 'GAME_MODE',
                        enabled: data.enabled || false,
                        source: 'puredata'
                    });
                }
                
                // Ajouter au buffer global avec info pupitre
                this.eventBuffer.push({
                    timestamp: Date.now(),
                    pupitreId: pupitreId,
                    pupitreName: connection.pupitre.name,
                    data: data
                });
                
                // Limiter la taille du buffer
                if (this.eventBuffer.length > this.maxBufferSize) {
                    this.eventBuffer.shift();
                }
                
            } catch (e) {
                console.error(`❌ Erreur parsing message ${connection.pupitre.name} (${pupitreId}):`, e);
            }
        }
    }
    
    // Décoder messages binaires pour un pupitre spécifique
    handleBinaryMessage(pupitreId, buffer) {
        const connection = this.connections.get(pupitreId);
        if (!connection) return;
        
        // Ignorer les buffers vides ou trop petits (probablement des heartbeats ou messages corrompus)
        if (!buffer || buffer.length === 0) {
            return;
        }
        
        // Ignorer les messages de 2 bytes qui sont juste des zéros (probablement des heartbeats)
        if (buffer.length === 2 && buffer[0] === 0x00 && buffer[1] === 0x00) {
            return;
        }
        
        // Vérifier si c'est un message VOLANT_STATE (7 bytes avec magic "SS")
        if (buffer.length === 7) {
            const magic1 = buffer.readUInt8(0);
            const magic2 = buffer.readUInt8(1);
            
            if (magic1 === 0x53 && magic2 === 0x53) { // Magic "SS"
                const type = buffer.readUInt8(2);
                const note = buffer.readUInt8(3);
                const velocity = buffer.readUInt8(4);
                const pitchbend = buffer.readUInt16BE(5);
                
                // console.log(`🎹 VOLANT_STATE ${connection.pupitre.name}: Type=${type}, Note=${note}, Velocity=${velocity}, Pitchbend=${pitchbend}`);
                
                if (type === 0x01) { // VOLANT_STATE
                    // Convertir note MIDI → fréquence → RPM (S3: transposition +1 octave, 8 sorties)
                    const frequency = this.midiToFrequency(note, pitchbend, 1); // +1 octave pour S3
                    const rpm = this.frequencyToRpm(frequency, 8); // 8 sorties pour S3
                    
                    // console.log(`🎹 Volant ${connection.pupitre.name}: Note=${note}, Velocity=${velocity}, Pitchbend=${pitchbend}, Freq=${frequency.toFixed(2)}Hz, RPM=${rpm.toFixed(1)}`);
                    
                    // Diffuser aux clients UI via le serveur
                    this.broadcastVolantData(pupitreId, note, velocity, pitchbend, frequency, rpm);
                }
                return;
            }
        }
        
        // Support JSON binaire brut (sans octet de type): commence par '{' (0x7B)
        if (buffer[0] === 0x7B) {
            try {
                const jsonStr = buffer.toString('utf8');
                const json = JSON.parse(jsonStr);
                
                const hasWrapper = json && (json.type === 'CONFIG_FULL' || json.config);
                const configPayload = hasWrapper ? (json.config || {}) : json;
                if (this.handlePupitreConfig && configPayload) {
                    const configData = this.convertPureDataConfigToPupitreConfig(configPayload, pupitreId);
                    this.handlePupitreConfig(pupitreId, configData, true);
                    return;
                }
            } catch (e) {
                // Laisser continuer le traitement si ce n'est pas du JSON valide
            }
        }

        // Protocole strict SirenePupitre: header 8 octets (LE) + payload JSON chunk.
        // Les trames connues de taille fixe passent d'abord : sans ça, une POSITION de 10 octets
        // (0x01, flags, mesure, temps...) a un en-tête de morceau plausible et était avalée
        // comme morceau de config (mesuré : mesures 5, 1 et 0 perdues).
        const len = buffer.length;
        const knownFixedFrame =
            (buffer[0] === 0x01 && len === 10) ||
            (buffer[0] === 0x02 && len === 10) ||
            (buffer[0] === 0x03 && len === 3) ||
            (buffer[0] === 0x04 && len === 3) ||
            (buffer[0] === 0x06 && (len === 6 || len === 8));
        if (len >= 8 && !knownFixedFrame) {
            const totalSize = buffer.readUInt32LE(0);
            const position  = buffer.readUInt32LE(4);
            const payload   = buffer.slice(8);
            
            // Ignorer les messages avec totalSize = 0 (probablement des heartbeats ou messages vides)
            if (totalSize === 0) {
                return;
            }
            if (totalSize > 0 && totalSize <= 10 * 1024 * 1024 && position >= 0 && position < totalSize) {
                let state = this.binaryChunkStates.get(pupitreId);
                if (!state || state.expectedSize !== totalSize) {
                    state = { expectedSize: totalSize, receivedBytes: 0, buffer: Buffer.allocUnsafe(totalSize) };
                    this.binaryChunkStates.set(pupitreId, state);
                }
                payload.copy(state.buffer, position);
                state.receivedBytes += payload.length;
                
                if (state.receivedBytes >= state.expectedSize) {
                    try {
                        // Vérifier que le buffer n'est pas juste des zéros avant de le parser
                        let allZeros = true;
                        for (let i = 0; i < Math.min(state.buffer.length, 100); i++) {
                            if (state.buffer[i] !== 0) {
                                allZeros = false;
                                break;
                            }
                        }
                        if (allZeros && state.buffer.length > 0) {
                            return;
                        }
                        
                        const jsonString = state.buffer.toString('utf8');
                        const trimmed = jsonString.trim();
                        if (jsonString.includes('\uFFFD') || !trimmed || trimmed === '""' || trimmed === "''") {
                            throw new Error(`Buffer invalide: ${trimmed.length > 50 ? trimmed.substring(0, 50) + '...' : trimmed}`);
                        }
                        
                        let jsonData;
                        try {
                            jsonData = JSON.parse(jsonString);
                        } catch (parseError) {
                            const now = Date.now();
                            const throttle = this.errorThrottle.get(pupitreId) || { lastError: 0, count: 0 };
                            if (now - throttle.lastError > 10000) {
                                throttle.lastError = now;
                                throttle.count = 0;
                            } else {
                                throttle.count++;
                            }
                            this.errorThrottle.set(pupitreId, throttle);
                            throw parseError;
                        }
                        
                        // Vérifier que le résultat est un objet ou un tableau
                        if (typeof jsonData !== 'object' || jsonData === null) {
                            throw new Error(`JSON valide mais pas un objet/tableau: type=${typeof jsonData}, value=${JSON.stringify(jsonData).substring(0, 100)}`);
                        }
                        
                        const hasWrapper = jsonData && (jsonData.type === 'CONFIG_FULL' || jsonData.config);
                        const configPayload = hasWrapper ? (jsonData.config || {}) : jsonData;
                        if (this.handlePupitreConfig && configPayload) {
                            const configData = this.convertPureDataConfigToPupitreConfig(configPayload, pupitreId);
                            this.handlePupitreConfig(pupitreId, configData, true);
                        }
                    } catch (e) {
                        // Throttling: logger seulement une fois toutes les 10 secondes par pupitre
                        const now = Date.now();
                        const throttle = this.errorThrottle.get(pupitreId) || { lastError: 0, count: 0 };
                        
                        if (now - throttle.lastError > 10000) {
                            console.error(`❌ Erreur parsing CONFIG_FULL (SP) ${connection.pupitre.name} (${pupitreId})${throttle.count > 0 ? ` (${throttle.count} erreurs ignorées)` : ''}:`, e.message);
                            // Logger aussi les détails du buffer pour le débogage
                            if (state && state.buffer) {
                                const preview = state.buffer.toString('utf8').substring(0, 200);
                                console.error(`   Buffer preview (${state.buffer.length} bytes):`, preview);
                            }
                            throttle.lastError = now;
                            throttle.count = 0;
                        } else {
                            throttle.count++;
                        }
                        this.errorThrottle.set(pupitreId, throttle);
                    } finally {
                        this.binaryChunkStates.delete(pupitreId);
                    }
                    return;
                }
                return;
            }
        }

        const messageType = buffer.readUInt8(0);
        
        // Si le message est plus grand que les messages standards, c'est peut-être un CONFIG_FULL
        if (buffer.length > 100 && messageType === 0x02) {
            // Essayer de parser comme JSON si ça commence par '{' après le type
            if (buffer.length > 1 && buffer[1] === 0x7B) {
                try {
                    const jsonStr = buffer.slice(1).toString('utf8');
                    const json = JSON.parse(jsonStr);
                    if (json.type === 'CONFIG_FULL' || json.config) {
                        const configPayload = json.config || json;
                        if (this.handlePupitreConfig && configPayload) {
                            const configData = this.convertPureDataConfigToPupitreConfig(configPayload, pupitreId);
                            this.handlePupitreConfig(pupitreId, configData, true);
                            return;
                        }
                    }
                } catch (e) {
                    console.error(`❌ [BINAIRE TYPE 0x02] Erreur parsing JSON:`, e.message);
                }
            }
        }
        
        // Initialiser playbackState pour ce pupitre si nécessaire
        if (!this.playbackStates.has(pupitreId)) {
            this.playbackStates.set(pupitreId, {
                type: 'MIDI_PLAYBACK_STATE',
                playing: false,
                position: 0,
                beat: 0,
                tempo: 120,
                timeSignature: { numerator: 4, denominator: 4 },
                duration: 0,
                totalBeats: 0,
                file: ""
            });
        }
        
        const playbackState = this.playbackStates.get(pupitreId);
        
        switch (messageType) {
            // case 0x00: // Désactivé: on n'utilise plus le type 0x00 pour CONFIG, on suit le protocole SP
            case 0x01: // POSITION (10 bytes, 50ms)
                if (buffer.length < 10) {
                    console.error(`❌ POSITION trop court ${connection.pupitre.name}:`, buffer.length, 'bytes (attendu 10)');
                    return;
                }
                const flags = buffer.readUInt8(1);
                playbackState.playing = (flags & 0x01) !== 0;
                const barNumber = buffer.readUInt16LE(2);
                const beatInBar = buffer.readUInt16LE(4);
                playbackState.beat = buffer.readFloatLE(6);
                
                // Calculer position en ms (beat * 60000 / tempo)
                const bpm = playbackState.tempo || 120;
                playbackState.position = Math.floor((playbackState.beat / bpm) * 60000);
                
                // Stocker bar/beat pour l'API
                playbackState.bar = barNumber;
                playbackState.beatInBar = beatInBar;
                
                // Log compact (max 1/sec par pupitre)
                const logKey = `pos_${pupitreId}`;
                if (!this[logKey] || Date.now() - this[logKey] > 1000) {
                    // console.log(`🎵 POSITION ${connection.pupitre.name} (10B):`, playbackState.playing ? 'PLAY' : 'STOP', 
                    //            '- Bar:', barNumber, 'Beat:', beatInBar, '/', playbackState.timeSignature?.numerator || 4,
                    //            '- Total:', playbackState.beat.toFixed(1));
                    this[logKey] = Date.now();
                }
                break;
                
            case 0x02: // FILE_INFO (10 bytes, au load) ou CONFIG_FULL (plus grand)
                if (buffer.length < 10) {
                    // Ignorer silencieusement les messages FILE_INFO incomplets (souvent des messages de heartbeat)
                    console.log(`📦 [0x02] Message trop court (${buffer.length} bytes), ignoré`);
                    return;
                }
                
                // Si le message est plus grand que 10 bytes, ce n'est probablement pas un FILE_INFO
                if (buffer.length > 10) {
                    console.log(`📦 [0x02] Message 0x02 de ${buffer.length} bytes (attendu 10 pour FILE_INFO), possible CONFIG_FULL`);
                    console.log(`   - Premiers octets: ${Array.from(buffer.slice(0, Math.min(50, buffer.length))).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' ')}`);
                    // Ne pas traiter comme FILE_INFO, laisser le code précédent gérer
                    return;
                }
                
                // Vérifier que le message n'est pas juste des zéros (message vide)
                let allZeros = true;
                for (let i = 1; i < Math.min(buffer.length, 10); i++) {
                    if (buffer[i] !== 0) {
                        allZeros = false;
                        break;
                    }
                }
                if (allZeros && buffer.length > 1) {
                    // Ignorer les messages vides (souvent des heartbeats)
                    console.log(`📦 [0x02] Message vide (que des zéros), ignoré`);
                    return;
                }
                playbackState.duration = buffer.readUInt32LE(2);
                playbackState.totalBeats = buffer.readUInt32LE(6);
                console.log(`📁 [0x02] FILE_INFO ${connection.pupitre.name} (10B): Durée:`, playbackState.duration, 'ms - Total beats:', playbackState.totalBeats);
                break;
                
            case 0x03: // TEMPO (3 bytes, quand change)
                if (buffer.length < 3) {
                    console.error(`❌ TEMPO trop court ${connection.pupitre.name}:`, buffer.length, 'bytes (attendu 3)');
                    return;
                }
                playbackState.tempo = buffer.readUInt16LE(1);
                // console.log(`🎼 TEMPO ${connection.pupitre.name} (3B):`, playbackState.tempo, 'BPM');
                break;
                
            case 0x04: // TIMESIG (3 bytes, quand change)
                // Attention: certains flux utilisent 0x04 sur 5 octets (note+duration) → ignorer
                if (buffer.length !== 3) {
                    // Ignorer formats inattendus pour éviter de corrompre l'UI
                    return;
                }
                playbackState.timeSignature.numerator = buffer.readUInt8(1);
                playbackState.timeSignature.denominator = buffer.readUInt8(2);
                // console.log(`🎵 TIMESIG ${connection.pupitre.name} (3B):`, 
                //           playbackState.timeSignature.numerator + '/' + 
                //           playbackState.timeSignature.denominator);
                break;
                
            case 0x06: // TICK_POSITION (6 ou 8 bytes) - Position en ticks pour PureData
                if (buffer.length < 6) {
                    console.error(`❌ TICK_POSITION trop court ${connection.pupitre.name}:`, buffer.length, 'bytes (attendu 6/8)');
                    return;
                }
                const tickFlags = buffer.readUInt8(1);
                playbackState.playing = (tickFlags & 0x01) !== 0;
                const tickPosition = buffer.readUInt32LE(2);
                // ppq optionnel (ancien format 8 octets). Ignoré si absent
                const tickPpq = buffer.length >= 8 ? buffer.readUInt16LE(6) : (playbackState.ppq || 480);
                
                // Stocker la position en ticks pour PureData
                playbackState.tick = tickPosition;
                playbackState.ppq = tickPpq;
                
                // Log compact (max 1/sec par pupitre)
                const tickLogKey = `tick_${pupitreId}`;
                if (!this[tickLogKey] || Date.now() - this[tickLogKey] > 1000) {
                    // console.log(`⏱️ TICK_POSITION ${connection.pupitre.name} (8B):`, playbackState.playing ? 'PLAY' : 'STOP', 
                    //            '- Tick:', tickPosition, '- PPQ:', tickPpq);
                    this[tickLogKey] = Date.now();
                }
                break;
                
            default:
                // console.warn(`⚠️ Type message binaire inconnu ${connection.pupitre.name}:`, '0x' + messageType.toString(16).padStart(2, '0'));
        }
        
        // Mettre à jour l'état
        this.playbackStates.set(pupitreId, playbackState);
    }
    
    // Convertir note MIDI → fréquence avec pitchbend et transposition
    midiToFrequency(note, pitchbend, transposition = 0) {
        // Appliquer la transposition (en octaves)
        const transposedNote = note + (transposition * 12);
        
        // Formule MIDI standard : f = 440 * 2^((note - 69) / 12)
        const baseFrequency = 440 * Math.pow(2, (transposedNote - 69) / 12);
        
        // Appliquer le pitchbend (0-16383, centre = 8192)
        const pitchbendFactor = (pitchbend - 8192) / 8192; // -1 à +1
        // Utiliser une échelle ±1 demi-ton pour cohérence UI
        const pitchbendSemitones = pitchbendFactor * 1.0; // ±1.0 demi-ton
        
        return baseFrequency * Math.pow(2, pitchbendSemitones / 12);
    }
    
    // Convertir fréquence → RPM pour chaque sirène
    frequencyToRpm(frequency, outputs) {
        return frequency * 60 / outputs;
    }
    
    // Diffuser les données du volant aux clients UI
    broadcastVolantData(pupitreId, note, velocity, pitchbend, frequency, rpm) {
        // Utiliser la fonction de diffusion directe
        if (this.broadcastToClients) {
            var continuousNote = note + ((pitchbend - 8192) / 8192);

            this.broadcastToClients({
                type: 'VOLANT_DATA',
                pupitreId: pupitreId,
                noteFloat: continuousNote,
                velocity: velocity,
                frequency: Math.round(frequency) | 0,
                rpm: Math.round(rpm) | 0,
                timestamp: Date.now()
            });
            // console.log(`📡 Diffusion terminée`);
        } else {
            // console.log(`❌ Impossible de diffuser: broadcastToClients=${!!this.broadcastToClients}`);
        }
    }
    
    // Envoyer une commande à un pupitre spécifique
    sendCommand(command, pupitreId = null) {
        // Log d'entrée pour REQUEST_CONFIG
        if (command.type === 'REQUEST_CONFIG') {
            console.log(`🔍 [BLOCAGE] sendCommand REQUEST_CONFIG appelé pour pupitreId=${pupitreId}`);
            console.log(`   Total connexions: ${this.connections.size}`);
            if (pupitreId) {
                const testConn = this.connections.get(pupitreId);
                console.log(`   Connexion pour ${pupitreId}: ${testConn ? 'EXISTE' : 'N\'EXISTE PAS'}`);
                if (testConn) {
                    console.log(`     - connected: ${testConn.connected}`);
                    console.log(`     - websocket: ${testConn.websocket ? 'EXISTE' : 'N\'EXISTE PAS'}`);
                    if (testConn.websocket) {
                        console.log(`     - readyState: ${testConn.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
                    }
                }
            }
        }
        
        // Si pupitreId spécifié, envoyer à ce pupitre uniquement
        if (pupitreId) {
            const connection = this.connections.get(pupitreId);
            
            // 🚫 BLOCAGE 1: Connexion n'existe pas
            if (!connection) {
                if (command.type === 'REQUEST_CONFIG') {
                    console.error(`🚫 [BLOCAGE 1] sendCommand REQUEST_CONFIG - Connexion n'existe pas pour ${pupitreId}`);
                    console.error(`   Les pupitres disponibles sont: ${Array.from(this.connections.keys()).join(', ') || 'AUCUN'}`);
                }
                console.error(`❌ Pupitre ${pupitreId} non connecté - connection: ${!!connection}, connected: ${connection?.connected}, websocket: ${!!connection?.websocket}`);
                return false;
            }
            
            // 🚫 BLOCAGE 2: Connexion existe mais n'est pas connectée ou websocket manquant
            if (!connection.connected || !connection.websocket) {
                if (command.type === 'REQUEST_CONFIG') {
                    console.error(`🚫 [BLOCAGE 2] sendCommand REQUEST_CONFIG - Connexion pas prête pour ${pupitreId}`);
                    console.error(`   - connection existe: ${!!connection}`);
                    console.error(`   - connection.connected: ${connection.connected}`);
                    console.error(`   - connection.websocket: ${!!connection.websocket}`);
                    if (connection.websocket) {
                        console.error(`   - websocket.readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
                    }
                }
                console.error(`❌ Pupitre ${pupitreId} non connecté - connection: ${!!connection}, connected: ${connection?.connected}, websocket: ${!!connection?.websocket}`);
                return false;
            }
            
            // Vérifier readyState avant d'appeler sendToPupitre
            if (connection.websocket.readyState !== WebSocket.OPEN) {
                if (command.type === 'REQUEST_CONFIG') {
                    console.error(`🚫 [BLOCAGE 2.5] sendCommand REQUEST_CONFIG - readyState pas OPEN pour ${pupitreId}`);
                    console.error(`   - readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
                    console.error(`   - États possibles: CONNECTING=0, OPEN=1, CLOSING=2, CLOSED=3`);
                }
            }
            
            return this.sendToPupitre(pupitreId, command);
        }
        
        // Sinon, envoyer à tous les pupitres connectés
        let successCount = 0;
        let totalCount = 0;
        
        for (const [id, connection] of this.connections) {
            if (connection.connected && connection.websocket) {
                totalCount++;
                if (this.sendToPupitre(id, command)) {
                    successCount++;
                }
            }
        }
        
        if (command.type === 'PARAM_UPDATE' && command.path && command.path[0] === 'uiControls') {
            fs.appendFileSync('/tmp/ui-controls.log', `[${new Date().toISOString()}] sendCommand UI_CONTROLS - envoyé à ${successCount}/${totalCount} pupitres\n`);
        }
        
        return successCount > 0;
    }
    
    // Envoyer une commande à un pupitre spécifique
    sendToPupitre(pupitreId, command) {
        const connection = this.connections.get(pupitreId);
        
        // 🚫 BLOCAGE 3: Connexion n'existe pas dans sendToPupitre
        if (!connection) {
            if (command.type === 'REQUEST_CONFIG') {
                console.error(`🚫 [BLOCAGE 3] sendToPupitre REQUEST_CONFIG - Connexion n'existe pas pour ${pupitreId}`);
                console.error(`   Les pupitres disponibles sont: ${Array.from(this.connections.keys()).join(', ') || 'AUCUN'}`);
            }
            console.error(`❌ sendToPupitre échoué pour ${pupitreId} - connection: ${!!connection}, connected: ${connection?.connected}, websocket: ${!!connection?.websocket}`);
            return false;
        }
        
        // 🚫 BLOCAGE 4: Connexion existe mais pas connectée ou websocket manquant
        if (!connection.connected || !connection.websocket) {
            if (command.type === 'REQUEST_CONFIG') {
                console.error(`🚫 [BLOCAGE 4] sendToPupitre REQUEST_CONFIG - Connexion pas prête pour ${pupitreId}`);
                console.error(`   - connection existe: ${!!connection}`);
                console.error(`   - connection.connected: ${connection.connected}`);
                console.error(`   - connection.websocket: ${!!connection.websocket}`);
                if (connection.websocket) {
                    console.error(`   - websocket.readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
                }
            }
            console.error(`❌ sendToPupitre échoué pour ${pupitreId} - connection: ${!!connection}, connected: ${connection?.connected}, websocket: ${!!connection?.websocket}`);
            return false;
        }
        
        // 🚫 BLOCAGE 5: readyState pas OPEN
        if (connection.websocket.readyState !== WebSocket.OPEN) {
            if (command.type === 'REQUEST_CONFIG') {
                console.error(`🚫 [BLOCAGE 5] sendToPupitre REQUEST_CONFIG - readyState pas OPEN pour ${pupitreId}`);
                console.error(`   - readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
                console.error(`   - États possibles: CONNECTING=0, OPEN=1, CLOSING=2, CLOSED=3`);
                console.error(`   - connection.connected: ${connection.connected}`);
            }
            console.error(`❌ sendToPupitre échoué pour ${pupitreId} - readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
            return false;
        }
        
        try {
            const message = JSON.stringify(command);
            if (command.type === 'REQUEST_CONFIG') {
                console.log(`✅ [ENVOI] sendToPupitre REQUEST_CONFIG - Tentative d'envoi pour ${pupitreId}`);
                console.log(`   - Message: ${message}`);
                console.log(`   - readyState: ${connection.websocket.readyState} (OPEN=${WebSocket.OPEN})`);
            }
            console.log(`📤 Envoi à ${connection.pupitre.name} (${pupitreId}):`, message);
            
            // Envoyer en mode binaire comme SirenePupitre
            const buffer = Buffer.from(message, 'utf8');
            connection.websocket.send(buffer);
            
            if (command.type === 'REQUEST_CONFIG') {
                console.log(`✅ [SUCCÈS] sendToPupitre REQUEST_CONFIG - Message envoyé avec succès à ${pupitreId}`);
            }
            console.log(`✅ Message envoyé avec succès à ${pupitreId}`);
            return true;
        } catch (error) {
            // 🚫 BLOCAGE 6: Exception lors de l'envoi
            if (command.type === 'REQUEST_CONFIG') {
                console.error(`🚫 [BLOCAGE 6] sendToPupitre REQUEST_CONFIG - Exception lors de l'envoi pour ${pupitreId}`);
                console.error(`   - Erreur: ${error.message}`);
                console.error(`   - Stack: ${error.stack}`);
            }
            console.error(`❌ Erreur envoi ${connection.pupitre.name} (${pupitreId}):`, error);
            return false;
        }
    }
    
    // Mettre un message en file d'attente pour envoi ultérieur
    queueMessage(pupitreId, command) {
        if (!this.messageQueues.has(pupitreId)) {
            this.messageQueues.set(pupitreId, []);
        }
        const queue = this.messageQueues.get(pupitreId);
        
        // Éviter les doublons pour REQUEST_CONFIG
        if (command.type === 'REQUEST_CONFIG') {
            const hasRequestConfig = queue.some(cmd => cmd.type === 'REQUEST_CONFIG');
            if (hasRequestConfig) {
                console.log(`⏭️ REQUEST_CONFIG déjà en file d'attente pour ${pupitreId}`);
                return;
            }
        }
        
        queue.push(command);
        const connection = this.connections.get(pupitreId);
        const status = connection ? 
            `connected=${connection.connected}, readyState=${connection.websocket ? connection.websocket.readyState : 'N/A'}` : 
            'pas de connexion';
        console.log(`📋 Message mis en file d'attente pour ${pupitreId} (${queue.length} messages en attente, ${status})`);
    }
    
    // Traiter la file d'attente de messages pour un pupitre
    flushMessageQueue(pupitreId) {
        const queue = this.messageQueues.get(pupitreId);
        if (!queue || queue.length === 0) {
            console.log(`📋 File d'attente vide pour ${pupitreId}`);
            return;
        }
        
        const connection = this.connections.get(pupitreId);
        const status = connection ? 
            `connected=${connection.connected}, readyState=${connection.websocket ? connection.websocket.readyState : 'N/A'}` : 
            'pas de connexion';
        
        console.log(`📤 Traitement de la file d'attente pour ${pupitreId} (${queue.length} messages, ${status})`);
        
        // Vérifier que la connexion est vraiment prête avant de traiter
        if (!connection || !connection.websocket || connection.websocket.readyState !== WebSocket.OPEN) {
            console.warn(`⚠️ Connexion ${pupitreId} pas prête pour traiter la file d'attente (connection=${!!connection}, websocket=${!!(connection && connection.websocket)}, readyState=${connection && connection.websocket ? connection.websocket.readyState : 'N/A'})`);
            return;
        }
        
        // Envoyer tous les messages en file d'attente
        const messagesToSend = [...queue];
        this.messageQueues.set(pupitreId, []); // Vider la file
        
        messagesToSend.forEach((command, index) => {
            // Utiliser un petit délai entre chaque message pour éviter la surcharge
            setTimeout(() => {
                console.log(`📤 Tentative envoi message ${index + 1}/${messagesToSend.length} depuis file d'attente pour ${pupitreId}`);
                const sent = this.sendToPupitre(pupitreId, command);
                if (!sent && command.type === 'REQUEST_CONFIG') {
                    // Si l'envoi échoue encore, remettre en file d'attente
                    console.warn(`⚠️ Échec envoi depuis file d'attente, remise en file pour ${pupitreId}`);
                    this.queueMessage(pupitreId, command);
                }
            }, index * 20); // 20ms entre chaque message
        });
    }
    
    // Retry périodique pour les messages en file d'attente
    retryQueuedMessages() {
        for (const [pupitreId, queue] of this.messageQueues) {
            if (queue.length === 0) continue;
            
            const connection = this.connections.get(pupitreId);
            if (connection && connection.connected && connection.websocket && 
                connection.websocket.readyState === WebSocket.OPEN) {
                // La connexion est prête, traiter la file
                this.flushMessageQueue(pupitreId);
            }
        }
    }
    
    // Récupérer les événements depuis le buffer
    getEvents(since = 0, pupitreId = null) {
        let events = this.eventBuffer.filter(event => event.timestamp > since);
        
        if (pupitreId) {
            events = events.filter(event => event.pupitreId === pupitreId);
        }
        
        return events;
    }
    
    // Vider le buffer
    clearEvents(pupitreId = null) {
        if (pupitreId) {
            this.eventBuffer = this.eventBuffer.filter(event => event.pupitreId !== pupitreId);
        } else {
            this.eventBuffer = [];
        }
    }
    
    // Obtenir le statut de toutes les connexions
    getStatus() {
        const status = {
            totalConnections: this.connections.size,
            connectedCount: 0,
            connections: []
        };
        
        for (const [pupitreId, connection] of this.connections) {
            const pupitreStatus = {
                pupitreId: pupitreId,
                pupitreName: connection.pupitre.name,
                connected: connection.connected,
                url: connection.url,
                lastSeen: connection.lastSeen
            };
            
            status.connections.push(pupitreStatus);
            
            if (connection.connected) {
                status.connectedCount++;
            }
        }
        
        return status;
    }
    
    // Afficher l'état des connexions dans les logs
    logConnectionStatus() {
        const status = this.getStatus();
        if (status.totalConnections === 0) {
            console.log(`📊 Aucun pupitre configuré`);
            return;
        }
        console.log(`📊 État des connexions: ${status.connectedCount}/${status.totalConnections} pupitres connectés`);
        for (const conn of status.connections) {
            if (conn.connected) {
                console.log(`   ✅ ${conn.pupitreId} (${conn.pupitreName}) - ${conn.url}`);
            } else {
                console.log(`   ❌ ${conn.pupitreId} (${conn.pupitreName}) - ${conn.url} - Non connecté`);
            }
        }
    }
    
    // Obtenir l'état de lecture MIDI pour un pupitre ou global
    getPlaybackState(pupitreId = null) {
        if (pupitreId) {
            return this.playbackStates.get(pupitreId) || {
                playing: false,
                position: 0,
                beat: 0,
                tempo: 120,
                timeSignature: { numerator: 4, denominator: 4 },
                duration: 0,
                totalBeats: 0,
                file: ""
            };
        }
        
        // Retourner l'état global (moyenne de tous les pupitres)
        const states = Array.from(this.playbackStates.values());
        if (states.length === 0) {
            // Si aucun état pupitre, retourner l'état du séquenceur si disponible
            if (this.sequencerPlayback) {
                return {
                    playing: this.sequencerPlayback.playing,
                    position: 0,
                    beat: this.sequencerPlayback.beat,
                    tempo: 120,
                    timeSignature: { numerator: 4, denominator: 4 },
                    duration: 0,
                    totalBeats: 0,
                    file: "",
                    bar: this.sequencerPlayback.bar,
                    beatInBar: this.sequencerPlayback.beatInBar,
                };
            }
            return {
                playing: false,
                position: 0,
                beat: 0,
                tempo: 120,
                timeSignature: { numerator: 4, denominator: 4 },
                duration: 0,
                totalBeats: 0,
                file: ""
            };
        }
        
        // Calculer la moyenne des états
        const avgState = {
            playing: states.some(s => s.playing),
            position: Math.round(states.reduce((sum, s) => sum + s.position, 0) / states.length),
            beat: states.reduce((sum, s) => sum + s.beat, 0) / states.length,
            tempo: Math.round(states.reduce((sum, s) => sum + s.tempo, 0) / states.length),
            timeSignature: states[0].timeSignature, // Prendre le premier
            duration: Math.max(...states.map(s => s.duration)),
            totalBeats: Math.max(...states.map(s => s.totalBeats)),
            file: states[0].file // Prendre le premier
        };
        
        // Si un état séquenceur est disponible, forcer bar/beat globaux cohérents
        if (this.sequencerPlayback) {
            avgState.bar = this.sequencerPlayback.bar;
            avgState.beatInBar = this.sequencerPlayback.beatInBar;
            avgState.beat = this.sequencerPlayback.beat;
        }
        return avgState;
    }
    
    // Mettre à jour le nom du fichier dans playbackState
    updatePlaybackFile(filePath, pupitreId = null) {
        if (pupitreId) {
            const playbackState = this.playbackStates.get(pupitreId);
            if (playbackState) {
                playbackState.file = filePath;
                // console.log(`📁 Fichier MIDI mis à jour ${pupitreId}:`, filePath);
            }
        } else {
            // Mettre à jour tous les pupitres
            for (const [id, playbackState] of this.playbackStates) {
                playbackState.file = filePath;
            }
            // console.log('📁 Fichier MIDI mis à jour pour tous les pupitres:', filePath);
        }
    }
    
    // Broadcaster un buffer binaire directement
    broadcastBinaryToClients(buffer, pupitreId = null) {
        // console.log('📡 broadcastBinaryToClients appelé, buffer[0]=0x' + buffer[0].toString(16).padStart(2, '0'), 'taille:', buffer.length);
        if (pupitreId) {
            // Envoyer à un pupitre spécifique
            const connection = this.connections.get(pupitreId);
            if (connection && connection.connected && connection.websocket) {
                try {
                    connection.websocket.send(buffer);
                    // Traiter localement aussi pour mettre à jour l'état
                    this.handleBinaryMessage(pupitreId, buffer);
                } catch (error) {
                    console.error(`❌ Erreur envoi binaire ${connection.pupitre.name} (${pupitreId}):`, error);
                }
            }
        } else {
            // Broadcaster à tous les pupitres connectés
            const count = this.connections.size;
            // console.log('📡 Broadcast à', count, 'pupitres natifs');
            for (const [id, connection] of this.connections) {
                if (connection.connected && connection.websocket) {
                    try {
                        connection.websocket.send(buffer);
                        // Traiter localement aussi pour mettre à jour l'état
                        this.handleBinaryMessage(id, buffer);
                    } catch (error) {
                        console.error(`❌ Erreur envoi binaire ${connection.pupitre.name} (${id}):`, error);
                    }
                }
            }
        }
    }
    
    // Planifier une reconnexion pour un pupitre
    scheduleReconnect(pupitreId) {
        if (this.reconnectTimers.has(pupitreId)) return;
        
        const connection = this.connections.get(pupitreId);
        if (!connection) return;
        
        // console.log(`🔄 Reconnexion ${connection.pupitre.name} (${pupitreId}) dans`, this.reconnectInterval, 'ms');
        
        const timer = setTimeout(() => {
            this.reconnectTimers.delete(pupitreId);
            this.connectToPupitre(connection.pupitre);
        }, this.reconnectInterval);
        
        this.reconnectTimers.set(pupitreId, timer);
    }
    
    // Fermer toutes les connexions
    close() {
        // console.log('🔌 Fermeture de toutes les connexions');
        
        // Nettoyer les timers
        for (const timer of this.reconnectTimers.values()) {
            clearTimeout(timer);
        }
        this.reconnectTimers.clear();
        
        // Fermer les connexions
        for (const [pupitreId, connection] of this.connections) {
            if (connection.websocket) {
                connection.websocket.close();
            }
        }
        
        this.connections.clear();
    }
    
    // Gérer une connexion entrante d'un pupitre
    handleIncomingConnection(ws, pupitreId, pupitreInfo) {
        // console.log(`🔌 Connexion entrante du pupitre ${pupitreId}`);
        
        // Stocker la connexion
        this.connections.set(pupitreId, {
            websocket: ws,
            pupitre: pupitreInfo,
            url: `ws://incoming:${pupitreId}`,
            connected: true,
            lastSeen: new Date()
        });
        
        // Gestionnaires d'événements
        ws.on('close', () => {
            // console.log(`❌ Pupitre ${pupitreId} déconnecté`);
            const connection = this.connections.get(pupitreId);
            if (connection) {
                connection.connected = false;
                connection.lastSeen = null;
            }
        });
        
        ws.on('error', (error) => {
            console.error(`❌ Erreur WebSocket pupitre ${pupitreId}:`, error);
            const connection = this.connections.get(pupitreId);
            if (connection) {
                connection.connected = false;
                connection.lastSeen = null;
            }
        });
        
        ws.on('message', (data) => {
            this.handleMessage(pupitreId, data);
        });
    }
    
    // Vérifier la santé des connexions
    checkConnectionsHealth() {
        for (const [pupitreId, connection] of this.connections) {
            if (connection.connected && connection.websocket) {
                // Vérifier si la connexion WebSocket est toujours ouverte
                if (connection.websocket.readyState === WebSocket.CLOSED || 
                    connection.websocket.readyState === WebSocket.CLOSING) {
                    // console.log(`❌ Connexion ${pupitreId} fermée détectée`);
                    connection.connected = false;
                    connection.lastSeen = null;
                    
                    // Programmer une reconnexion
                    this.scheduleReconnect(pupitreId);
                } else if (connection.websocket.readyState === WebSocket.OPEN) {
                    // Envoyer un ping pour vérifier que la connexion est vivante
                    try {
                        connection.websocket.ping();
                        // Ping envoyé (log supprimé pour éviter le spam)
                    } catch (error) {
                        // console.log(`❌ Erreur ping ${pupitreId}:`, error.message);
                        connection.connected = false;
                        connection.lastSeen = null;
                        this.scheduleReconnect(pupitreId);
                    }
                } else {
                    // console.log(`⚠️ Connexion ${pupitreId} dans un état inattendu:`, connection.websocket.readyState);
                }
            }
        }
    }
    
    // Obtenir les pupitres connectés
    getConnectedPupitres() {
        const connected = [];
        for (const [pupitreId, connection] of this.connections) {
            if (connection.connected) {
                connected.push({
                    id: pupitreId,
                    name: connection.pupitre.name,
                    host: connection.pupitre.host,
                    lastSeen: connection.lastSeen
                });
            }
        }
        return connected;
    }
}

module.exports = PureDataProxy;
module.exports = PureDataProxy;