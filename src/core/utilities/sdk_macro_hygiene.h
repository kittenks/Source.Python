/**
 * =============================================================================
 * Source Python
 * Copyright (C) 2012-2015 Source Python Development Team.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by
 * the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, the Source Python Team gives you permission
 * to link the code of this program (as well as its derivative works) to
 * "Half-Life 2," the "Source Engine," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, the Source.Python
 * Development Team grants this exception to all derivative works.
 */

// =============================================================================
// Macros the HL2SDK defines that collide with Boost headers.
//
// Source.Python includes both the HL2SDK and Boost, sometimes in the same
// translation unit with the SDK first. A macro from the SDK that expands inside
// a Boost declaration turns a Boost header into a syntax error, and the
// diagnostic points at the Boost header rather than at the SDK, which is why
// this is worth naming explicitly instead of leaving to be rediscovered.
//
// There is precedent for this in the tree: modules/memory/memory_signature.h
// already #undefs BOOST_PYTHON_FN_CC, N, Q and BOOST_PYTHON_LIST_INC for the
// same reason.
//
// -----------------------------------------------------------------------------
// str_size
//
// hl2sdk/<branch>/public/tier1/strtools.h:30
//
//     #ifdef _WIN64
//     #define str_size unsigned int
//     #else
//     #define str_size size_t
//     #endif
//
// boost/range/detail/implementation_help.hpp:79
//
//     template< class Char >
//     inline std::size_t str_size( const Char* const& s )
//
// Two things are wrong with the SDK's version, and the second is the reason a
// guard change would not be a fix:
//
//   1. The branches are the wrong way round for a length type. On x86-64
//      Windows, where a size_t is 64-bit, the SDK types it as unsigned int,
//      which is 32 bits. Anything that used it as the return type of a string
//      length could truncate. Source.Python itself never uses str_size - the
//      only two occurrences in the whole tree are the two #defines - so nothing
//      here is silently truncated today.
//
//   2. Both branches collide with Boost. Whichever way round they are,
//      defining a macro named str_size replaces the name of the Boost
//      function above. On x86-64 the expansion is literally "unsigned int", so
//      the preprocessor emits
//          inline std::size_t unsigned int( const Char* const& s )
//      and MSVC reports, at that line,
//          error C2628: 'size_t' followed by 'unsigned' is illegal
//          error C2988 / C2059 / C2143 / C2447
//      Which is ten diagnostics that name a Boost header and say nothing about
//      the HL2SDK. It was confirmed by preprocessing the failing translation
//      unit and looking at what the line actually became.
//
// So the macro is undefined rather than corrected. Correcting it would mean
// editing a pinned SDK checkout, and the collision would still be there in the
// other branch.
// =============================================================================

#ifndef _SOURCEPYTHON_SDK_MACRO_HYGIENE_H
#define _SOURCEPYTHON_SDK_MACRO_HYGIENE_H

// The SDK's own strtools.h can be reached through several different headers
// (iserverplugin.h, utlstring.h and others all pull it in), so this cannot be
// tied to one include. #undef is a no-op when the macro was never defined,
// which makes it safe to include this before the SDK as well as after it.
#ifdef str_size
#undef str_size
#endif

#endif // _SOURCEPYTHON_SDK_MACRO_HYGIENE_H
