/**
 * ============================================================================
 *  x64MsWin64 - Microsoft x64 (Windows) calling convention
 * ============================================================================
 *  See the header comment in x64MsWin64.h for the ABI rules.
 */

#include "x64MsWin64.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>

#include "registers.h"

// ============================================================================
//  Win64 ABI constants
// ============================================================================

/** Registers used by integer/pointer args #1..#4 (by position, not by class). */
static const Register_t g_integerRegisters[] = { RCX, RDX, R8, R9 };

/** Registers used by floating point args #1..#4. */
static const Register_t g_sseRegisters[] = { XMM0, XMM1, XMM2, XMM3 };

/** Number of arguments that can be passed in registers. */
static const int g_maxRegisterArguments = 4;

/**
 * These two values locate stack arguments. They describe the stack layout as it
 * looks AT FUNCTION ENTRY:
 *
 *      [RSP + 0]           return address
 *      [RSP + 8 .. +40)    home space (32 bytes / four 8-byte slots)
 *      [RSP + 40]          arg #5 (the first stack argument)
 *      [RSP + 48]          arg #6
 *      ...
 */
static const size_t kReturnAddressSize = 8;
static const size_t kHomeSpaceSize     = 32;

/**
 * If your bridge pushes extra data onto the stack before taking the register
 * snapshot (for example, another 8-byte return address because the bridge is
 * reached with a `call`), set this to the number of extra bytes. Nothing else
 * needs to change.
 *
 * Upstream x64GccSystemV records the return address in X64Snapshot::
 * dispatchReturn; the Windows backend is expected to do the same, so this stays
 * at 0 here. Calibrate it against a real hook test, not against
 * test_x64_ms_win64 (which does not exercise the bridge).
 */
static const size_t kRspBias = 0;

// ============================================================================
//  Helpers
// ============================================================================

bool x64MsWin64::IsSseType(DataType_t type) const
{
	return type == DATA_TYPE_FLOAT || type == DATA_TYPE_DOUBLE;
}

size_t x64MsWin64::GetStackArgumentOffset(int iIndex) const
{
	// On Win64 every stack argument occupies one 8-byte slot.
	return kRspBias + kReturnAddressSize + kHomeSpaceSize
	       + static_cast<size_t>(iIndex - g_maxRegisterArguments) * 8;
}

CRegister* x64MsWin64::GetRegister(Register_t reg, CRegisters* pRegisters)
{
	if (!pRegisters)
		return NULL;

	switch (reg)
	{
		case RAX:  return pRegisters->m_rax;
		case RCX:  return pRegisters->m_rcx;
		case RDX:  return pRegisters->m_rdx;
		case RBX:  return pRegisters->m_rbx;
		case RSP:  return pRegisters->m_rsp;
		case RBP:  return pRegisters->m_rbp;
		case RSI:  return pRegisters->m_rsi;
		case RDI:  return pRegisters->m_rdi;
		case R8:   return pRegisters->m_r8;
		case R9:   return pRegisters->m_r9;
		case R10:  return pRegisters->m_r10;
		case R11:  return pRegisters->m_r11;
		case R12:  return pRegisters->m_r12;
		case R13:  return pRegisters->m_r13;
		case R14:  return pRegisters->m_r14;
		case R15:  return pRegisters->m_r15;
		case XMM0: return pRegisters->m_xmm0;
		case XMM1: return pRegisters->m_xmm1;
		case XMM2: return pRegisters->m_xmm2;
		case XMM3: return pRegisters->m_xmm3;
		case XMM4: return pRegisters->m_xmm4;
		case XMM5: return pRegisters->m_xmm5;
		case XMM6: return pRegisters->m_xmm6;
		case XMM7: return pRegisters->m_xmm7;
		default:   return NULL;
	}
}

// ============================================================================
//  ICallingConvention
// ============================================================================

std::list<Register_t> x64MsWin64::GetRegisters()
{
	std::list<Register_t> registers;

	// Stack arguments are located via RSP, so always save it.
	registers.push_back(RSP);

	// Return value register.
	if (m_returnType != DATA_TYPE_VOID)
	{
		if (IsSseType(m_returnType))
			registers.push_back(XMM0);
		else
			registers.push_back(RAX);
	}

	// The first 4 arguments live in registers, assigned by position.
	const size_t count = m_vecArgTypes.size();
	const size_t registerArgs = count < static_cast<size_t>(g_maxRegisterArguments)
	                            ? count
	                            : static_cast<size_t>(g_maxRegisterArguments);

	for (size_t i = 0; i < registerArgs; ++i)
	{
		Register_t reg = IsSseType(m_vecArgTypes[i])
		                 ? g_sseRegisters[i]
		                 : g_integerRegisters[i];

		// CRegisters only allocates storage for registers present in the list,
		// and a duplicate would allocate two unrelated buffers.
		if (std::find(registers.begin(), registers.end(), reg) == registers.end())
			registers.push_back(reg);
	}

	return registers;
}

int x64MsWin64::GetPopSize()
{
	// The caller cleans up on Win64.
	return 0;
}

void* x64MsWin64::GetArgumentPtr(int iIndex, CRegisters* pRegisters)
{
	if (iIndex < 0 || static_cast<size_t>(iIndex) >= m_vecArgTypes.size())
		return NULL;

	if (!pRegisters)
		return NULL;

	if (iIndex < g_maxRegisterArguments)
	{
		Register_t reg = IsSseType(m_vecArgTypes[iIndex])
		                 ? g_sseRegisters[iIndex]
		                 : g_integerRegisters[iIndex];

		CRegister* pRegister = GetRegister(reg, pRegisters);
		return pRegister ? pRegister->m_pAddress : NULL;
	}

	CRegister* pRsp = pRegisters->m_rsp;
	if (!pRsp)
		return NULL;

	uintptr_t rsp = pRsp->GetValue<uintptr_t>();
	return reinterpret_cast<void*>(rsp + GetStackArgumentOffset(iIndex));
}

void x64MsWin64::ArgumentPtrChanged(int iIndex, CRegisters* pRegisters, void* pArgumentPtr)
{
	// Arguments live in-place in the register snapshot or in the stack slot, so
	// writing through pArgumentPtr is enough; nothing has to be written back.
	(void) iIndex;
	(void) pRegisters;
	(void) pArgumentPtr;
}

void* x64MsWin64::GetReturnPtr(CRegisters* pRegisters)
{
	if (m_returnType == DATA_TYPE_VOID || !pRegisters)
		return NULL;

	if (IsSseType(m_returnType))
	{
		CRegister* pRegister = pRegisters->m_xmm0;
		return pRegister ? pRegister->m_pAddress : NULL;
	}

	CRegister* pRegister = pRegisters->m_rax;
	return pRegister ? pRegister->m_pAddress : NULL;
}

void x64MsWin64::ReturnPtrChanged(CRegisters* pRegisters, void* pReturnPtr)
{
	(void) pRegisters;
	(void) pReturnPtr;
}
