// Do the two managers still answer the same page, and does every action the page
// offers exist on both routes a version can run by?
//
// EngineShelf is one product with four pairs of implementations - a CLI, a Docker
// launcher, a manager and a preflight library, each written twice - and one page
// that talks to whichever manager it was served by. Nothing about that is checked
// by running the tests: each half passes on its own machine while the halves
// disagree, and the disagreement only shows up as a feature that is silently
// missing on the platform the author does not use.
//
// That is not hypothetical. /api/doctor-install answered with the stream key its
// output is filed under on macOS and Linux, and without it on Windows - so the
// page opened no log panel at all there, for every job, not just dependency
// installs. The launcher implemented `docker clean`, the page offered "Reset the
// container's profile", and the Windows manager's allow-list did not have the
// verb - so the button answered 400. Both were invisible to every test that
// existed.
//
//     node tools/check-parity.mjs
//
// Divergences that are meant to be there live in ALLOWED below, each with the
// reason it is allowed. A new one fails this check until it is written down.
//
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const read = (p) => readFileSync(join(ROOT, p), 'utf8');

const PY = read('gui/server.py');
const PS = read('gui/server.ps1');
const APP = read('gui/app.js');
const CLI_SH = read('engineshelf.sh');
const CLI_PS = read('engineshelf.ps1');
const DOCK_SH = read('engineshelf-docker.sh');
const DOCK_PS = read('engineshelf-docker.ps1');
const PRE_SH = read('lib/preflight.sh');
const PRE_PS = read('lib/preflight.ps1');
const ENG_SH = read('lib/engines.sh');
const ENG_PS = read('lib/engines.ps1');

// Deliberate differences, and why. Each entry is checked to still be *needed* -
// an exception nobody uses any more is deleted rather than left to rot.
const ALLOWED = {
  'cli verbs': {
    offers: 'Asks a vendor which versions it still serves. Only Edge has such a ' +
            'feed, and Get-EnginePlatforms gives Edge no Windows build at all, so ' +
            'every Edge row there is container-only already.',
    'name-versions': 'Folded into `refresh-native versions` on Windows, which ' +
                     'also stores the answer - the manager there is one thread ' +
                     'serving HTTP and cannot do the storing itself.',
    'refresh-native': 'Windows only, for that same reason: on macOS and Linux the ' +
                      'manager runs the probes on background threads.',
  },
  'docker verbs': {},
};

let bad = 0;
const fail = (what, detail) => {
  bad++;
  console.log(`FAIL ${what}`);
  for (const line of detail) console.log(`       ${line}`);
};
const pass = (what, note) => console.log(`ok   ${what.padEnd(46)} ${note ?? ''}`);

const sorted = (set) => [...set].sort();
const setsMatch = (what, a, b, aName, bName, allowed = {}) => {
  const onlyA = sorted(a).filter((x) => !b.has(x) && !(x in allowed));
  const onlyB = sorted(b).filter((x) => !a.has(x) && !(x in allowed));
  if (!a.size && !b.size) return fail(what, ['nothing extracted from either side']);
  if (onlyA.length || onlyB.length) {
    return fail(what, [
      ...onlyA.map((x) => `${aName} only: ${x}`),
      ...onlyB.map((x) => `${bName} only: ${x}`),
      'If a difference is deliberate, add it to ALLOWED with the reason.',
    ]);
  }
  const excused = sorted(new Set([...a, ...b])).filter((x) => x in allowed);
  pass(what, `${a.size + excused.length - excused.length || a.size} shared` +
             (excused.length ? `, ${excused.length} excused` : ''));
};

// ---------- reading literals out of source ----------
// Everything at a nesting depth deeper than one is blanked out, so a regex for
// "a key" cannot reach into a nested value and find one.
function flattenTop(text) {
  let depth = 0;
  let out = '';
  for (const ch of text) {
    if (ch === '{' || ch === '[' || ch === '(') {
      depth++;
      out += depth === 1 ? ch : ' ';
      continue;
    }
    if (ch === '}' || ch === ']' || ch === ')') {
      out += depth === 1 ? ch : ' ';
      depth--;
      continue;
    }
    out += depth <= 1 ? ch : ' ';
  }
  return out;
}

// The balanced span that starts at the first `open` at or after `from`.
function span(text, from, open = '{', close = '}') {
  const start = text.indexOf(open, from);
  if (start < 0) return '';
  let depth = 0;
  for (let at = start; at < text.length; at++) {
    if (text[at] === open) depth++;
    else if (text[at] === close) {
      depth--;
      if (!depth) return text.slice(start, at + 1);
    }
  }
  return '';
}

const all = (re, text, group = 1) => new Set([...text.matchAll(re)].map((m) => m[group]));

// Keys of the dict a python function returns, top level only.
function pyReturnKeys(src, fnName) {
  const at = src.indexOf(`def ${fnName}(`);
  if (at < 0) return new Set();
  const body = span(src, src.indexOf('return {', at));
  return all(/"(\w+)"\s*:/g, flattenTop(body));
}

// Keys of the hashtable a PowerShell function returns, top level only. Several
// keys can share a line, separated by semicolons.
//
// From `return @{`, not from the first `@{`: a function that keeps a lookup of
// its own - Get-State has three - would otherwise be read as returning that.
function psReturnKeys(src, fnName) {
  const at = src.indexOf(`function ${fnName}`);
  if (at < 0) return new Set();
  const from = src.indexOf('return @{', at);
  const body = span(src, from >= 0 ? from : src.indexOf('@{', at));
  return all(/(?:^|[;{\n])\s*([A-Za-z_]\w*)\s*=/gm, flattenTop(body));
}

// The verbs a dispatch table answers to, aliases and all. Scoped to the table
// itself - both files switch on strings elsewhere, and an option parser looks
// enough like a command table to be read as one.
//
// Asking for help is not a feature the page uses and the two spell it slightly
// differently, so it is not what this is about.
const HELP_VERBS = new Set(['', '-h', '--help', 'help', '*', '--']);
function dispatchVerbs(text, startsWith, re) {
  const at = text.indexOf(startsWith);
  if (at < 0) return new Set();
  const table = startsWith.startsWith('case')
    ? text.slice(at, text.indexOf('\nesac', at))
    : span(text, at + startsWith.length - 1);
  const found = new Set();
  for (const m of table.matchAll(re)) {
    for (const verb of m[1].split('|')) {
      const name = verb.replace(/'/g, '');
      if (!HELP_VERBS.has(name)) found.add(name);
    }
  }
  return found;
}

// ---------- 1. the routes each manager answers ----------
const tidy = (p) => (p.endsWith('/') ? `${p}*` : p);
const pyRoutes = new Set([
  ...all(/path == "(\/api\/[^"]*)"/g, PY),
  ...[...PY.matchAll(/path\.startswith\("(\/api\/[^"]*)"\)/g)].map((m) => tidy(m[1])),
]);
const psRoutes = new Set([
  ...all(/\$path -eq '(\/api\/[^']*)'/g, PS),
  ...all(/\$path -like '(\/api\/[^']*)'/g, PS),
  ...all(/^\s*'(\/api\/[^']*)'\s*\{/gm, PS),
]);
setsMatch('routes: server.py vs server.ps1', pyRoutes, psRoutes, 'python', 'powershell');

// ---------- 2. every endpoint the page calls exists on both ----------
const pageCalls = new Set([
  ...all(/\bpost\('(\/api\/[^']*)'/g, APP),
  ...all(/\bapi\('(\/api\/[^']*)'/g, APP),
  ...all(/\bfetch\('(\/api\/[^']*)'/g, APP),
  ...[...APP.matchAll(/\bapi\(`(\/api\/[^`$]*)/g)].map((m) => tidy(m[1])),
]);
for (const [name, routes] of [['server.py', pyRoutes], ['server.ps1', psRoutes]]) {
  const missing = sorted(pageCalls).filter((p) => !routes.has(p));
  if (missing.length) fail(`the page's endpoints exist in ${name}`, missing);
  else pass(`the page's endpoints exist in ${name}`, `${pageCalls.size} called`);
}

// ---------- 3. the documents the page reads ----------
setsMatch('state keys: build_state vs Get-State',
          pyReturnKeys(PY, 'build_state'), psReturnKeys(PS, 'Get-State'),
          'python', 'powershell');
setsMatch('job fields: _summary vs Get-JobBrief',
          pyReturnKeys(PY, '_summary'), psReturnKeys(PS, 'Get-JobBrief'),
          'python', 'powershell');
setsMatch('one log: Jobs.log vs Get-StreamLog',
          pyReturnKeys(PY, 'log'), psReturnKeys(PS, 'Get-StreamLog'),
          'python', 'powershell');

// The listing the tab strip is rebuilt from is appended to a list rather than
// returned, so it is read where it is built.
const pyLogsEntry = all(/"(\w+)"\s*:/g,
  flattenTop(span(PY, PY.indexOf('out.append(', PY.indexOf('def logs(')), '{', '}')));
const psLogsEntry = all(/(?:^|[;{\n])\s*([A-Za-z_]\w*)\s*=/gm,
  flattenTop(span(PS, PS.indexOf('[void]$out.Add(', PS.indexOf('function Get-StreamList')))));
setsMatch('log listing: Jobs.logs vs Get-StreamList', pyLogsEntry, psLogsEntry,
          'python', 'powershell');

// ---------- 4. an answer that names a job must name its log ----------
// The page takes the stream key out of the answer to whatever it started and
// polls it. Without one it opens no panel and no tab, and the job runs unwatched.
for (const [name, src, open, jobKey, streamKey] of [
  ['server.py', PY, '_json({', '"job"', '"stream"'],
  ['server.ps1', PS, 'Send-Json $Stream @{', 'job =', 'stream ='],
]) {
  const answers = [];
  let at = 0;
  while ((at = src.indexOf(open, at)) >= 0) {
    answers.push(span(src, at + open.length - 1));
    at += open.length;
  }
  const naked = answers.filter((a) => a.includes(jobKey) && !a.includes(streamKey));
  if (naked.length) {
    fail(`${name}: a job answer carries its stream`,
         naked.map((a) => a.replace(/\s+/g, ' ').slice(0, 90)));
  } else {
    pass(`${name}: a job answer carries its stream`,
         `${answers.filter((a) => a.includes(jobKey)).length} answers`);
  }
}

// ---------- 4b. what a job gets on stdin ----------
// Nothing, on both. A child that asks a question has to be told there is nobody
// there; inherit the manager's stdin instead and the answer never comes, the job
// never ends, and the log stops dead after the question. Python hands every job
// DEVNULL and always did. PowerShell inherits unless told otherwise, so a
// dependency install sat at "installing..." for ever - on Windows only, which is
// why nothing caught it.
//
// Written without the leading dash because the redirection is set by name in the
// hashtable Start-Child splats, not as a flag on a call - which is also why the
// check below can be as strict as it is.
const stdinDenied = [
  ['server.py', /stdin=subprocess\.DEVNULL/.test(PY)],
  ['server.ps1', /RedirectStandardInput/.test(PS)],
];
const leaky = stdinDenied.filter(([, ok]) => !ok).map(([name]) => name);
if (leaky.length) {
  fail('a job is given no stdin', [
    ...leaky.map((n) => `${n} lets its jobs inherit the manager's stdin`),
    'Anything the child asks will hang it: winget agreements, sudo in WSL.',
  ]);
} else pass('a job is given no stdin', 'both managers');

// ---------- 4bb. one place that starts a powershell child ----------
// There were three, with the same command line copied into each: the catalog
// refresh, the native-availability refresh, and every job. Windows Defender read
// that command line - powershell.exe, -ExecutionPolicy Bypass, a window nobody
// can see - through AMSI and refused to load gui/server.ps1 at all on a 1.1.8
// install, before a line of ours had run. Whatever the answer to that turns out
// to be, it has to be the answer in one place: a fourth copy is a fourth thing
// to fix, and the copy that gets missed is the feature that quietly stops
// working on the half nobody here runs. Start-Child is that place.
const spawners = (PS.match(/'powershell\.exe'/g) || []).length;
if (spawners !== 1) {
  fail('one place starts a powershell child', [
    `server.ps1 names powershell.exe ${spawners} times, not once`,
    'Route it through Start-Child, which is where stdin, the window and the',
    'execution policy are decided for every child the manager starts.',
  ]);
} else pass('one place starts a powershell child', 'Start-Child');

// ---------- 4c. arguments with spaces in them ----------
// Python hands subprocess a list, and a list is the argument vector - a path with
// a space in it is one argument, always. Start-Process joins -ArgumentList with
// spaces and quotes nothing, so the same path arrives split, and every job on a
// machine whose download folder holds a second copy - "EngineShelf-1.1.5-Windows
// (1)" - failed on "the file does not have a '.ps1' extension". Quote-Args is the
// answer; this is that nobody adds a call site that forgets it.
const raw = [...PS.matchAll(/-ArgumentList\s+(.{0,20})/g)]
  .map((m) => m[1].trim())
  .filter((tail) => !tail.startsWith('(Quote-Args') && !tail.startsWith('('));
if (raw.length) {
  fail('every Start-Process quotes its arguments', [
    ...raw.map((t) => `-ArgumentList ${t}...`),
    'Wrap it in Quote-Args, from lib/preflight.ps1.',
  ]);
} else pass('every Start-Process quotes its arguments', 'server.ps1');

// ---------- 4d. the WebKit base image ----------
// A WebKit archive only runs on the Ubuntu release it was built for - the focal
// one in a jammy image links fine and then dies on libvpx.so.6 - and which
// releases a revision was published for is not a rule: r1908 is focal-only in
// the middle of the jammy range, r1668 and r1715 exist for neither. This used to
// be a boundary constant in three files, which was wrong for five of the
// fifty-three rows. Both launchers now ask the CDN, in the same order, and the
// order is the only thing left that can disagree.
const basesSh = DOCK_SH.match(/^WEBKIT_BASES="([^"]+)"/m)?.[1]
  ?.trim().split(/\s+/).join(',');
const basesPs = DOCK_PS.match(/^\$WebKitBases = @\(([^)]+)\)/m)?.[1]
  ?.match(/'([^']+)'/g)?.map((s) => s.slice(1, -1)).join(',');
if (!basesSh || !basesPs) {
  fail('both launchers name the WebKit base images', [
    `engineshelf-docker.sh: ${basesSh ?? 'missing'}`,
    `engineshelf-docker.ps1: ${basesPs ?? 'missing'}`,
  ]);
} else if (basesSh !== basesPs) {
  fail('both launchers try the WebKit base images in one order', [
    `shell ${basesSh}, powershell ${basesPs}`,
    'The first that answers is the image that gets built, so the order is the',
    'decision - two orders is two different images for the same revision.',
  ]);
} else pass('both launchers try the WebKit base images in one order', basesSh);

// Neither launcher may go back to deciding this without asking. A boundary is
// cheap to reintroduce and reads as an optimisation; it is the exact bug above.
const guessed = [
  ['engineshelf-docker.sh', /FOCAL_BELOW|\blt\b\s+"?\$?WEBKIT/i.test(DOCK_SH)],
  ['engineshelf-docker.ps1', /FocalBelow/i.test(DOCK_PS)],
].filter(([, hit]) => hit).map(([name]) => name);
if (guessed.length) {
  fail('no launcher guesses the WebKit base from the revision number', [
    ...guessed,
    'Availability is per revision and per release; ask the CDN.',
  ]);
} else pass('no launcher guesses the WebKit base from the revision number', 'both ask');

// And the image reads its own dependencies rather than carrying a list. Two
// hand-written lists lived in the Dockerfile, one per base; the focal one was
// measured against r1446 and shipped for thirteen more revisions, every one of
// which died at exec on a library it did not name. The archive ships the right
// list for its own revision, so the only correct list here is no list.
const DOCKERFILE = read('docker/Dockerfile.webkit');
const runsDeps = /COPY webkit-deps\.sh/.test(DOCKERFILE) &&
                 /RUN sh \/tmp\/webkit-deps\.sh/.test(DOCKERFILE);
// A run of library packages on one line is what a reintroduced list looks like.
const handList = DOCKERFILE.split('\n')
  .find((line) => (line.match(/\blib[a-z0-9.+-]*\d\b/g) ?? []).length >= 4);
if (!runsDeps || handList) {
  fail('the WebKit image reads its dependencies off the archive', [
    runsDeps ? 'webkit-deps.sh runs' : 'docker/Dockerfile.webkit does not run webkit-deps.sh',
    ...(handList ? [`a package list is back: ${handList.trim().slice(0, 60)}...`] : []),
  ]);
} else {
  pass('the WebKit image reads its dependencies off the archive', 'webkit-deps.sh');
}

// The catalog is the page's copy of the same answer, and the field only means
// anything if both managers read it. A WebKit row whose Docker route is open on
// one manager and closed on the other is CLAUDE.md's first rule, exactly.
const basesField = [
  ['gui/server.py', /"bases": parts\[6\]/.test(PY),
   /release\.get\("bases"\) == "-"/.test(PY)],
  ['gui/server.ps1', /\$bases = \$f\[6\]|\$bases = \$f\[6\]|bases = \$bases/.test(PS),
   /\$release\.bases -eq '-'/.test(PS)],
];
const gaps = basesField
  .filter(([, reads, acts]) => !reads || !acts)
  .map(([name, reads]) => `${name}: ${reads ? 'reads it, ignores it' : 'does not read it'}`);
if (gaps.length) {
  fail('both managers close the Docker route on a WebKit row with no Linux build', gaps);
} else {
  pass('both managers close the Docker route on a WebKit row with no Linux build',
       'catalog field 7');
}

// And the field has to be there to be read. Written by tools/discover.py, one
// entry per WebKit row; "-" is the answer that closes the route.
const shelfWebkit = read('catalog.tsv').split('\n')
  .filter((line) => line.startsWith('S\twebkit\t'));
const unfielded = shelfWebkit.filter((line) => line.split('\t').length < 7);
if (!shelfWebkit.length || unfielded.length) {
  fail('every WebKit shelf row says which Ubuntu releases it was built for', [
    `${unfielded.length} of ${shelfWebkit.length} rows carry no seventh field`,
    'Regenerate with: python3 tools/discover.py --write',
  ]);
} else {
  const closed = shelfWebkit.filter((line) => line.split('\t')[6] === '-').length;
  pass('every WebKit shelf row says which Ubuntu releases it was built for',
       `${shelfWebkit.length} rows, ${closed} with no Linux build`);
}

// ---------- 5. native and Docker offer the same shelf ----------
// Chain per verb: the page sends it, both managers allow it, both launchers
// implement it. A break anywhere is a menu entry that answers 400 or a job that
// dies in a log nobody opened.
const pageVerbs = all(/action: '(\w+)'/g, APP);
const pyVerbs = new Set(
  (PY.match(/if action not in \(([^)]*)\)/s)?.[1] ?? '').match(/"(\w+)"/g)?.map((s) => s.slice(1, -1)) ?? []);
const psVerbs = new Set(
  (PS.match(/if \(@\(([^)]*)\) -notcontains \$action\)/s)?.[1] ?? '').match(/'(\w+)'/g)?.map((s) => s.slice(1, -1)) ?? []);
setsMatch('docker verbs: server.py vs server.ps1', pyVerbs, psVerbs, 'python', 'powershell');
for (const [name, verbs] of [['server.py', pyVerbs], ['server.ps1', psVerbs]]) {
  const missing = sorted(pageVerbs).filter((v) => !verbs.has(v));
  if (missing.length) {
    fail(`the page's docker verbs are allowed by ${name}`,
         [...missing.map((v) => `the page sends action '${v}', ${name} refuses it`),
          'This is a menu entry that answers 400.']);
  } else pass(`the page's docker verbs are allowed by ${name}`, `${pageVerbs.size} sent`);
}

// The launchers behind them. Both dispatch tables list aliases; the first name is
// the one the manager passes.
const SH_CASE = /^\s{2}([a-z|'-]+)\)/gm;
const PS_CASE = /^\s+'\^\(?([a-z|'-]*)\)?\$'/gm;
const dockShVerbs = dispatchVerbs(DOCK_SH, 'case "$COMMAND" in', SH_CASE);
const dockPsVerbs = dispatchVerbs(DOCK_PS, 'switch -Regex ($Command) {', PS_CASE);
setsMatch('docker launcher verbs: sh vs ps1', dockShVerbs, dockPsVerbs,
          'shell', 'powershell', ALLOWED['docker verbs']);
for (const [name, verbs] of [['engineshelf-docker.sh', dockShVerbs],
                             ['engineshelf-docker.ps1', dockPsVerbs]]) {
  const missing = sorted(pageVerbs).filter((v) => !verbs.has(v));
  if (missing.length) fail(`the page's docker verbs exist in ${name}`, missing);
  else pass(`the page's docker verbs exist in ${name}`, `${pageVerbs.size} sent`);
}

// ---------- 6. the CLI behind the native route ----------
const cliShVerbs = dispatchVerbs(CLI_SH, 'case "$COMMAND" in', SH_CASE);
const cliPsVerbs = dispatchVerbs(CLI_PS, 'switch -Regex ($Command) {', PS_CASE);
setsMatch('cli verbs: engineshelf.sh vs engineshelf.ps1', cliShVerbs, cliPsVerbs,
          'shell', 'powershell', ALLOWED['cli verbs']);

// ---------- 7. what the doctor checks, and what it reports ----------
const shComponents = new Set(
  (PRE_SH.match(/^PF_COMPONENTS="([^"]*)"/m)?.[1] ?? '').split(/\s+/).filter(Boolean));
const psComponents = new Set(
  ((PRE_PS.match(/^\$PfComponents = @\(([^)]*)\)/m)?.[1] ?? '').match(/'(\w+)'/g) ?? [])
    .map((s) => s.slice(1, -1)));
setsMatch('doctor components: preflight.sh vs preflight.ps1',
          shComponents, psComponents, 'shell', 'powershell');

const shDoctorFields = all(/"(\w+)":"%s"/g,
  PRE_SH.match(/printf '(\{"id".*?)'/s)?.[1] ?? '');
const psDoctorFields = all(/(?:^|[;{\n])\s*([A-Za-z_]\w*)\s*=/gm,
  flattenTop(span(PRE_PS, PRE_PS.indexOf('[ordered]@{', PRE_PS.indexOf('function Get-PfReport')))));
setsMatch('doctor component fields: pf_json vs Get-PfReport',
          shDoctorFields, psDoctorFields, 'shell', 'powershell');

// ---------- 8. the engines, which everything else is keyed by ----------
const engineSets = {
  'lib/engines.sh': new Set((ENG_SH.match(/^ENGINES="([^"]*)"/m)?.[1] ?? '').split(/\s+/).filter(Boolean)),
  'lib/engines.ps1': new Set(((ENG_PS.match(/^\$EngineList = @\(([^)]*)\)/m)?.[1] ?? '').match(/'(\w+)'/g) ?? []).map((s) => s.slice(1, -1))),
  'gui/server.py': new Set(((PY.match(/^ENGINES = \(([^)]*)\)/m)?.[1] ?? '').match(/"(\w+)"/g) ?? []).map((s) => s.slice(1, -1))),
  'gui/server.ps1': new Set(((PS.match(/^\$Engines = @\(([^)]*)\)/m)?.[1] ?? '').match(/'(\w+)'/g) ?? []).map((s) => s.slice(1, -1))),
};
const [firstName, ...restNames] = Object.keys(engineSets);
for (const name of restNames) {
  setsMatch(`engines: ${firstName} vs ${name}`, engineSets[firstName], engineSets[name],
            firstName, name);
}

// ---------- 9. every excuse is still needed ----------
// An exception left behind after the thing it excused was implemented reads as
// permission to diverge again.
const stale = [];
for (const [what, entries] of Object.entries(ALLOWED)) {
  const both = what === 'cli verbs' ? [cliShVerbs, cliPsVerbs] : [dockShVerbs, dockPsVerbs];
  for (const name of Object.keys(entries)) {
    if (both[0].has(name) && both[1].has(name)) stale.push(`${what}: ${name} exists on both sides now`);
    if (!both[0].has(name) && !both[1].has(name)) stale.push(`${what}: ${name} exists on neither side`);
  }
}
if (stale.length) fail('ALLOWED holds no stale excuses', [...stale, 'Delete the entry.']);
else pass('ALLOWED holds no stale excuses',
          `${Object.values(ALLOWED).reduce((n, e) => n + Object.keys(e).length, 0)} live`);

console.log(bad ? `\n${bad} PARITY FAILURE${bad === 1 ? '' : 'S'}`
                : '\nnative and Docker offer the same actions; both managers answer the same page');
process.exit(bad ? 1 : 0);
