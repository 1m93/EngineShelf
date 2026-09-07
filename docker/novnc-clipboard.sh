#!/bin/sh
# Wire clipboard.js into the noVNC page, at image build time.
#
# noVNC ships a clipboard side panel and nothing else: the host's Cmd-V or
# Ctrl-V is swallowed by the canvas, so text copied outside the tab could only
# get in by being pasted into that panel by hand. clipboard.js wires the two
# clipboards together; it needs the page's RFB object, which ui.js keeps inside
# an ES module, hence the one-line export onto window.
#
# One copy, four images. It was four copies of the same two sed lines, which is
# three chances for one of them to keep working while the others quietly stop
# patching anything - and a clipboard that does not work is not loud.
#
# Deliberately fails the build if noVNC's layout has moved: a silent no-op here
# ships an image whose paste does nothing, and nobody finds out until they try.
set -e

ui=/usr/share/novnc/app/ui.js
page=/usr/share/novnc/vnc.html

grep -q '^export default UI;' "$ui" || {
  echo "noVNC layout changed: no export in ui.js" >&2
  exit 1
}
grep -q 'src="app/ui.js"' "$page" || {
  echo "noVNC layout changed: no ui.js tag in vnc.html" >&2
  exit 1
}

sed -i 's|^export default UI;|window.UI = UI;   /* EngineShelf: app/clipboard.js needs the live RFB object */\nexport default UI;|' "$ui"
sed -i 's|<script type="module" crossorigin="anonymous" src="app/ui.js"></script>|&\n    <script src="app/clipboard.js" defer></script>|' "$page"

grep -q 'app/clipboard.js' "$page"

# One mtime for the whole tree. The two rewrites above leave ui.js and vnc.html
# carrying today's date while everything they import still carries the Debian
# package's - 2021 - and websockify serves both with no Cache-Control. A browser
# then revalidates the two young files and holds the old ones for years, which is
# how a rebuilt image ends up running a new ui.js against a cached core/. The
# no-store header in novnc-serve.py is the real fix; this makes the tree
# consistent for anything that reaches it another way.
#
# -h so the symlink itself is stamped rather than whatever it points at. Ubuntu
# 20.04's noVNC ships include/web-socket-js-project/swfobject.js as a link to a
# file its package no longer carries, and following that dangling link is a
# non-zero exit - which, with `set -e` at the top, failed the whole build on the
# older base. Stamping links rather than targets is also the more correct thing
# here: every real file under this tree is enumerated by find in its own right.
find /usr/share/novnc -exec touch -h {} +
