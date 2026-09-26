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

The package currently loads only on Ubuntu 24.04. Both of the floors below
come from committed prebuilts, and neither is imposed by the engine.

| file | requires | source |
|---|---|---|
| `Python3/plat-linux64/libpython3.13.so.1.0` | `GLIBC_2.38` | committed prebuilt |
| `Python3/plat-linux64/libsqlite3.so.0` | `GLIBC_2.38` | committed prebuilt |
| `addons/source-python/bin/core.so` | `GLIBC_2.30`, `GLIBCXX_3.4.21` | built by the pipeline |
| `addons/source-python.so` | `GLIBC_2.29`, `GLIBCXX_3.4.21` | built by the pipeline |
| Valve's own `bin/linux64/*.so` (all 14) | `GLIBC_2.29` | Valve |
| `Python3/plat-linux/libpython3.13.so.1.0` (x86) | `GLIBC_2.30` | committed prebuilt |

The two objects the pipeline builds are compiled in an `ubuntu:20.04`
container so that the compiler cannot emit a symbol version newer than
2.31. Building on the 22.04 runner image instead produced a gamedll at
2.34 and a core at 2.35, neither of which loads on a supported LTS.

`libstdc++` is a separate floor that the glibc check cannot see.
`thirdparty/boost/lib/linux64/libboost_filesystem.a` references
`std::__cxx11::basic_string<...>::_M_replace_cold`, a libstdc++ internal
that no GCC 9 runtime exports, so the package also needs a libstdc++ from
a compiler newer than GCC 9. The x86 `thirdparty/boost/lib/` copy does not
reference it.

Every one of these x86-64 prebuilts was produced on a newer toolchain than
its x86 counterpart, and **this repository records no recipe for any of
them**: the baseline list above names versions, not procedures. That is why
the floor is 2.38 and cannot simply be lowered. Rebuilding the x86-64
CPython runtime and Boost.Python on an older sysroot is the fix, and until
then `scripts/ci/verify-packages.ps1 -MaxGlibc64` is set to the floor that
can actually be delivered.

Measured on a real 64-bit TF2 dedicated server (Valve app 232250,
`srcds_linux64`) running Ubuntu 20.04.2, x86-64, glibc 2.31. After the
link-name fix, the engine loads the addon and the next failure is
`undefined symbol: ..._M_replace_cold`, then the libpython floor.

