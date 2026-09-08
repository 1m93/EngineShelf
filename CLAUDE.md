# EngineShelf — rules for changing it

One product, written twice. Every behaviour lives in a pair, and one page is the
client for both halves:

|  | macOS / Linux | Windows |
|---|---|---|
| CLI | `engineshelf.sh` | `engineshelf.ps1` |
| Docker launcher | `engineshelf-docker.sh` | `engineshelf-docker.ps1` |
| Manager (HTTP + state) | `gui/server.py` | `gui/server.ps1` |
| Dependency checks | `lib/preflight.sh` | `lib/preflight.ps1` |
| Engine / platform tables | `lib/engines.sh` | `lib/engines.ps1` |
| The page | `gui/app.js` — one file, served by both managers | |

Nothing enforces that pairing at runtime. Each half passes its own tests on its
own machine while the two disagree, and the disagreement surfaces as a feature
that is silently missing on the platform its author does not use. Both rules
below exist because that already happened.

## 1. Both managers answer the same page

`gui/app.js` cannot tell which manager served it. Whatever it sends or reads must
exist on both sides, in the same change:

- A **route** added to one manager is added to the other.
- Same for a field in the **state document**, a field on a **job**, a field in a
  **log answer**, and any value the page destructures out of a POST answer.
- **Any answer that names a job names the log it writes to.** The page takes
  `stream` out of the answer and polls `/api/log/<key>`; with no key it opens no
  panel and no tab, and the job runs unwatched.
- If the page reads it, both managers send it. If only one *can*, the page has to
  cope with it missing — and that is a decision to write down (rule 3), not a
  default.

> `/api/doctor-install` answered with `stream` on Python and without it on
> PowerShell. Not just dependency installs: **every** job on Windows ran with no
> log panel, because `watch(undefined)` returns at its first line. `Get-State`
> also carried no `logs` at all, so the page read the manager as older than
> itself and said so in place of every log. Fixed in `991365c`.

## 2. Native and Docker offer the same shelf

A version can run two ways, and the row is the same row either way. An action has
to exist along the whole chain — **page → both managers → both launchers**:

- The row's menu must not offer a dead end on either route.
- One log stream per row, shared by both routes (`streamKeyOf(row)`), because a
  native download and a container build are two things happening to one version.
- "running" and "running in Docker" are different states and a row must be able
  to say both; a container's job ends the moment the desktop answers, so job
  status alone never means the container is down.
- An action that only makes sense on one route says so on the row, rather than
  answering 400 when pressed.
- **Both routes closed means no button at all**, not the other route's button.
  `dockerOnly` is false wherever Docker is missing, so "nothing left to download"
  used to fall through to the plain native Get — `nothingToOffer()` in `app.js` is
  where that is decided now, and `tools/check-rows.mjs` pins it.
- **What a vendor publishes is not a rule — ask, and write the answer down.**
  Availability is per version and per platform and it is not monotonic in either.
  A boundary constant is always wrong for some row, and the rows it is wrong for
  are the ones nobody thinks to test. Ask at the point of use where the answer is
  cheap (the launcher is about to download from the same CDN), and record it in
  `catalog.tsv` where the page needs it before the button is pressed —
  `tools/discover.py` is what refreshes it.

> The page offered "Reset the container's profile" → `action: 'clean'`, the
> launcher implemented `clean`, and the allow-list in `gui/server.ps1` did not
> have the verb. A dead button, on Windows only, with nothing to say why.
>
> `WEBKIT_FOCAL_BELOW = 1724` said which Ubuntu image a WebKit container was
> built from. Measured revision by revision, it was wrong for five of fifty-three
> rows: r1908 is focal-only *above* the boundary, r1751/r1944/r1992 jammy-only
> below it, and r1668 and r1715 were published for no Linux release at all — two
> rows offering a build that spent a minute on a base image and then 404ed. The
> mismatched pairs were worse: the archive unpacked, the image built, and
> MiniBrowser died at exec on `libvpx.so.6` ten minutes later.

## 3. A divergence is allowed only when it is written down

Some differences are real. Edge publishes no Windows build, so every Edge row
there is container-only; `rosetta` and `knownBad` are macOS-only mechanisms and
correctly inert elsewhere. Those are fine — **stated** at the place they diverge.

When the difference is a verb, a route, or a field, it also gets an entry in
`ALLOWED` in `tools/check-parity.mjs` with the reason. That checker fails on an
entry nobody needs any more, so the list cannot rot into permission to diverge.

## 4. Windows specifics that have already cost a feature

- **`.ps1` files stay ASCII.** PowerShell 5.1 reads a `.ps1` with no BOM as ANSI,
  so a literal `─` arrives as mojibake. Write it as `[char]0x2500`.
- **Anything the page parses is formatted with `InvariantCulture`.** `-f` uses the
  machine's culture: on a Windows set to Vietnamese, German or French,
  `'{0:0.#} GB' -f 1.25` is `1,3 GB`, which the page's meter pattern does not
  match — no progress bar, on exactly the machines nobody tests on.
- **The manager is one thread serving HTTP.** Python's background threads have no
  counterpart. Anything that waits on a network or walks a directory goes in a
  hidden child process (`Start-Process`, never waited on) or behind a cache with a
  TTL — `Get-DirSize`, `Get-DoctorReport`, `Get-DockerStatus` all have one, and
  `Get-JobState` is the single place that drops them when a job ends.
- **A variable nothing assigned is `$null`, not an error.** `$null -notcontains
  'webkit'` is *true*, so a check written against the wrong list refuses
  everything; `$null['webkit']` throws, but only when that line is finally
  reached. The names differ across the split — the shell has `$ENGINES`, the
  PowerShell library has `$EngineList` behind `Test-EngineKnown`, the manager has
  its own `$EngineNames` — and reaching for the wrong one costs a feature.
  `tools/check-psvars.ps1` catches it; it found four, in two files.
- **A native command's stderr is an error record, and `2>$null` does not stop
  it.** Windows PowerShell turns every stderr line an `.exe` writes into one, and
  under `$ErrorActionPreference = 'Stop'` — which `gui.ps1`, `gui/server.ps1` and
  both launchers set — that record terminates the script. The redirection on the
  line is applied *after* the record is raised, so it discards nothing:
  `wsl -l -q 2>$null` on a Windows with WSL switched off printed Microsoft's
  "not installed" line and took the manager down from `Set-InheritedContainers`,
  before the first request, on every machine that only ever wanted the native
  launcher. A native call belongs behind a helper that lowers the preference for
  exactly the length of the call — `Invoke-WslHere`, `Invoke-DockerHere` — which
  leaves the record non-terminating and every caller's own `2>$null` or `2>&1`
  working. PowerShell 7 raises the same record for a nonzero exit code instead,
  so the helper is what holds on both. And what the one HTTP thread asks the
  machine at startup goes in a `try`: `server.py` asks it on a daemon thread,
  where a throw costs the answer rather than the manager.
- **A job gets nothing on stdin.** `server.py` hands every child
  `stdin=subprocess.DEVNULL`; `Start-Process` inherits unless told
  `-RedirectStandardInput`, and an inherited stdin that never answers is a job
  that never ends — winget waiting on its source agreements, `sudo` waiting on a
  password inside WSL. The log stops dead after the question and the only way out
  is quitting the manager. Anything a job shells out to gets its prompts accepted
  on the command line as well; a flag is cheaper than a hang.
- **`Write-Host` is how the CLI prints, and it does reach a redirected file** —
  that is how the manager reads job output. Phase detection depends on the exact
  wording (`Downloading <Engine> …`, `Extracting...`, `… ready.`, `  > <Engine> …`);
  `tools/check-phases.mjs` asserts it for both CLIs.

## 5. What a release note says

The GitHub release body **is** the changelog. A workflow copies it into
`docs/release.json` on publish and on edit and the landing page reads that file,
so `release.json` is never written by hand. The draft lives at the root as
`RELEASE-NOTES-<version>.md` and is what gets pasted into the release.

- **Two sections, `## Fixed` and `## Upgrading`.** A section with nothing to say
  is left out, not filled — no "Changed", no "Internal", no thanks.
- **A bullet opens with the symptom, in bold, the way whoever hit it would say
  it.** "The manager would not start on a machine without WSL 2", not "fixed
  `Test-WslReady`". Then a line or two of mechanism, for whoever has to believe
  it.
- **Say which half it happened on, and which was never affected.** Every rule
  above this one exists because one platform's bug was invisible on the other,
  and a note that hides that has the other half upgrading for nothing: "Windows
  only", "the repo checkout was never affected".
- **`## Upgrading` is only what the reader has to do** — rebuild this image,
  press that row — and it ends with the line saying the rest needs nothing and
  that browsers and profiles are untouched. Anyone who *must* take the release
  is told so, and why, in one sentence.
- **A number in a note is measured, not remembered.** "Five of fifty-three
  rows", "all 288 shelf rows", "the run of 2026-08-31" — counted off the
  catalog, the diff or the log at the time of writing, because a number nobody
  checked is the part a reader tests first.

## Before you call a change done

```bash
node tools/check-parity.mjs                        # the two rules above, mechanically
node tools/check-rows.mjs                          # no row offers a button that cannot work
node tools/check-phases.mjs                        # CLI wording ↔ what the page parses
pwsh -NoProfile -File tools/check-windows.ps1      # the Windows half, from any machine
```

The last one runs `tools/check-psvars.ps1` first, then six suites out of
`tools/windows-tests/` that lift the real functions out of `gui/server.ps1`,
`engineshelf.ps1`, `engineshelf-docker.ps1` and `lib/preflight.ps1` by parse tree
and run them against stubs — so what is tested is what ships. On Windows it is
`powershell -File tools\check-windows.ps1`.

The Windows scripts will also run under `pwsh` on macOS, which is worth doing when
a change touches one, but they need the two things a Windows shell always has:

```bash
USERPROFILE=/tmp/es-check ENGINESHELF_HOME=/tmp/es-check \
  pwsh -NoProfile -File engineshelf.ps1 catalog
```

Then run the manager for real:

```bash
ENGINESHELF_HOME=/tmp/es-check python3 gui/server.py --port 8797 --no-open --new
TOKEN=$(curl -s http://127.0.0.1:8797/api/token \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s http://127.0.0.1:8797/api/state -H "X-EngineShelf-Token: $TOKEN" | head -c 300
```

`ENGINESHELF_HOME` matters: a throwaway `--new` manager writes `manager.json` in
the shared home and deletes it on the way out, which leaves a manager you are
actually using undiscoverable by the next launch. The server quits ~12s after the
last request, so nothing needs killing.

Release builds strip comments and blank lines from the `.ps1` files and minify the
page (`tools/obfuscate.sh`). If a change leans on a comment position, a here-string
or a line continuation, check it against a stripped copy before shipping.
