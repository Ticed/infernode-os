/*
 * Metal drawing hardware for the emulator on macOS (memhw-metal.m),
 * joined to libmemdraw by memhw.c.  Plain C types only: the Metal
 * headers and Inferno's cannot share a file (Point, Rect).
 */

typedef struct Mtlop Mtlop;
struct Mtlop
{
	int	kind;		/* as Memhwop's: 1 fill, 2 copy, 3 cover, 4 blend */
	int	w, h;
	unsigned char	*dst;
	long	dstride;
	int	dnb;
	int	dshift[4];
	unsigned char	*src;	/* nil: none, or a constant blend */
	long	sstride;
	int	sshift[4];
	unsigned char	*mask;
	long	mstride;
	unsigned int	value;
};

int	mtlinit(void);			/* 0 if there is no device */
void	mtlarena(void*, unsigned long);	/* memory the device may draw in */
int	mtlrun(Mtlop*);			/* queue it; 0 if it cannot */
void	mtlsync(void);			/* wait for everything queued */
