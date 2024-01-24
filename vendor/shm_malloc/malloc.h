#ifndef _malloc_h_
#define _malloc_h_
#include <stddef.h>

#if defined(LOCKTYPE) && LOCKTYPE == SYSVSEM
#include <sys/ipc.h>
#include <sys/sem.h>
#endif /* SYSVSEM */
#if defined(LOCKTYPE) && LOCKTYPE == SPINLOCK
#include "atomic.h"
#endif /* SPINLOCK */
#if defined(LOCKTYPE) && LOCKTYPE == PMUTEX
#include <pthread.h>
#endif /* PMUTEX */

/* PAGESIZE MUST be a constant and MUST be a power of 2.  It may be larger
** than the actual machine page size, but probably can't be smaller
** Total heap memory is limited to PAGESIZE * 2^32, and must in fact be in
** one contiguous extent that size or smaller (so if brk/sbrk gives you holes
** you'll get less memory.)  PAGESIZE must be <= sizeof(void *) * 2^11, (8K
** on a 32-bit machine, 16K on 64-bit) though the bitfields could be rearranged
** to allow up to sizeof(void *) * 2^12 fairly easily.
*/
#if defined(__alpha__)
#define PAGESIZE	8192
#else
#define PAGESIZE	4096
#endif

enum {	size4, size8
#if defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ > 4
		=0
#endif
	, size16
#if defined(__SIZEOF_POINTER__) && __SIZEOF_POINTER__ > 8
		=0
#endif
	, size32, size64, size128, size256, size512,
	size1024, size2048, size4096, size8192, size16384, size32768,
	size65536,
	BIG=26, MIDDLE=28, BASE=30, FREE=1 };
#define CAT(A,B)	A##B
#define XCAT(A,B)	CAT(A,B)

/* number of small (<1 page) block sizes supported */
#define	NUMSMALL	XCAT(size, PAGESIZE)
#define LOG2PAGESIZE	(NUMSMALL+(8-size256))
#define SIZE(l)		((1 << (8-size256)) << (l))
#define PERPAGE(l)	((PAGESIZE/(1 << (8-size256))) >> (l))

struct page {			/* descriptor for a page */
    unsigned		page;	/* page number of next page with same chunksize
    				 * for small chunk pages.
				 * page number after end of extent for BIG
				 * page number of start of extent for MIDDLE */
    unsigned		free:11;/* offset of first free chunk on page.
    				 * 0 for non small chunk pages */
    int			count:12;/* number of free chunks on page.
    				 * 0 for non small chunk pages */
    unsigned		code:8;	/* code describing size of objects on page
                                 * <BIG, page is broken down into chunks of the
				 *       corresponding size from the enum; at
				 *       least one chunk is in use
				 * BIG, first page in extent of 1 or more pages
				 * MIDDLE, non-first page in extent of 2+ pages
				 * FREE, added to BIG/MIDDLE for free extents
				 * BASE, holds struct page objects of pages in
				 *       in the pool or refs to other BASE */
    /* using a 32-bit page index here limits the pool to 4G pages (16TB with
     * 4K pages).  We can shave bits from free/count/code to allow larger
     * indexes and thus a bigger pool.  'free' needs to be
     * log2(PAGESIZE/__SIZEOF_POINTER__) bits, while 'count' needs to be 1 bit
     * larger for the sign.  'code' needs only 5 bits.  So with 8K pages on a
     * 64 bit machine, we could shave 6 bits to add to 'page' -- 2PB max */
    };

struct freepage {		/* descriptor for completely free page extent */
    struct freepage	**parent; /* pointer to this descriptor */
    struct freepage	*bigger;/* next larger free extent */
    struct freepage	*next;	/* next same size free extent */
    int			size;	/* number of pages in extent */
    };

struct chunk {
    struct chunk	*next;
    };

struct basepage {
    char		magic[4];	/* "SHM " */
    unsigned char	param[4];	/* param[0] = version (0)
    					 * param[1] = wordsize (sizeof(void *))
    					 * param[2] = LOCKTYPE + debug
					 * param[3] = NUMSMALL */
    void		*base;		/* base address expected to load at */
    struct page		**pages;
    struct freepage	*freepages;
    void		*end;
    unsigned 		freechunks[NUMSMALL];
#ifdef SHM
    volatile int	init;		/* set to 1 when init complete */
    void		*brk;		/* where the shm brk is */
    void		*eof;		/* end of the shm file */
    void		*global;	/* user global pointer */
#endif /* SHM */
#if defined(LOCKTYPE) && LOCKTYPE == SYSVSEM
    key_t		semkey;		/* semaphore key */
#endif /* SYSVSEM */
#if defined(LOCKTYPE) && LOCKTYPE == SPINLOCK
    volatile TAS_t	locks[NUMSMALL+1];	/* spinlocks */
#endif /* SPINLOCK */
#if defined(LOCKTYPE) && LOCKTYPE == PMUTEX
    pthread_mutex_t	locks[NUMSMALL+1];
#endif /* PMUTEX */
#ifdef SHM
    char		mfile[256];	/* actually, all the rest of the page*/
#endif /* SHM */
    };

struct localfree {
    struct chunk	*free, *aux;
    unsigned short	count, target;
    };

extern void *malloc(size_t), *realloc(void *, size_t), free(void *),
	    *calloc(size_t, size_t);
extern void *malloc_small(int);	/* parameter is bucket number < NUMSMALL */
extern void *valloc(size_t);	/* round up to page, page aligned */
    
#define SMLIST(sz)					\
 ((sz)<= 64 ? sizeof(void *)<=8 && (sz)<=8		\
		 ? sizeof(void*)<=4 && (sz)<=4 ? size4	\
			                       : size8	\
	    : (sz)<= 16 ? size16			\
	    : (sz)<= 32 ? size32			\
	    : size64					\
: (sz)<=512 ? (sz)<=128 ? size128		 	\
	    : (sz)<=256 ? size256			\
	    : size512					\
: PAGESIZE > 1024 && (sz) <= 1024 ? size1024		\
: PAGESIZE > 2048 && (sz) <= 2048 ? size2048		\
: PAGESIZE > 4096 && (sz) <= 4096 ? size4096		\
: PAGESIZE > 8192 && (sz) <= 8192 ? size8192		\
: PAGESIZE > 16384 && (sz) <= 16384 ? size16384		\
: PAGESIZE > 32768 && (sz) <= 32768 ? size32768		\
: -1 )
/* use the MALLOC macro with a CONSTANT argument for fast mallocs, less than
** half a page.  Will crash if greater than half a page.  No speed advantage
** if the argument is not constant */
#ifndef MALLOC_DEBUG
#define MALLOC(sz)	malloc_small(SMLIST(sz))
#else
#define MALLOC(sz)	(assert((sz) <= PAGESIZE/2), malloc(sz))
#endif

#endif /* _malloc_h_ */
