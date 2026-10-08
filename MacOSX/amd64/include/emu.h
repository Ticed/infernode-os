/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 *
 * amd64 (x86_64) macOS version
 */

extern Proc *getup(void);
#define	up	(getup())

/*
 * This structure must agree with FPsave and FPrestore asm routines
 * macOS saves the SSE/x87 state across thread switches itself,
 * so FPsave and FPrestore are stubs and this is only a placeholder
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[512] __attribute__((aligned(16)));	/* FXSAVE-sized; unused */
};

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
