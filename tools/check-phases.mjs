// Does the manager still understand what the CLI is telling it?
//
// The page reads a job's phase back out of the CLI's own output, so the two are
// coupled by nothing but the wording of a few lines. That coupling broke once
// already: both patterns spelled "Chromium", so a Firefox, Edge or WebKit
// download reported no progress and a browser that was up never registered as
// open - its row sat on "Installing..." for as long as it ran and never offered
// Stop. Nothing failed loudly; the row was just wrong.
//
// So this asserts the round trip for all four engines, against the real
// gui/app.js and against the lines engineshelf.sh actually prints.
//
//     node tools/check-phases.mjs
// Loads gui/app.js for real, against a DOM stub, so the phase patterns under
// test are the ones the page actually ships.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP = join(dirname(dirname(fileURLToPath(import.meta.url))), 'gui', 'app.js');

const nul = new Proxy(function () {}, {
  get: (t, k) => (k === 'dataset' || k === 'style' || k === 'classList' ? nul
        : k === 'content' ? nul : k === 'textContent' ? '' : nul),
  set: () => true,
  apply: () => nul,
});
globalThis.document = {
  getElementById: () => nul,
  querySelector: () => nul,
  querySelectorAll: () => [],
  createElement: () => nul,
  createDocumentFragment: () => nul,
  documentElement: { dataset: {} },
  addEventListener: () => {},
};
// The page answers the macOS window's "is anything running?" question through a
// property on window, so importing it needs one to assign to. Same object, so
// window.x and globalThis.x are the one variable the browser has.
globalThis.window = globalThis;
// A browser has these on window; the page hangs its tooltip teardown off them.
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.innerWidth = 1440;
globalThis.innerHeight = 900;
globalThis.localStorage = { getItem: () => null, setItem: () => {} };
globalThis.location = { search: '', reload: () => {} };
globalThis.matchMedia = () => ({ matches: false });
// The page reads the sticky toolbar's height out of the stylesheet, so that one
// number lives in one place. Nothing here has a stylesheet; the fallback answers.
globalThis.getComputedStyle = () => ({ getPropertyValue: () => '' });
globalThis.fetch = () => new Promise(() => {});
globalThis.setInterval = () => 0;
globalThis.setTimeout = () => 0;
process.on('unhandledRejection', () => {});

const src = readFileSync(APP, 'utf8');
const mod = await import(
  'data:text/javascript,' +
    encodeURIComponent(src + '\nexport { readJob, PHASE_MARKS, logKind };')
);
const { readJob, logKind } = mod;

// Exactly what engineshelf.sh prints with colours off (stdout is not a tty for
// every launch the manager makes). Label is "<engine display> <version>".
const cases = [
  ['Chromium', 'Chromium 120.0.6099.0', 'Mac_Arm'],
  ['Firefox', 'Firefox 115.0', 'mac'],
  ['Edge', 'Edge 151.0.4129.107', 'Mac_Universal'],
  ['WebKit', 'WebKit 26.5', 'mac-26-arm64'],
];

const meter =
  ' 43  232M   43 99.8M    0     0  8400k      0  0:00:28  0:00:12  0:00:16 9000k';

let bad = 0;
const show = (n, want, got) => {
  const ok = JSON.stringify(want) === JSON.stringify(got);
  if (!ok) bad++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${n.padEnd(40)} ${JSON.stringify(got)}`);
};

for (const [engine, label, platform] of cases) {
  const downloading = [
    '',
    `Downloading ${label} (${platform}, one time only)`,
    '-> /Users/you/.engineshelf/builds/x',
    '',
    '  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current',
    meter,
  ].join('\n');
  const info = readJob(downloading);
  show(`${engine}: downloading`, { phase: 'downloading', percent: 43 }, { phase: info.phase, percent: info.percent });
  show(`${engine}: bytes+eta`, '100 MB / 232 MB · 16s left', info.detail);

  const open = [downloading, 'Extracting...', `v ${label} ready.`, '',
                `  > ${label} (${platform})`, '  Profile: /x', ''].join('\n');
  show(`${engine}: open`, 'open', readJob(open).phase);

  show(`${engine}: ready`, 'ready',
       readJob([downloading, 'Extracting...', `v ${label} ready.`].join('\n')).phase);
}

// The same round trip against engineshelf.ps1, which prints its own wording and
// draws its own meter - there is no curl in the picture on Windows. Every line
// below is what that file actually writes: Write-Info prints the message bare,
// Write-Ok prefixes "OK ", and Write-Meter builds the meter out of Format-Bytes
// and Format-Left. Nothing checked this before, and one of the two managers had
// already drifted from the page by a whole feature.
console.log('');
const psMeter = '  100 MB / 232 MB \u00b7 16s left \u00b7 12 MB/s  43%';

for (const [engine, label, platform] of cases) {
  const downloading = [
    '',
    `Downloading ${label} (${platform}, one time only)`,
    '-> C:\\Users\\you\\.engineshelf\\builds\\x',
    '   ~60-300 MB, this can take a few minutes...',
    '',
    psMeter,
  ].join('\n');
  const info = readJob(downloading);
  show(`${engine}: downloading (ps)`, { phase: 'downloading', percent: 43 },
       { phase: info.phase, percent: info.percent });
  // Word for word what the curl meter yields above, which is the point: one row
  // reads the same whichever manager is behind it.
  show(`${engine}: bytes+eta (ps)`, '100 MB / 232 MB · 16s left', info.detail);

  const open = [downloading, 'Extracting...', `OK ${label} ready.`, '',
                `  > ${label} (${platform})`, '  Profile: C:\\x', ''].join('\n');
  show(`${engine}: open (ps)`, 'open', readJob(open).phase);

  show(`${engine}: ready (ps)`, 'ready',
       readJob([downloading, 'Extracting...', `OK ${label} ready.`].join('\n')).phase);
}

// A meter with nothing to estimate from, and one for a server that will not say
// how big the file is. Both are shapes Write-Meter really emits.
console.log('');
const partial = [
  '',
  'Downloading Chromium 120.0.6099.0 (Win_x64, one time only)',
  '',
  '  1 KB / 232 MB  0%',
].join('\n');
show('ps meter with no estimate', { phase: 'downloading', percent: 0, detail: '1 KB / 232 MB' },
     readJob(partial));

const unknownSize = [
  '',
  'Downloading Chromium 120.0.6099.0 (Win_x64, one time only)',
  '',
  '  104 MB fetched \u00b7 13 MB/s',
].join('\n');
show('ps meter with no total', { phase: 'downloading', percent: null, detail: null },
     readJob(unknownSize));

// ---------------------------------------------------------------------------
// The same coupling, one step further: the log panel colours each line by what
// the CLI called it. Same failure mode as the phases above, and the same reason
// to pin both halves - the shell CLI marks a result "v ... ready." and the
// PowerShell one marks it "OK ... ready.", so a rule written against whichever
// machine its author uses leaves the other platform's log all one grey.
console.log('');

const kinds = [
  // Both CLIs' own marks, and lib/preflight.sh's indented ones.
  ['x  Unsupported OS: Windows. On Windows use engineshelf.ps1.', 'bad'],
  ['X  Missing catalog: C:\\EngineShelf\\catalog.tsv', 'bad'],
  ['  x Docker cannot be installed automatically here.', 'bad'],
  ['!  This build is x86_64 and Rosetta does not look installed.', 'warn'],
  ['  ! Docker still is not usable.', 'warn'],
  ['v Chromium 120.0.6099.0 ready.', 'ok'],
  ['OK Chromium 120.0.6099.0 ready.', 'ok'],
  ['v Built. Nothing is running: start 120 opens it.', 'ok'],
  ['OK Built. Nothing is running: start 120 opens it.', 'ok'],
  ['  ok Docker is ready.', 'ok'],
  // lib/preflight.ps1 colours this one green rather than marking it, so on
  // Windows it arrives with nothing in front of it at all. "ready." is what
  // catches it, which is why that phase mark earns its place twice over.
  ['  Docker is ready.', 'ok'],

  // What the page already reads for progress, wearing the colour that goes
  // with it. One table, so these cannot drift apart.
  ['Downloading Chromium 120.0.6099.0 (Mac_Arm, one time only)', 'step'],
  ['Downloading WebKit 26.5 (mac-26-arm64, one time only)', 'step'],
  ['Extracting...', 'step'],
  ['  > Chromium 120.0.6099.0 (Mac_Arm)', 'up'],
  ['  > http://localhost:6080/vnc.html?autoconnect=1&resize=scale', 'up'],
  ['  > Chromium 120.0.6099.0 is already running  http://localhost:6080/', 'up'],

  // Noise: the meters both CLIs draw, and the asides they print dim.
  ['  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current', 'quiet'],
  [meter, 'quiet'],
  [psMeter, 'quiet'],
  ['-> /Users/you/.engineshelf/builds/chromium-1217362', 'quiet'],
  ['  Profile: /Users/you/.engineshelf/profiles/chromium-1217362', 'quiet'],
  ['  Log: /Users/you/.engineshelf/logs/chromium-1217362.log', 'quiet'],

  // The divider both managers write between two runs on one target. server.ps1
  // builds it out of [char]0x2500 because that file stays ASCII; it has to
  // arrive here as the same character server.py writes literally.
  ['\u2500\u2500 Chromium 120.0.6099.0 \u00b7 14:22:07 \u2500\u2500', 'rule'],

  // A container build, which is most of what this panel ever holds.
  ['#12 [4/9] RUN apt-get install -y --no-install-recommends libvpx6', 'step'],
  ['#12 12.34 Setting up libvpx6:amd64 (1.8.2-1build1) ...', 'quiet'],
  ['#12 12.34 E: Unable to locate package libvpx6', 'bad'],
  ['#12 12.34 W: Target Packages is configured multiple times', 'warn'],
  ['ERROR: failed to solve: process "/bin/sh -c apt-get install -y libvpx6" ' +
     'did not complete successfully: exit code: 100', 'bad'],
  ['./engineshelf-docker.sh: line 12: docker: command not found', 'bad'],

  // Nothing to say about these, and saying it in colour would be worse.
  ['', ''],
  ['  Copy and paste work across the tab in both directions.', ''],
];

for (const [line, want] of kinds) {
  const label = line.length > 46 ? `${line.slice(0, 43)}...` : line || '(blank)';
  show(`kind: ${label}`, want, logKind(line));
}

console.log(bad ? `\n${bad} FAILURES`
                : '\nall phases detected for all four engines, on both CLIs, ' +
                  'and every line kind with them');
process.exit(bad ? 1 : 0);
