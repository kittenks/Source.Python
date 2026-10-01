/*

 Package: dyncall
 Library: dyncall
 File: dyncall/dyncall_config.h
 Description: Macro configuration file for non-standard C types
 License:

   Copyright (c) 2007-2011 Daniel Adler <dadler@uni-goettingen.de>, 
                           Tassilo Philipp <tphilipp@potion-studios.com>

   Permission to use, copy, modify, and distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

*/


/*

  dyncall type configuration

  REVISION
  2007/12/11 initial

*/

#ifndef DYNCALL_CONFIG_H
#define DYNCALL_CONFIG_H

#include "dyncall_macros.h"

/* uintptr_t is needed for DC_POINTER. dyncall_types.h includes <stddef.h>
   before this header but not <stdint.h>, so it is pulled in here. */
#include <stdint.h>

#define DC_BOOL         bool
#define DC_LONG_LONG    long long

/* Source.Python Windows x86-64: this was `unsigned long`, which is 32 bits
 * under LLP64, so DCpointer - the type dyncall uses for every function pointer
 * it is asked to call - could not hold a 64-bit address.
 *
 * `long` is pointer-width on Linux x86-64 (LP64) and is 32 bits on x86-32, so
 * the original definition is correct on every platform except the one being
 * ported, which is why it has survived upstream.
 *
 * The damage: memory_function.cpp:282 passes an Addr_t into dcCallInt's
 * DCpointer parameter, and line 336 passes an Addr_t into dcArgPointer. Both
 * narrow to 32 bits at the call site, and both were compiled into core.dll.
 * The address then reaches dyncall's assembly already halved, which is not
 * something the library can undo.
 *
 * Confirmed against a minidump of the crash. At the moment of the fault:
 *
 *     rax  = 0x000000007DE677F0        the truncated target
 *     rip  = 0x000000007DE677F0        where the CPU actually branched
 *     [rsp+0x98] = 0x00007FFA7DE677F0  the full address, intact in the
 *                                     caller's own stack frame
 *
 * The lost half was exactly 0x00007FFA00000000, and rip equalled the fault
 * address, so the CPU branched to the truncated value rather than executing a
 * bad instruction at the right one. Three separate runs, two different ASLR
 * bases, the same high half lost every time.
 *
 * uintptr_t rather than void*: it is pointer-width on all three targets, and
 * it keeps the two call sites in memory_function.cpp compiling unchanged,
 * whereas void* would need an explicit cast where an Addr_t is passed.
 *
 * DClong is deliberately left as `long`. That is dyncall's long type and 32
 * bits is the correct width for it on Windows, matching the platform's own
 * long; Source.Python's DATA_TYPE_ULONG is 32-bit at the Python level too.
 * Only DC_POINTER was wrong. */
#define DC_POINTER      uintptr_t

#endif /* DYNCALL_CONFIG_H */

