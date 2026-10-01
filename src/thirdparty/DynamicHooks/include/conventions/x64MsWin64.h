/**
 * ============================================================================
 *  x64MsWin64 - Microsoft x64 (Windows) calling convention
 * ============================================================================
 *
 *  Windows x64 has exactly ONE calling convention, and its parameter rules are
 *  completely different from the x86 cdecl/stdcall/thiscall/fastcall family.
 *  It is therefore a standalone implementation, not a variant of any x86 one:
 *
 *    - integer/pointer args #1..#4 -> RCX, RDX, R8, R9
 *    - floating point args  #1..#4 -> XMM0, XMM1, XMM2, XMM3
 *    - arg #5 and beyond           -> stack
 *    - Slots are assigned by ARGUMENT POSITION, not by counting each register
 *      class separately:
 *        (int, double, int, double) => RCX, XMM1, R8, XMM3   <- note the XMM ids
 *      This is the single most common mistake when porting from System V, which
 *      does use two independent counters (SysV would give RCX, XMM0, R8, XMM1).
 *    - The caller reserves 32 bytes of home space (shadow space) above the
 *      return address, so on entry to the callee:
 *        [RSP + 0]          return address
 *        [RSP + 8 .. +40)   home space (32 bytes / four 8-byte slots)
 *        [RSP + 40]         arg #5 (the first stack argument)
 *    - Return values: integer/pointer -> RAX, float/double -> XMM0.
 *    - The caller cleans the stack, so GetPopSize() is always 0.
 *
 *  Known limitations (same trade-offs as the upstream x64GccSystemV backend):
 *    - Aggregates passed by value and __m128 are not supported (DataType_t has
 *      no corresponding member).
 *    - The varargs rule "float argument goes in BOTH the XMM register and the
 *      matching integer register" is not supported.
 *    - __vectorcall is not supported.
 *
 *  The interface matches the upstream x64GccSystemV from PR #11 exactly, so the
 *  two are drop-in replacements for each other.
 */

#ifndef _X64_MS_WIN64_H
#define _X64_MS_WIN64_H

#include <vector>
#include <list>

#include "convention.h"

class x64MsWin64 : public ICallingConvention
{
public:
	x64MsWin64(
		std::vector<DataType_t> vecArgTypes,
		DataType_t returnType,
		int iAlignment = 8
	) : ICallingConvention(vecArgTypes, returnType, iAlignment) {}

	std::list<Register_t> GetRegisters();
	int GetPopSize();
	void* GetArgumentPtr(int iIndex, CRegisters* pRegisters);
	void ArgumentPtrChanged(int iIndex, CRegisters* pRegisters, void* pArgumentPtr);
	void* GetReturnPtr(CRegisters* pRegisters);
	void ReturnPtrChanged(CRegisters* pRegisters, void* pReturnPtr);

	CRegister* GetRegister(Register_t reg, CRegisters* pRegisters);

private:
	bool IsSseType(DataType_t type) const;

	/**
	 * Returns the stack offset of argument iIndex (only meaningful for the 5th
	 * argument and beyond). The offset is relative to RSP at function entry.
	 */
	size_t GetStackArgumentOffset(int iIndex) const;
};

#endif // _X64_MS_WIN64_H
