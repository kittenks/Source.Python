# Windows x86-64 (CSS, DODS, HL2DM, TF2)

Windows x86-64 support covers the four OrangeBox branches whose HL2SDK pins
ship `public/x64` libraries: **Counter-Strike: Source (`css`)**, **Day of
Defeat: Source (`dods`)**, **Half-Life 2: Deathmatch (`hl2dm`)** and **Team
Fortress 2 (`tf2`)**. `src/CMakeLists.txt` hard-fails `x86_64` for every other
branch. The existing 32-bit Windows build remains the default and is
unchanged.

Build with the CI helper scripts:

```powershell
.\scripts\ci\fetch-hl2sdk.ps1 -Branch css
.\scripts\ci\build-windows.ps1 -Branch css -Architecture x86_64
```

The equivalent direct CMake invocation is:

```powershell
cmake -S src -B src/Builds/Windows/css-x86_64 -G "Visual Studio 17 2022" -A x64 `
      -DBRANCH=css -DSOURCEPYTHON_ARCH=x86_64
cmake --build src/Builds/Windows/css-x86_64 --config Release --parallel 2
```

`build-windows.ps1` selects the newest installed Visual Studio generator
automatically, asserts that `core.dll` and `source-python.dll` are PE machine
`0x8664`, and stages them under `artifacts/native/<game>/windows-x86_64/`.

In GitHub Actions the workflow `.github/workflows/build-x64.yml` is
**manual-only** (`workflow_dispatch`); one run builds a single game chosen from
the `css / dods / hl2dm / tf2` drop-down and never creates a release. The
32-bit `build-packages.yml` pipeline is unaffected.

## Architecture-specific dependencies

x86-64 dependencies are kept beside the x86 ones, never in place of them:

```text
thirdparty/python_win64/include/          # CPython 3.13 headers
thirdparty/python_win64/libs/             # python3.lib, python313.lib
thirdparty/boost/lib/win64/               # libboost_{filesystem,system,python313}-vc143-mt-s-x64-1_87.lib
thirdparty/AsmJit/lib/win64/AsmJit.lib
thirdparty/dyncall/lib/win64/             # libdyncall_s, libdyncallback_s, libdynload_s
thirdparty/DynamicHooks/src/*.cpp         # compiled from source on x86-64
thirdparty/HDE64/hde64.c                  # compiled from source on x86-64
```

All compile-time dependencies are static, Release, `/MT` (static CRT). There
is deliberately **no prebuilt `DynamicHooks/lib/win64/DynamicHooks.lib`**: the
archive shipped with upstream DynamicHooks was built for the System V AMD64 ABI
and cannot work on Windows. On x86-64 the four DynamicHooks translation units
and HDE64 are compiled directly into `core.dll` (see
`src/makefiles/win32/win32.base.cmake`). The reproducible build scripts for the
vendored Boost/AsmJit/dyncall archives live in the companion repository
`kittenks/Source.Python-thirdparty-tools-Winx64`.

## Runtime layout

The loader (`src/loader/definitions.h`) uses `Python3/plat-win/python313.dll`
and `Python3/plat-win/vcruntime140.dll` on Windows for **both** architectures;
there is no `plat-win64` directory and no loader change. A Windows x86-64
package therefore ships the x86-64 native runtime **inside `Python3/plat-win`**,
replacing the 32-bit set wholesale (`plat-win` contains only native `.dll`/`.pyd`
files).

That runtime is the official **CPython 3.13.2 embeddable amd64** distribution
(`python-3.13.2-embed-amd64.zip`), reduced to the 28 PE-x86-64 files the port
loads; the embeddable `python313.zip` standard-library archive and
`python313._pth` are dropped because Source.Python ships its own standard
library. The interpreter is not rebuilt from source. The companion
thirdparty-tools repository produces this runtime set; its files were verified
byte-for-byte (SHA-256) identical to the runtime of a working CS:S x64 server.

## Porting notes (why the code differs)

- **DynamicHooks x64 JIT bridge (Microsoft x64 ABI / LLP64).** The bridge must
  reserve the 32-byte shadow/home space the Microsoft ABI requires, and the
  pre-hook bridge must compute the stack pointer with `lea r8,[rsp+frameSize]`
  rather than passing the address of the saved RSP snapshot. Building the
  upstream (System V) archive on Windows was the root cause of the crash when a
  bot joined an empty server.
- **Hibernation detour on a 4-byte function.** On the 64-bit `server.dll`,
  `CServerGameDLL::SetServerHibernation(bool)` is a four-byte setter
  (`88 51 10 C3` plus padding), shorter than the 14 bytes an absolute detour
  needs and unreachable from the old 5-byte near relay at the module's high
  base. Short terminals now use a 14-byte `FF 25` absolute jump that borrows the
  inter-function `CC/90` padding. `listeners.py` keeps the upstream issue #181
  install logic and treats a failed install as a non-fatal warning.
- **LLP64/pointer-width fixes.** Pointer-sized values use `uintptr_t`/`Addr_t`
  rather than `int`/32-bit types across the memory, entities, weapons, studio
  and KeyValues modules, and Python integer conversions use pointer-sized
  helpers. MSVC-specific thunks match only on Windows; RIP-relative pointer
  discovery defaults off.
- **Linux x86-64 guard regression.** The DynamicHooks public headers gate the
  x64 surface on `(defined(__linux__) && defined(__x86_64__)) ||
  defined(DYNAMICHOOKS_X86_64)`, and the Windows-only `m_iPatchBytes` member is
  isolated at the end of `CHook`. This keeps the `CHook`/`CRegisters` layout the
  Linux x86-64 build sees byte-identical to the upstream headers and the
  prebuilt `libDynamicHooks.a`, so the Windows port does not break Linux.

## Diagnostics: the `SP_HOOK_DIAG` build switch (no runtime cvar)

The optional "address and bytes" diagnostics are controlled by a **compile-time
CMake option, not a runtime ConVar**:

```cmake
option(SP_HOOK_DIAG "Enable verbose DynamicHooks x64 address/byte diagnostics (development only)" OFF)
```

It exists only for `x86_64` (see `src/makefiles/win32/win32.base.cmake`). When
enabled it defines `DYNAMICHOOKS_DIAG=1` for the `core` target;
`src/thirdparty/DynamicHooks/src/hook_x64.cpp` defaults the macro to `0`.

- **OFF (default — stable/release builds):** `DYNAMICHOOKS_DIAG=0`. The
  diagnostic code is not compiled into `core.dll` at all, hooks carry zero extra
  overhead, and the fatal error stays a short
  `"Terminating control flow ... before the detour boundary."` message. There
  is no diagnostic cvar, so the extra output cannot be enabled at runtime on a
  stable build.
- **ON (development/test builds):** configure with `-DSP_HOOK_DIAG=ON`. The same
  fatal error additionally reports the target address (`pFunc`) and its first 24
  bytes, which distinguishes a wrong vtable index from a genuinely unsupported
  function prologue when porting to another game or engine build.

Use a separate build directory so the option is not masked by a cached CMake
configure:

```powershell
# Diagnostic (test) build
cmake -S src -B src/Builds/Windows/css-x86_64-diag -G "Visual Studio 17 2022" -A x64 `
      -DBRANCH=css -DSOURCEPYTHON_ARCH=x86_64 -DSP_HOOK_DIAG=ON
cmake --build src/Builds/Windows/css-x86_64-diag --config Release
```

There is intentionally no runtime cvar for this: the diagnostic runs once,
during hook installation at startup, inside the third-party DynamicHooks code —
before Source.Python has registered any ConVar — and a stable package must not
contain the diagnostic code in the first place.

## Stable vs. test packages

The Windows x86-64 workflow offers selectable outputs per game:

- **DLL artifact** — `core.dll` + `source-python.dll` + `build-info.json`
  (`SP_HOOK_DIAG=OFF`).
- **Stable game package** — full runnable addon with the x86-64 runtime and the
  `SP_HOOK_DIAG=OFF` binaries. No diagnostics, no debug plugins, no PDBs; this is
  the clean deployable build.
- **Test game package** — built with `-DSP_HOOK_DIAG=ON`, optionally accompanied
  by the archived diagnostic Source.Python plugins from the companion
  thirdparty-tools repository (`debug/server-plugins/`). Those plugins are
  dropped into `addons/source-python/plugins/` but are **not** auto-loaded; load
  one on demand with `sp plugin load <name>`.

## Verification

Measured on a real Counter-Strike: Source Windows x86-64 dedicated server
(`srcds_win64`, AppID 232330) with `bot_join_after_player 0`,
`bot_quota_mode fill` and `bot_quota 6`: Source.Python loaded with no
hibernation warning, six bots connected and entered the game in the same second
the server reported it was hibernating (with no human player present), and
multiple full rounds (plant/defuse, weapon purchases, kills) completed without a
crash. Hibernation does not block bots from joining, so no hibernation cvar is
needed; `sv_hibernate_when_empty` is a CS:GO command and does not exist in CS:S.

### Team Fortress 2

Measured on a real Team Fortress 2 Windows x86-64 dedicated server
(`srcds_win64`, AppID 232250, build 10828683) with the test package:

- Official bots use the `tf_bot_*` cvars (not the CS `bot_*` ones):
  `tf_bot_quota 6`, `tf_bot_quota_mode fill`, `tf_bot_difficulty 1`, and
  critically `tf_bot_join_after_player 0` (it defaults to `1`, which keeps bots
  out of an otherwise empty server).
- The hibernation cvar is `tf_allow_server_hibernation` (set it to `0` to keep
  an empty server awake); TF2 has no `sv_hibernate_when_empty`. On TF2 the
  hooked `CServerGameDLL::SetServerHibernation` resolves to vtable index 38
  (`server.dll+0x2E69B0`), a ~29-byte thunk that is longer than the 14-byte
  detour, so there is no short-function boundary problem. It was exercised for
  real on the x86-64 server: with an empty server the engine logged
  "Server is hibernating", the Source.Python pre-hook disconnected the bots and
  the original function ran, and waking the server (re-adding bots) resumed
  normal play with no crash across repeated hibernate/wake cycles.
- Over a continuous 20+ minute run, six bots across several classes fought,
  built and destroyed Engineer buildings, captured control points and played
  through several round wins with zero crashes, zero Python tracebacks, zero
  minidumps and flat memory (~485 MB, edicts ~319/2048).

**Navigation meshes are not shipped for most official maps.** The TF2 dedicated
depot (232250) does not include a `.nav` for maps such as
`koth_harvest_final`; bots then join but stand still and never fight. Generate
one once with `sv_cheats 1` followed by `nav_generate` (several minutes; it
saves `<map>.nav` into `tf/maps/` and reloads the map automatically), or copy
the `.nav` from a full game client. This is game-data setup, not a
Source.Python defect.

**Do not delete `addons/source-python/data/source-python/`.** The entity class
definitions under `entities/` (together with `memory/`, `teams/`, `weapons/`
and the rest) are static data shipped in every package, not generated at
runtime. Removing that directory leaves virtual functions such as
`Entity.get_solid_mask()` unregistered; the server keeps running because the
collision manager catches the error, but every networked entity then logs
`AttributeError: Attribute "get_solid_mask" not found` and the collision /
solid-mask / ray-trace features silently stop working. The CI packages were
verified to contain all of these files (188 entity-data entries for TF2). Only
the writable runtime directories (`cfg/source-python`, `logs/source-python`,
`data/source-python/settings`, `plugins`, ...) are created on demand at
startup; the startup code creates them recursively, and the Windows x86-64
package additionally seeds them as empty directory entries so a fresh extract
boots with no manual creation.
