#!/usr/bin/env bash
# Build the Linux x86-64 third-party runtime that Source.Python links against
# and ships.
#
# WHY THIS EXISTS
#
# The x86-64 copies of libpython3.13 and Boost.Python that used to be committed
# to the repository were produced on a much newer toolchain than the x86 ones
# beside them, and nothing in the repository recorded how. That made the
# x86-64 package unloadable on any supported distribution older than Ubuntu
# 24.04, for two independent reasons:
#
#   Python3/plat-linux64/libpython3.13.so.1.0   needed GLIBC_2.38
#   thirdparty/boost/lib/linux64/libboost_filesystem.a
#         referenced std::__cxx11::basic_string<...>::_M_replace_cold, a
#         libstdc++ internal no GCC 9 runtime exports
#
# A binary can only require what the toolchain that produced it could see, so
# the fix is to build these where the floor is the one we promise. Run this in
# an ubuntu:20.04 container: that is glibc 2.31, the manylinux_2_31 baseline,
# the oldest LTS still supported, and one below what the engine itself needs
# (Valve's 64-bit libraries top out at GLIBC_2.29). A binary built here also
# runs on every newer distribution, so one artefact covers the whole range.
#
# WHAT IT PRODUCES
#
#   thirdparty/python_linux64/libs/libpython3.13.{a,so.1.0}   build-time link
#   thirdparty/python_linux64/include/                         headers, must match
#   thirdparty/boost/lib/linux64/libboost_python313.a           build-time link
#   thirdparty/boost/lib/linux64/libboost_filesystem.a          build-time link
#   thirdparty/boost/lib/linux64/libboost_system.a              header-only, empty
#   Python3/plat-linux64/{libpython3.13.so.1.0,libsqlite3.so.0,libz.so.1.2.11}
#   Python3/lib-dynload-linux64/*.cpython-313-x86_64-linux-gnu.so
#
# The SONAMEs and the RUNPATH are not free choices; they are what the loader
# and core.so already expect:
#
#   core.so carries RUNPATH $ORIGIN/../Python3/plat-linux64, which is how it
#   finds libpython. The extension modules get the same RUNPATH so they find
#   the sibling libsqlite3.so.0 and libz.so.1.2.11 without relying on SP's
#   loader having preloaded them.
#
#   libz.so.1.2.11 must carry SONAME libz.so.1, which is what the zlib module
#   asks for. Passing -soname is the only way to get that from zlib's own
#   configure, which is why it is spelled out here.
set -euo pipefail

CPYTHON_VERSION="${CPYTHON_VERSION:-3.13.2}"
BOOST_VERSION="${BOOST_VERSION:-1.87.0}"
PYTHON_SERIES=3.13

WORK="${WORK:-/tmp/sp-runtime}"
PREFIX="${PREFIX:-$WORK/prefix}"
OUT="${OUT:-$WORK/out}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn}"

log() { printf '=== %s ===\n' "$*"; }

fetch() {
    local url="$1" out="$2"
    [ -s "$out" ] && return 0
    wget -q -T 30 -t 3 -O "$out.part" "$url"
    mv -f "$out.part" "$out"
}

mkdir -p "$WORK" "$PREFIX" "$OUT"
cd "$WORK"

# ---------------------------------------------------------------------------
log "toolchain"
# ---------------------------------------------------------------------------
gcc --version | head -1
ldd --version | head -1
case "$(getconf GNU_LIBC_VERSION)" in
    *2.3[01]*) : ;;
    *) echo "WARNING: this script is meant to run where getconf GNU_LIBC_VERSION" >&2
       echo "         reports 2.30 or 2.31. On anything newer the artefacts will" >&2
       echo "         carry that newer floor and the whole point is lost." >&2 ;;
esac

# ---------------------------------------------------------------------------
log "zlib 1.2.11"
# ---------------------------------------------------------------------------
# SO version and SONAME both have to be libz.so.1.
fetch "https://zlib.net/fossils/zlib-1.2.11.tar.gz" zlib-1.2.11.tar.gz \
  || fetch "$MIRROR/debian/pool/main/z/zlib/zlib_1.2.11.orig.tar.gz" zlib-1.2.11.tar.gz
rm -rf zlib-1.2.11 && tar xf zlib-1.2.11.tar.gz
(
    cd zlib-1.2.11
    ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)

# ---------------------------------------------------------------------------
log "sqlite"
# ---------------------------------------------------------------------------
# SONAME libsqlite3.so.0. The version matters: CPython 3.13 calls
# sqlite3_deserialize, which needs sqlite >= 3.36, so a distribution's own
# copy is frequently too old (Ubuntu 20.04 ships 3.31).
fetch "$MIRROR/debian/pool/main/s/sqlite3/sqlite_3.45.1.orig.tar.gz" sqlite.tgz \
  || fetch "https://www.sqlite.org/2024/sqlite-autoconf-3450100.tar.gz" sqlite.tgz
rm -rf sqlite-autoconf-* && tar xf sqlite.tgz
(
    cd sqlite-autoconf-* 2>/dev/null || cd sqlite-*
    ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" \
        --disable-static --enable-shared --disable-readline \
        "LDFLAGS=-Wl,-soname,libsqlite3.so.0" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)

# ---------------------------------------------------------------------------
log "CPython $CPYTHON_VERSION"
# ---------------------------------------------------------------------------
# The build rpath points into $PREFIX so that the import test CPython runs on
# every module resolves *our* sqlite, not the distribution's older one. It is
# rewritten to the $ORIGIN form afterwards and must never ship.
fetch "$MIRROR/python/$CPYTHON_VERSION/Python-$CPYTHON_VERSION.tgz" "Python-$CPYTHON_VERSION.tgz"
rm -rf "Python-$CPYTHON_VERSION" && tar xf "Python-$CPYTHON_VERSION.tgz"
(
    cd "Python-$CPYTHON_VERSION"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$FFI_STATIC:$PREFIX/lib/pkgconfig"
    ./configure \
        --prefix="$PREFIX" \
        --enable-shared \
        --with-ensurepip=no \
        CFLAGS="-O2 -fPIC" \
        CPPFLAGS="-I$PREFIX/include" \
        LDFLAGS="-L$FFI_STATIC -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
        LIBS="-lffi -lsqlite3 -lz" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
)

# CPython puts the static archive under its config directory; link steps want
# it beside the shared one.
cp -f "$PREFIX/lib/python$PYTHON_SERIES/config-$PYTHON_SERIES-x86_64-linux-gnu/libpython$PYTHON_SERIES.a" \
      "$PREFIX/lib/libpython$PYTHON_SERIES.a"

# ---------------------------------------------------------------------------
log "link libffi statically into _ctypes"
# ---------------------------------------------------------------------------
# The shipped x86-64 _ctypes needs only libc, and docs/linux-x86_64.md says so
# explicitly. CPython 3.13 prefers the system libffi and would emit a
# DT_NEEDED for libffi.so.7 -- the 32-bit module's legacy dependency, absent
# from modern 64-bit hosts. Linking the static archive instead removes the
# dependency entirely, which is what makes one build work on both ends of the
# supported range.
#
# GNU ld resolves -lffi against the first search directory containing either
# libffi.so or libffi.a, preferring .so within a directory, so a directory
# holding only the .a wins over the system directory that holds the .so.
# CPython 3.13 has no bundled libffi, so there is no alternative to this.
FFI_STATIC="$PREFIX/libffi-static"
mkdir -p "$FFI_STATIC"
if [ -f /usr/lib/x86_64-linux-gnu/libffi.a ]; then
    cp -f /usr/lib/x86_64-linux-gnu/libffi.a "$FFI_STATIC/"
else
    echo "libffi.a not found; build libffi from source and put the archive in $FFI_STATIC" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
log "rewrite the module rpath"
# ---------------------------------------------------------------------------
DL="$PREFIX/lib/python$PYTHON_SERIES/lib-dynload"
for m in "$DL"/*.so; do
    patchelf --set-rpath '$ORIGIN/../plat-linux64' "$m"
done
# libpython itself needs none: core.so's RUNPATH finds it.
patchelf --remove-rpath "$PREFIX/lib/libpython$PYTHON_SERIES.so.1.0" 2>/dev/null || true
patchelf --remove-rpath "$PREFIX/lib/libsqlite3.so.0.8.6" 2>/dev/null || true

# ---------------------------------------------------------------------------
log "Boost $BOOST_VERSION"
# ---------------------------------------------------------------------------
# The interpreter has to be runnable for b2 to interrogate it, and our
# libpython is not on the default search path, so LD_LIBRARY_PATH is required
# for the bootstrap as well as the build.
fetch "https://archives.boost.io/release/$BOOST_VERSION/source/boost_${BOOST_VERSION//./_}.tar.bz2" \
      "boost_${BOOST_VERSION//./_}.tar.bz2"
rm -rf "boost_${BOOST_VERSION//./_}"
tar xf "boost_${BOOST_VERSION//./_}.tar.bz2"
(
    cd "boost_${BOOST_VERSION//./_}"
    export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    ./bootstrap.sh \
        --with-python="$PREFIX/bin/python$PYTHON_SERIES" \
        --with-python-version="$PYTHON_SERIES" \
        --with-libraries=python,filesystem >/dev/null
    # filesystem has to be requested too; `python` alone does not build it.
    ./b2 python,filesystem --without-mpi \
        toolset=gcc variant=release link=static threading=multi runtime-link=shared \
        "cxxflags=-O2 -fPIC" stage >/dev/null
)

# ---------------------------------------------------------------------------
log "AsmJit"
# ---------------------------------------------------------------------------
# thirdparty/AsmJit/lib/linux64/libasmjit.a referenced __isoc23_strtol, the
# C23 rename of strtol that arrived in glibc 2.38. A 2.31 host has never heard
# of it, so core.so failed to load with an undefined symbol. The x86 copy does
# not reference it.
#
# The whole AsmJit 1.14.0 source is committed under thirdparty/AsmJit/include --
# every .cpp sits beside its header -- so this builds the library from the exact
# sources those headers came from, with no download and no version drift. Only
# upstream's CMakeLists.txt is absent, and it does nothing here that the loop
# below does not: glob the sources, compile them, emit a static archive.
mkdir -p "$WORK/asmjit"
tar xzf "${ASMJIT_SOURCE_TGZ:?set ASMJIT_SOURCE_TGZ to a tarball of thirdparty/AsmJit/include}" \
    -C "$WORK/asmjit"
(
    cd "$WORK/asmjit"
    mkdir -p obj
    for cpp in $(find include -name '*.cpp' | sort); do
        g++ -c -O2 -fPIC -m64 -std=c++11 -w \
            -Iinclude -DASMJIT_STATIC -DASMJIT_NO_LIBRARY \
            "$cpp" -o "obj/$(echo "$cpp" | tr '/' '_' | sed 's/\.cpp$/.o/')"
    done
    ar rcs libasmjit.a obj/*.o
    ranlib libasmjit.a 2>/dev/null || true
)

# ---------------------------------------------------------------------------
log "assemble"
# ---------------------------------------------------------------------------
mkdir -p "$OUT/thirdparty/python_linux64/libs" \
         "$OUT/thirdparty/python_linux64/include/cpython" \
         "$OUT/thirdparty/python_linux64/include/internal" \
         "$OUT/thirdparty/boost/lib/linux64" \
         "$OUT/Python3/plat-linux64" \
         "$OUT/Python3/lib-dynload-linux64"

cp -f "$PREFIX/lib/libpython$PYTHON_SERIES.a"       "$OUT/thirdparty/python_linux64/libs/"
# linux.base.cmake lists both the archive and the shared object in
# SOURCEPYTHON_LINK_LIBRARIES_RELEASE, so the build-time libs directory needs
# the shared one too even though the archive satisfies the symbols first and
# --as-needed drops the resulting DT_NEEDED.
cp -f "$PREFIX/lib/libpython$PYTHON_SERIES.so.1.0"  "$OUT/thirdparty/python_linux64/libs/"
cp -f "$PREFIX/lib/libpython$PYTHON_SERIES.so.1.0"  "$OUT/Python3/plat-linux64/"
cp -fL "$PREFIX/lib/libsqlite3.so.0"                "$OUT/Python3/plat-linux64/"
cp -fL "$PREFIX/lib/libz.so.1.2.11"                 "$OUT/Python3/plat-linux64/"
cp -f "$WORK/boost_${BOOST_VERSION//./_}/stage/lib/libboost_python313.a"  "$OUT/thirdparty/boost/lib/linux64/"
cp -f "$WORK/boost_${BOOST_VERSION//./_}/stage/lib/libboost_filesystem.a" "$OUT/thirdparty/boost/lib/linux64/"
mkdir -p "$OUT/thirdparty/AsmJit/lib/linux64"
cp -f "$WORK/asmjit/libasmjit.a" "$OUT/thirdparty/AsmJit/lib/linux64/"
# boost_system is header-only in modern Boost; an empty archive keeps the
# link line in linux.base.cmake unchanged.
: > "$OUT/thirdparty/boost/lib/linux64/libboost_system.a"

cp -f "$PREFIX/include/python$PYTHON_SERIES"/*.h          "$OUT/thirdparty/python_linux64/include/"
cp -f "$PREFIX/include/python$PYTHON_SERIES/cpython"/*.h  "$OUT/thirdparty/python_linux64/include/cpython/"
cp -f "$PREFIX/include/python$PYTHON_SERIES/internal"/*.h "$OUT/thirdparty/python_linux64/include/internal/"
cp -f "$DL"/*.so "$OUT/Python3/lib-dynload-linux64/"

strip --strip-unneeded "$OUT/Python3/plat-linux64/libpython$PYTHON_SERIES.so.1.0"
strip --strip-unneeded "$OUT/Python3/plat-linux64/libsqlite3.so.0"
strip -g "$OUT/thirdparty/python_linux64/libs/libpython$PYTHON_SERIES.a"
strip -g "$OUT/thirdparty/boost/lib/linux64/"*.a
strip -g "$OUT/thirdparty/AsmJit/lib/linux64/libasmjit.a"

# ---------------------------------------------------------------------------
log "verify the floor"
# ---------------------------------------------------------------------------
# Report rather than assert: the caller decides. A single object over budget
# invalidates the whole run, and the CI guard is what turns that into a
# failure.
worst=0
for f in "$OUT/Python3/plat-linux64/"*.so* "$OUT/Python3/lib-dynload-linux64/"*.so; do
    [ -f "$f" ] || continue
    v=$(grep -aoE 'GLIBC_2\.[0-9]+' "$f" | sort -u -V | tail -1 | cut -d. -f2)
    v=${v:-0}
    [ "$v" -gt "$worst" ] && worst=$v
done
echo "worst glibc minor version across the runtime: 2.$worst"
if [ "$worst" -gt 31 ]; then
    echo "FAIL: the runtime requires glibc 2.$worst but the budget is 2.31." >&2
    exit 1
fi
# A version check cannot see this class of problem at all: a prebuilt can name
# a symbol that only exists in a newer libc without pinning any version, which
# is exactly how __isoc23_strtol and _M_replace_cold got in. Look for the
# symbol names themselves.
for sym in '_M_replace_cold' '__isoc23_'; do
    if grep -rlF "$sym" "$OUT/thirdparty" 2>/dev/null | grep -q .; then
        echo "FAIL: a prebuilt references '$sym', which this toolchain cannot emit" >&2
        echo "      and an older host does not provide." >&2
        grep -rlF "$sym" "$OUT/thirdparty" | sed 's/^/      /' >&2
        exit 1
    fi
done
echo "OK: no _M_replace_cold, no __isoc23_, no libffi dependency, floor within budget"
# The CI step that ldd's this module fails on an unresolved dependency, and
# libffi.so.7 is exactly the name that is absent from modern 64-bit hosts.
if grep -rl 'libffi\.so' "$OUT/Python3/lib-dynload-linux64/" 2>/dev/null | grep -q .; then
    echo "FAIL: an extension module still needs libffi.so; the static link did not take." >&2
    exit 1
fi
echo "OK: no _M_replace_cold, no libffi dependency, floor within budget"
