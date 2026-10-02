// Reference results for Shared's differential tests, produced by the JS code itself.
// Run from the repository root:  node Shared.Tests/fixtures/generate.js
// The two preset conversions are taken from SirenConsole/webfiles/server.js as they are
// (they are not exported) and run in a vm sandbox; normalizePreset is the one of
// api-presets.js (inlined here, as on branch fix/sirenconsole-contract).
// Keep this file until server.js is gone.

const fs = require('fs');
const vm = require('vm');
const path = require('path');

const root = path.join(__dirname, '..', '..');
const server = fs.readFileSync(path.join(root, 'SirenConsole/webfiles/server.js'), 'utf8');

function extract(name) {
    const start = server.indexOf(`function ${name}(`);
    if (start < 0) throw new Error(`${name} not found in server.js`);
    let depth = 0, i = server.indexOf('{', start);
    for (; i < server.length; i++) {
        if (server[i] === '{') depth++;
        else if (server[i] === '}' && --depth === 0) break;
    }
    return server.slice(start, i + 1);
}

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(extract('convertPresetToParamUpdates') + '\n' + extract('convertParamUpdateToPreset') +
    '\nthis.toUpdates = convertPresetToParamUpdates; this.fromUpdate = convertParamUpdateToPreset;', sandbox);

function normalizePreset(preset) {
    if (!preset || typeof preset !== 'object') return preset;
    const legacy = preset.pupitres;
    const { pupitres, ...rest } = preset;
    const config = (rest.config && typeof rest.config === 'object') ? { ...rest.config } : {};
    if (!Array.isArray(config.pupitres)) config.pupitres = Array.isArray(legacy) ? legacy : [];
    return { ...rest, config };
}

const presetsOnMain = JSON.parse(fs.readFileSync(path.join(__dirname, 'presets.main.json'), 'utf8'));
const normalized = { presets: presetsOnMain.presets.map(normalizePreset) };
const write = (name, data) => fs.writeFileSync(path.join(__dirname, name), JSON.stringify(data, null, 2) + '\n');
write('presets.normalized.json', normalized);

const clone = x => JSON.parse(JSON.stringify(x));
const ids = ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7', 'P9'];
write('param-updates.json', normalized.presets.flatMap(preset =>
    ids.map(id => ({ preset: preset.id, pupitreId: id, updates: clone(sandbox.toUpdates(clone(preset), id)) }))));

// Changes coming from a pupitre, applied one by one to a copy of the first preset.
const changes = [
    [['sirenConfig', 'assignedSirenes'], [2, 3], 'P1'],
    [['sirenConfig', 'currentSirens'], ['4', 5, 'x'], 'P2'],
    [['sirenConfig', 'sirens', 2, 'ambitus', 'restricted'], 1, 'P1'],
    [['sirenConfig', 'sirens', '0', 'frettedMode', 'enabled'], 0, 'P3'],
    [['outputConfig', 'vstEnabled'], 1, 'P8'],
    [['outputConfig', 'udpEnabled'], 0, 'P1'],
    [['outputConfig', 'rtpMidiEnabled'], true, 'P1'],
    [['gameMode', 'enabled'], 1, 'P4'],
    [['controllerMapping', 'fader', 'cc'], '7', 'P1'],
    [['controllerMapping', 'joystickX', 'curve'], 'linear', 'P5'],
    [['displayConfig', 'ui', 'scale'], 1.2, 'P1'],
    [[], 1, 'P1'],
];
let state = clone(normalized.presets[0]);
const steps = [];
for (const [p, value, id] of changes) {
    state = sandbox.fromUpdate(clone(p), clone(value), id, clone(state));
    steps.push({ path: p, value, pupitreId: id, preset: clone(state) });
}
write('param-to-preset.json', { start: normalized.presets[0], steps });
console.log('fixtures written');
