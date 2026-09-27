# ------------------------------------------------------------------
# File: src/makefiles/win32/win32.base.cmake
# Purpose: This is the base Windows CMake file which sets a bunch of
#    shared flags across all Windows builds, for both x86 and x86-64.
#
# Architecture handling mirrors src/makefiles/linux/linux.base.cmake: the
# per-architecture third-party directories are appended here rather than in
# shared.cmake, so shared.cmake stays platform-neutral and each base file owns
# its own layout.
#
# Everything that differs between the two architectures is confined to the
# SOURCEPYTHON_ARCH blocks below. The x86 values are byte-for-byte what this
# file always used, so an x86 build is unaffected by the x86-64 work.
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# Included makefiles
# ------------------------------------------------------------------
include("makefiles/branch/${BRANCH}.cmake")
include("makefiles/shared.cmake")

# ------------------------------------------------------------------
# Per-architecture third-party layout
# ------------------------------------------------------------------
If(SOURCEPYTHON_ARCH STREQUAL "x86_64")
    # The committed x86-64 Windows libraries live in a parallel tree, exactly as
    # the Linux ones do in lib/linux64. Nothing falls back to the x86 copies:
    # a wrong-architecture import library would link and then fail at load time,
    # which is a far worse failure than a missing file at build time.
    Set(PYTHONSDK            ${THIRDPARTY_DIR}/python_win64)
    Set(BOOSTSDK_LIB         ${BOOSTSDK_LIB}/win64)
    Set(DYNCALLSDK_LIB       ${DYNCALLSDK_LIB}/win64)
    Set(ASMJITSDK_LIB        ${ASMJITSDK_LIB}/win64)
    Set(DYNAMICHOOKSSDK_LIB  ${DYNAMICHOOKSSDK_LIB}/win64)

    # The MSVC compiler macro. COMPILER_MSVC32 is a 32-bit assertion and several
    # places in the tree branch on it, so x86-64 needs the 64-bit counterpart.
    # -D_WIN32 stays: it means "Windows", not "32-bit", and is relied on as such.
    Set(SOURCEPYTHON_MSVC_ARCH_DEFINE COMPILER_MSVC64)

    # The HL2SDK keeps its per-architecture Windows libraries in public/x86 and
    # public/x64. Confirmed present at all four x86-64 pins.
    Set(SOURCEPYTHON_SDK_ARCH_DIR x64)
Else()
    # PYTHONSDK has to be set here as well, not only in the x86-64 branch. An
    # earlier revision of this file replaced the unconditional
    # "Set(PYTHONSDK ${THIRDPARTY_DIR}/python_win32)" with the x86-64 line and
    # no counterpart here, which left PYTHONSDK undefined for 32-bit builds:
    # PYTHONSDK_INCLUDE then expanded to a bare "/include", the real
    # python_win32/include was never added to the include path, and the build
    # failed with 97 instances of
    #   error C1083: cannot open include file: 'pyconfig.h'
    # from boost/python/detail/wrap_python.hpp. It is worth writing down because
    # the x86-64 build was green throughout and nothing about the missing line
    # points at 32-bit.
    Set(PYTHONSDK            ${THIRDPARTY_DIR}/python_win32)
    Set(SOURCEPYTHON_MSVC_ARCH_DEFINE COMPILER_MSVC32)
    Set(SOURCEPYTHON_SDK_ARCH_DIR x86)
EndIf()

# ------------------------------------------------------------------
# Python directories
# ------------------------------------------------------------------
Set(PYTHONSDK_INCLUDE    ${PYTHONSDK}/include)
Set(PYTHONSDK_LIB        ${PYTHONSDK}/libs)

# ------------------------------------------------------------------
# Add in the python sdk as an include directory.
# ------------------------------------------------------------------
Include_Directories(
    ${PYTHONSDK_INCLUDE}
)

# ------------------------------------------------------------------
# Required to get SP to compile on MSVC for csgo.
# ------------------------------------------------------------------
Add_Definitions(-DCOMPILER_MSVC -D${SOURCEPYTHON_MSVC_ARCH_DEFINE} -D_WIN32)

# ------------------------------------------------------------------
# Release flags.
# ------------------------------------------------------------------
Set(CMAKE_CXX_FLAGS_RELEASE "/D_NDEBUG /MD /wd4005 /MP")

# ------------------------------------------------------------------
# Statically link runtime libraries for the loader
# ------------------------------------------------------------------
set_property(TARGET core source-python PROPERTY
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

# ------------------------------------------------------------------
# SafeSEH.
#
# /SAFESEH:NO is an x86-only linker option: the x86-64 ABI has no SafeSEH table
# at all, because it uses a table-based exception model instead. Passing it to a
# 64-bit link is at best a warning and at worst an error, so it is applied only
# to the 32-bit build. (The win32 file has always set it; restricting it is a
# behaviour change for x86 of nothing, since x86 still gets it.)
# ------------------------------------------------------------------
If(SOURCEPYTHON_ARCH STREQUAL "x86")
    SET(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} /SAFESEH:NO")
EndIf()

# ------------------------------------------------------------------
# Boost library names.
#
# The x86 libraries carry a full toolchain tag in the filename, for example
# libboost_python313-vc143-mt-s-x32-1_87.lib: compiler, runtime, "x32" for
# 32-bit, then the library version. Predicting the x86-64 tag would mean
# guessing the compiler version and the Boost version that will be dropped in,
# and a wrong guess produces a confusing "cannot open file" at build time.
#
# So the x86-64 names are globbed from whatever is actually present, and a miss
# is reported as a message naming the directory that was searched. That also
# means adding the x86-64 Boost libraries later needs no edit here.
# ------------------------------------------------------------------
If(SOURCEPYTHON_ARCH STREQUAL "x86_64")
    File(GLOB SOURCEPYTHON_BOOST_FILESYSTEM_X64 "${BOOSTSDK_LIB}/libboost_filesystem*x64*.lib")
    File(GLOB SOURCEPYTHON_BOOST_SYSTEM_X64     "${BOOSTSDK_LIB}/libboost_system*x64*.lib")
    File(GLOB SOURCEPYTHON_BOOST_PYTHON_X64     "${BOOSTSDK_LIB}/libboost_python*x64*.lib")

    # Emptiness is checked before List(GET): taking element -1 of an empty list
    # is itself a hard error, and doing it first turned one clear diagnostic into
    # four, two of which ("List GET given empty list") said nothing about the
    # cause.
    If(NOT SOURCEPYTHON_BOOST_FILESYSTEM_X64)
        Message(FATAL_ERROR
            "No x86-64 boost_filesystem library was found in ${BOOSTSDK_LIB}. "
            "The x86-64 Boost libraries are looked up by an *x64* glob so the "
            "toolchain tag does not have to be predicted.")
    EndIf()
    If(NOT SOURCEPYTHON_BOOST_SYSTEM_X64)
        Message(FATAL_ERROR
            "No x86-64 boost_system library was found in ${BOOSTSDK_LIB}. "
            "The x86-64 Boost libraries are looked up by an *x64* glob so the "
            "toolchain tag does not have to be predicted.")
    EndIf()
    If(NOT SOURCEPYTHON_BOOST_PYTHON_X64)
        Message(FATAL_ERROR
            "No x86-64 boost_python library was found in ${BOOSTSDK_LIB}. "
            "The x86-64 Boost libraries are looked up by an *x64* glob so the "
            "toolchain tag does not have to be predicted.")
    EndIf()

    # Sort so the choice is deterministic when several builds are present, then
    # take the last, which for these tags is the newest.
    List(SORT SOURCEPYTHON_BOOST_FILESYSTEM_X64)
    List(SORT SOURCEPYTHON_BOOST_SYSTEM_X64)
    List(SORT SOURCEPYTHON_BOOST_PYTHON_X64)
    List(GET SOURCEPYTHON_BOOST_FILESYSTEM_X64 -1 SOURCEPYTHON_BOOST_FILESYSTEM_X64)
    List(GET SOURCEPYTHON_BOOST_SYSTEM_X64 -1     SOURCEPYTHON_BOOST_SYSTEM_X64)
    List(GET SOURCEPYTHON_BOOST_PYTHON_X64 -1     SOURCEPYTHON_BOOST_PYTHON_X64)

    Message(STATUS "x86-64 Boost libraries chosen:")
    Message(STATUS "  ${SOURCEPYTHON_BOOST_FILESYSTEM_X64}")
    Message(STATUS "  ${SOURCEPYTHON_BOOST_SYSTEM_X64}")
    Message(STATUS "  ${SOURCEPYTHON_BOOST_PYTHON_X64}")
EndIf()

# ------------------------------------------------------------------
# Link libraries.
# ------------------------------------------------------------------
Set(SOURCEPYTHON_LINK_LIBRARIES
    ${SOURCEPYTHON_LINK_LIBRARIES}
    ${DYNCALLSDK_LIB}/libdyncall_s.lib
    ${DYNCALLSDK_LIB}/libdyncallback_s.lib
    ${DYNCALLSDK_LIB}/libdynload_s.lib
    ${ASMJITSDK_LIB}/AsmJit.lib
    ${DYNAMICHOOKSSDK_LIB}/DynamicHooks.lib
)

If(SOURCEPYTHON_ARCH STREQUAL "x86_64")
    List(APPEND SOURCEPYTHON_LINK_LIBRARIES
        ${SOURCEPYTHON_BOOST_FILESYSTEM_X64}
        ${SOURCEPYTHON_BOOST_SYSTEM_X64}
    )
Else()
    List(APPEND SOURCEPYTHON_LINK_LIBRARIES
        ${BOOSTSDK_LIB}/libboost_filesystem-vc143-mt-s-x32-1_87.lib
        ${BOOSTSDK_LIB}/libboost_system-vc143-mt-s-x32-1_87.lib
    )
EndIf()

If( SOURCE_ENGINE MATCHES "orangebox")
    Set(SOURCEPYTHON_LINK_LIBRARIES
        ${SOURCEPYTHON_LINK_LIBRARIES}
        ${SOURCESDK_LIB}/public/${SOURCEPYTHON_SDK_ARCH_DIR}/tier0.lib
        ${SOURCESDK_LIB}/public/${SOURCEPYTHON_SDK_ARCH_DIR}/tier1.lib
        ${SOURCESDK_LIB}/public/${SOURCEPYTHON_SDK_ARCH_DIR}/vstdlib.lib
        ${SOURCESDK_LIB}/public/${SOURCEPYTHON_SDK_ARCH_DIR}/mathlib.lib
    )
Else()
    Set(SOURCEPYTHON_LINK_LIBRARIES
        ${SOURCEPYTHON_LINK_LIBRARIES}
        ${SOURCESDK_LIB}/public/tier0.lib
        ${SOURCESDK_LIB}/public/tier1.lib
        ${SOURCESDK_LIB}/public/tier2.lib
        ${SOURCESDK_LIB}/public/tier3.lib
        ${SOURCESDK_LIB}/public/vstdlib.lib
        ${SOURCESDK_LIB}/public/mathlib.lib
    )
Endif()

# CSGO Engine adds in interfaces.lib
If( SOURCE_ENGINE MATCHES "csgo" OR SOURCE_ENGINE MATCHES "blade")
    Set(SOURCEPYTHON_LINK_LIBRARIES
        ${SOURCEPYTHON_LINK_LIBRARIES}
        ${SOURCESDK_LIB}/public/interfaces.lib
    )
Endif()

If( SOURCE_ENGINE MATCHES "csgo" OR SOURCE_ENGINE MATCHES "blade")
    Set(SOURCEPYTHON_LINK_LIBRARIES
        ${SOURCEPYTHON_LINK_LIBRARIES}
        ${SOURCESDK_LIB}/win32/release/vs2017/libprotobuf.lib
    )
Endif()

# ------------------------------------------------------------------
# Release link libraries
# ------------------------------------------------------------------
Set(SOURCEPYTHON_LINK_LIBRARIES_RELEASE
    optimized ${PYTHONSDK_LIB}/python313.lib
)

If(SOURCEPYTHON_ARCH STREQUAL "x86_64")
    List(APPEND SOURCEPYTHON_LINK_LIBRARIES_RELEASE
        optimized ${SOURCEPYTHON_BOOST_PYTHON_X64}
    )
Else()
    List(APPEND SOURCEPYTHON_LINK_LIBRARIES_RELEASE
        optimized ${BOOSTSDK_LIB}/libboost_python313-vc143-mt-s-x32-1_87.lib
    )
EndIf()

If( SOURCE_ENGINE MATCHES "csgo" )
    SET(SOURCEPYTHON_LINK_LIBRARIES_RELEASE
        ${SOURCEPYTHON_LINK_LIBRARIES_RELEASE}
        optimized ${SOURCESDK_LIB}/win32/release/vs2010/libprotobuf.lib
    )
Endif()
