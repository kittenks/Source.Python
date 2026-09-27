# Linux x86-64 (HL2DM)

Linux x86-64 support is currently limited to the `hl2dm` branch. The existing
x86 build remains the default.

Build with:

```sh
cd src
bash ./Build.sh hl2dm x86_64
```

The preserved 32-bit build remains available as:

```sh
cd src
bash ./Build.sh hl2dm x86
```

The build accepts `SOURCEPYTHON_SDK` as a CMake cache path when the HL2SDK is
outside `src/hl2sdk/hl2dm`.

Architecture-specific dependencies are kept beside, rather than in place of,
the existing x86 dependencies:

```text
thirdparty/python_linux64/
thirdparty/boost/lib/linux64/
thirdparty/dyncall/lib/linux64/
thirdparty/DynamicHooks/lib/linux64/
thirdparty/AsmJit/lib/linux64/
```

The tested dependency baseline is CPython 3.13.2, Boost 1.87, the current
HL2DM branch of AlliedModders HL2SDK, and a DynamicHooks build containing the
Linux System V AMD64 backend.

The packaged runtime uses `Python3/plat-linux64`. Native optional packages in
the standard library are loaded from `Python3/lib-dynload-linux64`, leaving the
existing x86 `Python3/lib-dynload` directory untouched. Native optional
packages in the shared `site-packages` directory must be rebuilt for x86-64;
32-bit extension modules cannot be imported by the x86-64 runtime.

Post-hook callbacks that need function arguments must select the preserved
entry-register snapshot through `CHook::SetUsePreRegisters`. The legacy
`m_bUsePreRegisters` member remains available to the x86 backend, but it is not
the invocation-local selector used by the reentrant x86-64 backend.

The upstream x86 CPython `_ctypes` module still declares `libffi.so.7` as a
runtime dependency. Distributions that no longer provide that SONAME must
supply it separately for 32-bit deployments. This legacy dependency is not
used by the x86-64 `_ctypes` module and was not introduced by this port.

## Runtime floor

The package loads on Ubuntu 20.04 LTS and on everything newer. 2.31 is the
oldest LTS still supported, the `manylinux_2_31` baseline, and one below what
the engine itself needs. A binary built against an older glibc also runs on
every newer distribution, so one artefact covers the whole range.

| file | requires | source |
|---|---|---|
| `addons/source-python.so` | `GLIBC_2.29` | built by the pipeline |
| `addons/source-python/bin/core.so` | `GLIBC_2.30` | built by the pipeline |
| `Python3/plat-linux64/libpython3.13.so.1.0` | `GLIBC_2.30` | committed prebuilt |
| `Python3/plat-linux64/libsqlite3.so.0` | `GLIBC_2.29` | committed prebuilt |
| `Python3/plat-linux64/libz.so.1.2.11` | `GLIBC_2.14` | committed prebuilt |
| `Python3/lib-dynload-linux64/*.so` (68) | `GLIBC_2.29` worst | committed prebuilt |
| Valve's own `bin/linux64/*.so` (all 14) | `GLIBC_2.29` | Valve |
| `Python3/plat-linux/libpython3.13.so.1.0` (x86) | `GLIBC_2.30` | committed prebuilt |

Everything in the x86-64 column is built inside an `ubuntu:20.04` container, so
the compiler cannot emit a symbol version newer than 2.31. That applies both to
what the pipeline compiles and to the prebuilts it links, and
`scripts/ci/build-linux-x86_64-runtime.sh` is what produces the prebuilts.

There is a second, independent floor that a glibc check cannot see:
`libstdc++`. The x86-64 `thirdparty/boost/lib/linux64/` archives used to
reference `std::__cxx11::basic_string<...>::_M_replace_cold`, a libstdc++
internal that no GCC 9 runtime exports, so the addon failed to `dlopen` with
`undefined symbol` on any host whose libstdc++ predates it. Those archives are
rebuilt with GCC 9 and no longer reference it. The x86 copies never did, which
is what made this an x86-64 problem rather than a general one.

Two things in the prebuilt layout are not free choices:

- The extension modules carry `RUNPATH $ORIGIN/../plat-linux64`, the same form
  `core.so` uses to find libpython, so they locate the sibling
  `libsqlite3.so.0` and `libz.so.1.2.11` without depending on Source.Python's
  loader having preloaded them first.
- `_ctypes` must not gain a `DT_NEEDED` for `libffi.so.7`. That SONAME is the
  32-bit module's legacy dependency and is absent from modern 64-bit hosts.
  CPython 3.13 prefers the system libffi and has no bundled copy, so
  `libffi.a` is placed in a directory of its own ahead of the one holding the
  shared object: `ld` resolves `-lffi` against the first directory containing
  either and prefers the `.so` within a directory.

`scripts/ci/verify-packages.ps1 -MaxGlibc64` is set to `2.31` in the x86-64
pipeline and asserts this, so a prebuilt that drifts back onto a newer
toolchain fails the build rather than reaching a host.

Measured on a real 64-bit TF2 dedicated server (Valve app 232250,
`srcds_linux64`) running Ubuntu 20.04.2, x86-64, glibc 2.31 — the oldest
supported target, and the one this floor is chosen for.

