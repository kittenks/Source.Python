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
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, the Source Python Team gives you permission to
 * link the code of this program (as well as its derivative works) to
 * "Half-Life 2," the "Source Engine," and any Game MODs that run on software
 * by the Valve Corporation. You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, the Source.Python
 * Development Team grants this exception to all derivative works.
 */
#ifndef _MEMORY_ADDR_H
#define _MEMORY_ADDR_H

#include <cstdint>

//=============================================================================
// The width of a code or data address in this build.
//=============================================================================
// This has to be pointer-width, and it used to be `unsigned long`, which is
// pointer-width on two of the three supported targets and 32 bits on the third:
//
//   Win32    unsigned long = 32 bits  = pointer width   correct
//   Linux64  unsigned long = 64 bits  = pointer width   correct
//   Win64    unsigned long = 32 bits  != 64-bit pointer  WRONG
//
// Windows is LLP64: long, unsigned long and DWORD are 32 bits even inside a
// 64-bit process, while pointers, intptr_t and uintptr_t are 64. So on Win64
// every address Source.Python handled was being cut to its low 32 bits. The
// code compiles without a diagnostic and links without a diagnostic, and the
// only symptom is a wrong address at run time - a module that cannot be found,
// or a vtable slot that is not in any vtable.
//
// uintptr_t is used rather than a fixed 64-bit type on purpose: it is
// pointer-width everywhere, so Win32 stays 32 bits and Linux64 stays 64 bits and
// neither already-working configuration changes width. A hardcoded 64-bit type
// would have silently widened Win32 as well.
typedef uintptr_t Addr_t;

#endif // _MEMORY_ADDR_H
