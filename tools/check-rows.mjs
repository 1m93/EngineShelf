// Does a row ever offer a button that cannot work?
//
//     node tools/check-rows.mjs
//
// A version can run two ways and each can be closed for its own reason: the
// catalog has no build for this machine, the vendor has stopped serving the one
// it had, Docker is not installed. The row is what has to add those up, and the
// failure is quiet - a button that looks ordinary, and a job that dies at the
// vendor a second after it is pressed.
//
// That shipped. `dockerOnly` is false wherever Docker is missing, so a row with
// nothing left to download fell through to the plain native "Get". On Windows
// every Edge row is in that state permanently, because Microsoft ships Edge here
// as an installer rather than an archive and the shelf has no Windows route for
// it - thirty-nine rows, each offering a download of nothing.
//
// Asked of the real gui/app.js, against a DOM stub, so what is pinned is what
// the page ships.
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
  getElementById: () => nul, querySelector: () => nul, querySelectorAll: () => [],
  createElement: () => nul, documentElement: { dataset: {} }, addEventListener: () => {},
};
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.innerWidth = 1440;
globalThis.innerHeight = 900;
globalThis.localStorage = { getItem: () => null, setItem: () => {} };
globalThis.location = { search: '', reload: () => {} };
globalThis.matchMedia = () => ({ matches: false });
globalThis.getComputedStyle = () => ({ getPropertyValue: () => '' });
globalThis.fetch = () => new Promise(() => {});
globalThis.setInterval = () => 0;
globalThis.setTimeout = () => 0;
process.on('unhandledRejection', () => {});

const src = readFileSync(APP, 'utf8');
const mod = await import('data:text/javascript,' + encodeURIComponent(
  src +
  '\nexport { decorate, nothingToOffer, nativeRoute };' +
  '\nglobalThis.__setState = (s) => { state = s; };'));
const { decorate, nothingToOffer, nativeRoute } = mod;

const shelf = ({ os = 'darwin', dockerCli = false } = {}) => {
  globalThis.__setState({
    os, arch: 'x86_64', hostPlatforms: [os === 'windows' ? 'Win_x64' : 'Mac_Arm'],
    versions: [], extra: [], jobs: [], logs: [], engines: [],
    docker: { cli: dockerCli, running: dockerCli, supported: true, containers: [],
              byRevision: {}, imageBytes: 0, profileBytes: 0 },
    doctor: { os, arch: 'x86_64', components: [] },
  });
};

// One release, as a manager reports it, with only the parts under test varied.
const release = (over = {}) => decorate({
  engine: 'edge', id: '151', label: '151.0.4129.107', version: '151.0.4129.107',
  date: '2026-07-28', year: 2026, note: '', milestone: null, revision: null,
  selector: 'edge:151.0.4129.107', key: 'edge-151.0.4129.107',
  supported: true, native: true, nativeAvailable: true, installed: false,
  knownBad: false, sizeBytes: 0, profileBytes: 0, platformDir: 'Win_x64',
  docker: { revision: '151.0.4129.107', selector: 'edge:151.0.4129.107',
            state: 'absent', status: '', imageBytes: 0, profileBytes: 0, port: null },
  ...over,
});

// The cascade in idleControls, named. Which button a row would draw.
const primary = (row) =>
  row.dockerOnly ? (row.dockerImage ? 'Launch in Docker' : 'Get in Docker')
  : row.installed ? 'Launch'
  : row.dockerImage ? 'Launch in Docker'
  : 'Get natively';

let bad = 0;
const show = (name, want, got) => {
  const ok = JSON.stringify(want) === JSON.stringify(got);
  if (!ok) bad++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name.padEnd(52)} ${JSON.stringify(got)}`);
};

// A row draws either a button or nothing at all, never both and never neither.
const offer = (row) => (nothingToOffer(row) ? 'nothing, dimmed' : primary(row));

console.log('what a row offers');
shelf({ os: 'darwin' });
show('mac: vendor still serves it, no Docker', 'Get natively', offer(release()));
show('mac: vendor dropped it, no Docker', 'nothing, dimmed',
     offer(release({ nativeAvailable: false })));
show('mac: no build for this machine, no Docker', 'nothing, dimmed',
     offer(release({ supported: false })));
show('mac: dropped but already on disk', 'Launch',
     offer(release({ nativeAvailable: false, installed: true })));

shelf({ os: 'darwin', dockerCli: true });
show('mac: vendor dropped it, Docker there', 'Get in Docker',
     offer(release({ nativeAvailable: false })));
show('mac: dropped, image already built', 'Launch in Docker',
     offer(release({ nativeAvailable: false,
                     docker: { revision: '151', selector: 'edge:151', state: 'absent',
                               status: '', imageBytes: 900e6, profileBytes: 0, port: null } })));

// Edge on Windows is never native: nativeAvailable is false on every row, for
// every version, forever.
shelf({ os: 'windows' });
show('windows: Edge, no Docker', 'nothing, dimmed',
     offer(release({ nativeAvailable: false })));
shelf({ os: 'windows', dockerCli: true });
show('windows: Edge, Docker there', 'Get in Docker',
     offer(release({ nativeAvailable: false })));

// A WebKit revision Playwright published for no Ubuntu release: both managers
// send docker: null for it, which is the same shape as an engine with no
// container at all. r1668 and r1715 are the two, measured. On a mac the native
// archive may still exist and the row is worth drawing; on Windows, where WebKit
// is never native, there is nothing behind either mark.
console.log('');
console.log('a WebKit revision with no Linux build');
const noLinux = { engine: 'webkit', id: '1668', label: '15.4',
                  selector: 'webkit:1668', key: 'webkit-1668', docker: null };
shelf({ os: 'darwin', dockerCli: true });
show('mac: native still there, Docker shut', 'Get natively',
     offer(release(noLinux)));
show('mac: and it is not offered in Docker', false,
     release(noLinux).dockerAvailable);
shelf({ os: 'windows', dockerCli: true });
show('windows: neither route, so no button', 'nothing, dimmed',
     offer(release({ ...noLinux, nativeAvailable: false })));

console.log('');
console.log('why the row says the native route is shut');
shelf({ os: 'windows' });
show('windows: Edge does not blame the feed',
     true,
     /installer rather than an archive/.test(nativeRoute(release({ nativeAvailable: false }))[1]));
shelf({ os: 'darwin' });
show('mac: Edge does blame the feed',
     true,
     /keeps about six months/.test(nativeRoute(release({ nativeAvailable: false }))[1]));
show('mac: WebKit blames Playwright',
     true,
     /Playwright deleted/.test(
       nativeRoute(release({ engine: 'webkit', nativeAvailable: false }))[1]));

console.log(bad ? `\n${bad} FAILURES` : '\nno row offers a button that cannot work');
process.exit(bad ? 1 : 0);
