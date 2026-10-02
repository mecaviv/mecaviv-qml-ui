const fs = require('fs');
const midiFile = require('midi-file');
const { performance } = require('perf_hooks');

/**
 * Séquenceur MIDI pour Node.js
 * Gère la lecture, le transport, et le broadcast de position
 */
class MidiSequencer {
    constructor(pureDataProxy) {
        this.pureDataProxy = pureDataProxy;
        
        // État du séquenceur
        this.playing = false;
        this.currentBeat = 0;           // Beat actuel (decimal)
        this.currentBar = 1;             // Mesure actuelle
        this.currentBeatInBar = 1;       // Beat dans la mesure
        
        // Fichier MIDI
        this.midiData = null;
        this.ppq = 480;                  // Pulses per quarter note
        this.tempo = 500000;             // Microsecondes par beat (120 BPM par défaut)
        this.timeSignature = { numerator: 4, denominator: 4 };
        this.duration = 0;               // Durée en ms
        this.totalBeats = 0;
        this.currentFile = "";
        
        // Événements MIDI triés par tick
        this.events = [];
        this.eventIndex = 0;
        this.currentTick = 0;
        
        // Timer et timing
        this.timer = null;
        this.timerInterval = 50;         // Broadcast toutes les 50ms
        this.lastTickTime = 0;           // Pour calcul delta temps
        this.startTime = 0;              // Timestamp démarrage
        // Plus d'horloge MIDI ni d'envoi binaire côté pupitres
        
        // Map des changements de signature (pour calcul bar/beat)
        this.signatureChanges = [];      // [{tick, numerator, denominator, barAtThisTick}]
        
        console.log('🎵 MidiSequencer initialisé');
    }

    // Plus d'horloge MIDI ni seek/tick binaire
    
    /**
     * Charger un fichier MIDI
     */
    loadFile(filePath) {
        try {
            console.log('📁 MidiSequencer: Chargement', filePath);
            
            const buffer = fs.readFileSync(filePath);
            this.midiData = midiFile.parseMidi(buffer);
            this.ppq = this.midiData.header.ticksPerBeat || 480;
            this.currentFile = filePath;
            
            // Extraire tous les événements et les trier
            this.extractEvents();
            
            // Construire la map des changements de signature
            this.buildSignatureMap();
            
            // Reset position
            this.stop();
            
            console.log('✅ Fichier MIDI chargé:', this.events.length, 'événements,', this.totalBeats, 'beats');
            console.log('   PPQ:', this.ppq, '- Tempo initial:', Math.floor(60000000 / this.tempo), 'BPM');
            console.log('   Signature:', this.timeSignature.numerator + '/' + this.timeSignature.denominator);
            console.log('   Changements signature:', this.signatureChanges.length);
            
            return true;
        } catch (error) {
            console.error('❌ Erreur chargement MIDI:', error.message);
            return false;
        }
    }
    
    /**
     * Extraire tous les événements MIDI et les trier par tick absolu
     */
    extractEvents() {
        this.events = [];
        let totalTicks = 0;
        
        // Valeurs initiales par défaut
        this.tempo = 500000;
        this.timeSignature = { numerator: 4, denominator: 4 };
        
        this.midiData.tracks.forEach((track, trackIndex) => {
            let tick = 0;
            
            track.forEach(event => {
                tick += event.deltaTime;
                
                // Créer événement absolu
                const absEvent = {
                    tick: tick,
                    type: event.type,
                    data: event,
                    trackIndex: trackIndex
                };
                
                // Meta-events
                if (event.type === 'setTempo') {
                    absEvent.tempo = event.microsecondsPerBeat;
                    this.tempo = event.microsecondsPerBeat; // Initial
                }
                
                if (event.type === 'timeSignature') {
                    absEvent.timeSignature = {
                        numerator: event.numerator,
                        denominator: event.denominator
                    };
                    this.timeSignature = absEvent.timeSignature; // Initial
                }
                
                // Notes MIDI
                if (event.type === 'noteOn' || event.type === 'noteOff') {
                    absEvent.noteNumber = event.noteNumber;
                    absEvent.velocity = event.velocity;
                    absEvent.channel = event.channel;
                }
                
                this.events.push(absEvent);
                totalTicks = Math.max(totalTicks, tick);
            });
        });
        
        // Trier par tick
        this.events.sort((a, b) => a.tick - b.tick);
        
        // Calculer durée et beats
        this.totalBeats = Math.floor(totalTicks / this.ppq);
        const bpm = Math.floor(60000000 / this.tempo);
        this.duration = Math.floor((totalTicks / this.ppq / bpm) * 60000);
        
        console.log('📊 Événements extraits:', this.events.length);
        console.log('   Total ticks:', totalTicks, '- Total beats:', this.totalBeats);
    }
    
    /**
     * Construire la map des changements de signature
     */
    buildSignatureMap() {
        this.signatureChanges = [];
        let currentBar = 1;
        let currentTick = 0;
        let currentSig = { numerator: 4, denominator: 4 };
        
        // Ajouter signature initiale
        this.signatureChanges.push({
            tick: 0,
            numerator: currentSig.numerator,
            denominator: currentSig.denominator,
            barNumber: 1
        });
        
        // Parcourir les événements pour trouver les changements
        this.events.forEach(event => {
            if (event.timeSignature) {
                // Calculer combien de mesures se sont passées depuis le dernier changement
                const ticksSinceLastChange = event.tick - currentTick;
                const beatsPerBar = currentSig.numerator;
                const ticksPerBar = this.ppq * beatsPerBar;
                const barsElapsed = Math.floor(ticksSinceLastChange / ticksPerBar);
                
                currentBar += barsElapsed;
                currentTick = event.tick;
                currentSig = event.timeSignature;
                
                this.signatureChanges.push({
                    tick: event.tick,
                    numerator: currentSig.numerator,
                    denominator: currentSig.denominator,
                    barNumber: currentBar
                });
                
                console.log('📊 Changement signature au tick', event.tick, ':', currentSig.numerator + '/' + currentSig.denominator, '- Mesure', currentBar);
            }
        });
    }
    
    /**
     * Calculer bar et beat à partir du tick actuel
     */
    getBarBeatFromTick(tick) {
        // Trouver la dernière signature applicable
        let sigIndex = 0;
        for (let i = this.signatureChanges.length - 1; i >= 0; i--) {
            if (tick >= this.signatureChanges[i].tick) {
                sigIndex = i;
                break;
            }
        }
        
        const sig = this.signatureChanges[sigIndex];
        const ticksSinceChange = tick - sig.tick;
        const ticksPerBeat = this.ppq;
        const beatsPerBar = sig.numerator;
        const ticksPerBar = ticksPerBeat * beatsPerBar;
        
        const barsElapsed = Math.floor(ticksSinceChange / ticksPerBar);
        const ticksInCurrentBar = ticksSinceChange % ticksPerBar;
        const beatInBar = Math.floor(ticksInCurrentBar / ticksPerBeat) + 1;
        
        return {
            barNumber: sig.barNumber + barsElapsed,
            beatInBar: beatInBar,
            currentSignature: { numerator: sig.numerator, denominator: sig.denominator }
        };
    }
    
    /**
     * Démarrer la lecture
     */
    play() {
        if (this.playing || !this.midiData) {
            console.log('⚠️ Déjà en lecture ou pas de fichier chargé');
            return false;
        }
        
        console.log('▶️ Play - Position beat:', this.currentBeat.toFixed(1), 'tick:', this.currentTick);
        this.playing = true;
        
        // Calculer le temps écoulé depuis le début (même formule que tick())
        const bpm = 60000000 / this.tempo;
        const elapsedMs = (this.currentBeat / bpm) * 60000;
        this.startTime = Date.now() - elapsedMs;
        
        console.log('   Elapsed:', elapsedMs.toFixed(0), 'ms - StartTime:', this.startTime);
        
        // Démarrer le timer
        this.lastTickTime = performance.now();
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
        this.timer = setInterval(() => this.tick(), this.timerInterval);
        
        // Broadcast immédiat (UI) uniquement
        this.broadcastPosition();
        
        return true;
    }
    
    /**
     * Pause (garde la position)
     */
    pause() {
        if (!this.playing) return false;
        
        console.log('⏸ Pause - Position:', this.currentBeat.toFixed(1));
        this.playing = false;
        
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
        
        // Broadcaster position (UI) uniquement
        this.broadcastPosition();
        return true;
    }
    
    /**
     * Stop (retour à 0)
     */
    stop() {
        console.log('⏹ Stop');
        this.playing = false;
        this.currentTick = 0;
        this.currentBeat = 0;
        this.currentBar = 1;
        this.currentBeatInBar = 1;
        this.eventIndex = 0;
        
        if (this.timer) {
            clearInterval(this.timer);
            this.timer = null;
        }
        
        // Broadcaster position (UI) uniquement
        this.broadcastPosition();
        return true;
    }
    
    /**
     * Seek à une position (ms)
     */
    seek(positionMs) {
        console.log('⏩ Seek à', positionMs, 'ms');
        
        // Convertir ms → tick
        const bpm = 60000000 / this.tempo;
        const beatTarget = (positionMs / 60000) * bpm;
        const tickTarget = Math.floor(beatTarget * this.ppq);
        
        this.currentTick = tickTarget;
        this.currentBeat = beatTarget;
        
        // Mettre à jour bar/beat
        const barBeat = this.getBarBeatFromTick(tickTarget);
        this.currentBar = barBeat.barNumber;
        this.currentBeatInBar = barBeat.beatInBar;
        this.timeSignature = barBeat.currentSignature;
        
        // Reset index événements
        this.eventIndex = 0;
        while (this.eventIndex < this.events.length && this.events[this.eventIndex].tick < tickTarget) {
            this.eventIndex++;
        }
        
        if (this.playing) {
            // Recalibrer l'horloge incrémentale
            this.lastTickTime = performance.now();
        }
        
        // Broadcaster position (UI) uniquement
        this.broadcastPosition();
        return true;
    }
    
    /**
     * Changer le tempo
     */
    setTempo(bpm) {
        const safeBpm = Math.max(1, Math.floor(bpm));
        this.tempo = Math.floor(60000000 / safeBpm);
        console.log('🎼 Tempo changé:', bpm, 'BPM');
        
        // Pas d'envoi binaire; le tempo est relayé en JSON par server.js
        
        return true;
    }
    
    /**
     * Tick du séquenceur (appelé toutes les 50ms)
     */
    tick() {
        if (!this.playing || !this.midiData) return;
        
        // Intégration incrémentale basée sur delta temps (horloge monotone)
        const now = performance.now();
        const deltaMs = now - this.lastTickTime;
        this.lastTickTime = now;

        // this.tempo est en microsecondes par noire (uspb)
        if (!Number.isFinite(this.tempo) || this.tempo <= 0) {
            // Tempo invalide, ignorer ce tick
            return;
        }
        const beatIncrement = Math.max(0, deltaMs) / (this.tempo / 1000); // ms / (uspb_ms)
        const tickIncrementFloat = beatIncrement * this.ppq;
        const tickIncrement = tickIncrementFloat >= 1 ? Math.floor(tickIncrementFloat) : 0;

        if (tickIncrement > 0) {
            const targetTick = this.currentTick + tickIncrement;
            // Jouer tous les événements entre currentTick et targetTick
            while (this.eventIndex < this.events.length && this.events[this.eventIndex].tick <= targetTick) {
                const event = this.events[this.eventIndex];
                this.processEvent(event);
                this.eventIndex++;
            }
            this.currentTick = targetTick;
            this.currentBeat = this.currentTick / this.ppq;
        }
        
        // Calculer bar/beat
        const barBeat = this.getBarBeatFromTick(this.currentTick);
        this.currentBar = barBeat.barNumber;
        this.currentBeatInBar = barBeat.beatInBar;
        this.timeSignature = barBeat.currentSignature;
        
        // Broadcaster position pour l'UI uniquement
        this.broadcastPosition();
        
        // Vérifier fin
        if (this.eventIndex >= this.events.length || this.currentBeat >= this.totalBeats) {
            console.log('🏁 Fin du morceau');
            this.stop();
        }
    }
    
    /**
     * Traiter un événement MIDI
     */
    processEvent(event) {
        // Meta-events
        if (event.tempo) {
            const newBpm = Math.floor(60000000 / event.tempo);
            console.log('🎼 Changement tempo au beat', this.currentBeat.toFixed(1), ':', newBpm, 'BPM');
            this.tempo = event.tempo;
            
            // Broadcaster le changement de tempo (0x03)
            const buffer = Buffer.allocUnsafe(3);
            buffer.writeUInt8(0x03, 0);
            buffer.writeUInt16LE(newBpm, 1);
            this.pureDataProxy.broadcastBinaryToClients(buffer);
            
            // Recalibrer la référence de temps pour l'intégration
            this.lastTickTime = performance.now();
        }
        
        if (event.timeSignature) {
            console.log('🎵 Changement signature au beat', this.currentBeat.toFixed(1), ':', 
                       event.timeSignature.numerator + '/' + event.timeSignature.denominator);
            
            // Broadcaster le changement (0x04)
            const buffer = Buffer.allocUnsafe(3);
            buffer.writeUInt8(0x04, 0);
            buffer.writeUInt8(event.timeSignature.numerator, 1);
            buffer.writeUInt8(event.timeSignature.denominator, 2);
            this.pureDataProxy.broadcastBinaryToClients(buffer);
        }
        
        // Pas de notes MIDI d'ici : PureData lit le MIDI localement et envoie les notes aux pupitres
    }
    
    /**
     * Broadcaster la position aux pupitres (format 0x06 - 6 bytes avec ticks)
     */
    broadcastPosition() {
        if (!this.pureDataProxy) return;
        
        // console.log('📍 Broadcast position:', this.playing ? '▶' : '⏸', 'tick:', this.currentTick);
        
        // Mettre à jour l'état interne pour l'UI (garde le format actuel pour l'UI)
        this.pureDataProxy.updatePlaybackFromSequencer({
            playing: this.playing,
            bar: this.currentBar,
            beatInBar: this.currentBeatInBar,
            beat: this.currentBeat,
        });
        
        // Envoyer le message binaire 0x06 aux pupitres natifs (format ticks)
        // Format: [0x06, flags, tick_u32_LE]
        // flags: 0x01 = start/play, 0x00 = stop
        const buffer = Buffer.allocUnsafe(6);
        
        buffer.writeUInt8(0x06, 0);                          // messageType (TICK_POSITION)
        buffer.writeUInt8(this.playing ? 0x01 : 0x00, 1);    // flags (bit0=playing: 1=start, 0=stop)
        buffer.writeUInt32LE(this.currentTick, 2);           // tick position (uint32 LE)
        
        // Broadcaster aux pupitres natifs (Raspberry Pi)
        this.pureDataProxy.broadcastBinaryToClients(buffer);
        
        // Broadcaster aussi aux clients UI (SirenePupitre WebAssembly) - format binaire identique
        // console.log('📡 Tentative broadcast aux clients UI, fonction existe:', !!this.pureDataProxy.broadcastBinaryToUIClients);
        if (this.pureDataProxy.broadcastBinaryToUIClients) {
            // console.log('📡 Appel broadcastBinaryToUIClients...');
            this.pureDataProxy.broadcastBinaryToUIClients(buffer);
        } else {
            // console.log('❌ broadcastBinaryToUIClients non disponible');
        }
    }
    
    /**
     * Broadcaster la position en ticks (0x06 - 6 bytes) pour PureData
     * Format: [0x06, flags(1=play/0=stop), tick_u32_LE]
     */
    broadcastTickPosition(tickOverride) {
        const buffer = Buffer.allocUnsafe(6);
        
        buffer.writeUInt8(0x06, 0);                           // messageType (TICK_POSITION)
        buffer.writeUInt8(this.playing ? 0x01 : 0x00, 1);    // flags (bit0=playing)
        buffer.writeUInt32LE((tickOverride !== undefined ? tickOverride : this.currentTick), 2);           // tick position (uint32, little-endian)
        
        // Envoyer via le proxy (envoie vraiment via WebSocket aux pupitres)
        if (this.pureDataProxy) {
            this.pureDataProxy.broadcastBinaryToClients(buffer);
        }
    }
    
    /**
     * Obtenir l'état actuel
     */
    getState() {
        return {
            playing: this.playing,
            position: Math.floor((this.currentBeat / (60000000 / this.tempo)) * 60000),
            beat: this.currentBeat,
            bar: this.currentBar,
            beatInBar: this.currentBeatInBar,
            tempo: Math.floor(60000000 / this.tempo),
            timeSignature: this.timeSignature,
            duration: this.duration,
            totalBeats: this.totalBeats,
            file: this.currentFile
        };
    }
}

module.exports = MidiSequencer;

