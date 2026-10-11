// The conf defaults as the page receives them: the patched chunk is run the way Steam
// serves it, from a home laid out like a real install, and the panel then rendered
// against what that chunk defined.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: effective.js <emit>'); process.exit(2); }

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'np-effective-'));
const np = path.join(home, 'Library', 'Application Support', 'notproton');
const put = (rel, text) => {
  fs.mkdirSync(path.dirname(path.join(np, rel)), { recursive: true });
  fs.writeFileSync(path.join(np, rel), text);
};
put('gamefixes/default.conf',
  '# Global defaults for every game (lowest precedence: per-game confs and Steam launch options win).\n' +
  'MTL_HUD_ENABLED=1\nRETINA=1\n' +
  '# Rosetta hides AVX/AVX2 unless asked; many games quit without it.\n' +
  'ROSETTA_ADVERTISE_AVX=1\n' +
  '# Exposes DLSS through MetalFX (D3DMetal); only takes effect when DLSS is switched on in the game.\n' +
  'D3DM_ENABLE_METALFX=1\n');
put('gamefixes-default/1888930.conf', 'ROSETTA_ADVERTISE_AVX=1\n');
// The first tool is the default one, and its name runs past the 16 characters a value may.
put('tools',
  'notproton-winecx-11.17\twinecx-11.17\trosetta\tWineCX 11.17 (msync, D3DMetal)\n' +
  'notproton-winecx\twinecx-11.15\trosetta\tWineCX 11.15 (msync, D3DMetal)\n' +
  'notproton-winehq\twinehq-11.15\trosetta\tWineHQ 11.15 - Rosetta\n');

// Steam's chunks end in a source map comment with no newline after it.
const chunk = path.join(home, 'chunk.js');
const fixture = path.join(__dirname, '..', 'webpatch-fixtures', 'gates.forcetool.js');
const map = '//# sourceMappingURL=file:///home/buildbot/steamui/sourcemaps/chunk~2dcc5aaf7.js.map';
fs.writeFileSync(chunk, fs.readFileSync(fixture, 'utf8').replace(/\n$/, '') + map);

let failed = 0;
const t0 = runner('chunk');
let fx;
try {
  const out = execFileSync(emit, ['transform', chunk, 'notproton-winecx-11.17'],
                           { encoding: 'utf8', env: Object.assign({}, process.env, { HOME: home }) });
  // Everything from the comment on is code the browser parses at the end of the chunk.
  const tail = out.slice(out.lastIndexOf(map));
  const ctx = vm.createContext({});
  vm.runInContext(tail, ctx);
  fx = ctx.MSCXFx;
} finally {
  fs.rmSync(home, { recursive: true, force: true });
}
t0.ok(fx !== undefined, 'the defaults survive the source map comment the chunk ends in');
t0.ok(!!(fx && fx.e && fx.e['notproton-winecx-11.17'] && fx.e['notproton-winecx-11.17'].WINEMSYNC === '1'),
      'a tool name longer than a value still reaches the engine map');
t0.ok(!!(fx && fx.e && fx.e[''] && fx.e[''].WINEMSYNC === '1'), 'the default tool stands in for an unpinned game');
failed += t0.failed;

const LABELS = ['Metal HUD', 'DLSS', 'Advertise AVX2 to Rosetta', 'MSync', 'High Resolution',
                'Let games read controllers directly'];
globalThis.MSCXFx = fx;
for (const form of Object.keys(FORMS)) {
  const { render: P } = panel(emit, form);
  const t = runner(form);
  const rows = over => walk(P({ details: details('', Object.assign({ unAppID: 1778820 }, over)) }))
    .filter(x => x.type === 'Toggle');
  const checked = over => rows(over).filter(x => x.props.checked).map(x => x.props.label);
  const on = checked({ strCompatToolName: '' });
  t.ok(LABELS.every(l => on.includes(l)),
       `a game on the default tool shows every conf and engine default on (${on.join(',')})`);
  t.ok(checked({ strCompatToolName: 'notproton-winecx-11.17' }).includes('MSync'),
       'the default tool named outright reads MSync as on');
  t.ok(!checked({ strCompatToolName: 'notproton-winehq' }).includes('MSync'),
       'a tool without msync reads MSync as off');
  failed += t.failed;
}
delete globalThis.MSCXFx;

if (failed) { console.error(`effective: ${failed} check(s) failed`); process.exit(1); }
