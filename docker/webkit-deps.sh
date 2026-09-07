#!/bin/sh
# Install everything the unpacked WebKit build needs, and prove it at build time.
#
# There used to be two hand-written package lists here - one for focal, one for
# jammy - and they were wrong in the way hand-written lists are always wrong:
# quietly, and only for the revisions nobody tested. The focal list was measured
# against r1446 and shipped for the whole 20.04 range; from r1630 the bundle
# carries its own libmanette, which links a libevdev that r1446 never needed and
# so the list never named, and every one of those revisions died at exec on
# libevdev.so.2. A missing library is not a build failure - the image builds fine
# and the browser is what refuses to start - so it reached the user as "WebKit
# keeps failing to start (status 127)", ten minutes and a gigabyte after the
# button, pointing at nothing.
#
# Nothing here is hand-written any more. Three layers, cheapest first:
#
#   1. The archive names its own dependencies. Every build Playwright publishes
#      carries minibrowser-gtk/install-dependencies.sh with the exact package
#      list for that revision on that Ubuntu release - measured present on every
#      revision the shelf offers, from r1446 to r2336, 113 to 136 packages. It
#      is written by the people who compiled the thing, which is one more than
#      could be said for the lists it replaces.
#
#   2. A published list can still be short. Nothing on the shelf needs this
#      today - measured, every focal revision that links libmanette names the
#      libevdev under it - but the list is Playwright's to change and a gap in it
#      is invisible until a browser will not start. Whatever is still unresolved
#      after (1) gets looked up: by name first, because Debian names a library
#      package after its soname and that is instant, and only then by index.
#
#   3. Anything still unresolved fails the build, here, naming the library. A
#      container that cannot start its browser is worth less than one that was
#      never built, and the difference is which of us finds out.
set -eu

GTK=/opt/webkit/minibrowser-gtk

# The search path the browser will actually have, taken from the wrapper that
# sets it rather than restated here. It is not the same across the shelf: up to
# about r1596 the bundle is lib/ alone, and from r1630 it also carries sys/lib/
# with fifteen to twenty libraries of its own - libsoup-3.0, libjxl, libbacktrace,
# and from r1630 libmanette. Assuming lib/ alone reported nine of r2336's objects
# as broken when the image was fine, and would have gone on to install packages
# nothing needed; assuming both would be a guess in the other direction the first
# time Playwright changes the layout again.
#
# MYDIR is what the wrapper calls its own directory. Set it, take the one line,
# and the path is by construction the one the browser gets.
MYDIR="$GTK"
eval "$(grep '^export LD_LIBRARY_PATH=' "$GTK/MiniBrowser" || true)"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-$GTK/lib}"
echo "webkit-deps: library path $LD_LIBRARY_PATH"

# Every library the build asks for and cannot find, deduplicated. Read across the
# whole tree rather than off MiniBrowser alone: MiniBrowser is a wrapper around
# bin/MiniBrowser, and the web, network and GPU processes are separate
# executables that a launch only reaches once a page loads - so a gap in one of
# those is a browser that opens and then renders nothing. ldd resolves
# transitively, which is what makes a missing dependency of a bundled library -
# libmanette in sys/lib needing a libevdev that no bundle ever ships - show up
# here rather than at exec.
unresolved() {
    for f in "$GTK"/bin/* "$GTK"/lib/*.so*; do
        [ -f "$f" ] || continue
        ldd "$f" 2>/dev/null | grep 'not found' || true
    done | awk '{print $1}' | sort -u
}

# Debian names a library package after its soname, two ways, and which one is
# anybody's guess: libmanette-0.2.so.0 is libmanette-0.2-0, libevdev.so.2 is
# libevdev2. Both spellings are offered to apt and the one that exists wins.
# This is a shortcut past the index download in step (2), not a substitute for
# it - a name that resolves to nothing simply falls through.
guesses() {
    stem=${1%.so.*}
    version=${1##*.so.}
    [ "$stem" = "$1" ] && return 0        # no .so.N in it; nothing to guess from
    printf '%s\n%s\n' "$stem-$version" "$stem$version"
}

exists() {
    apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'
}

apt-get update

echo "webkit-deps: installing the list the archive ships"
bash "$GTK/install-dependencies.sh" --autoinstall

missing=$(unresolved)
if [ -n "$missing" ]; then
    echo "webkit-deps: still unresolved: $missing"
    wanted=
    unnamed=
    for soname in $missing; do
        found=
        for candidate in $(guesses "$soname"); do
            if exists "$candidate"; then found=$candidate; break; fi
        done
        if [ -n "$found" ]; then
            echo "  $soname -> $found"
            wanted="$wanted $found"
        else
            unnamed="$unnamed $soname"
        fi
    done

    # Only now, and only for what guessing could not name: apt-file downloads
    # the whole file index of every configured component, which is tens of
    # megabytes and minutes of a build. Measured on focal, it is the difference
    # between a second and four and a half minutes - worth paying when it is the
    # only thing standing between a built image and a browser that cannot exec,
    # and worth skipping every other time.
    if [ -n "$unnamed" ]; then
        echo "webkit-deps: asking the file index about:$unnamed"
        apt-get install -y --no-install-recommends apt-file
        apt-file update
        for soname in $unnamed; do
            owner=$(apt-file search -x "/${soname}$" 2>/dev/null | head -1 | cut -d: -f1)
            echo "  $soname -> ${owner:-nothing provides it}"
            [ -n "$owner" ] && wanted="$wanted $owner"
        done
        apt-get purge -y apt-file >/dev/null
        apt-get autoremove -y >/dev/null
    fi

    [ -n "$wanted" ] && apt-get install -y --no-install-recommends $wanted
fi

# The gate. Everything above is an attempt; this is the part that is allowed to
# be believed.
still=$(unresolved)
if [ -n "$still" ]; then
    echo "webkit-deps: no package on Ubuntu $(. /etc/os-release; echo "$VERSION_ID") provides:" >&2
    for soname in $still; do echo "    $soname" >&2; done
    echo "  The browser would build and then fail to start, so the build stops here." >&2
    exit 1
fi

echo "webkit-deps: every library the build asks for resolves"
rm -rf /var/lib/apt/lists/*
