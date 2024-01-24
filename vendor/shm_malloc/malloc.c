#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>

#ifdef SHM
#define	malloc		shm_malloc
#define realloc		shm_realloc
#define free		shm_free
#define	calloc		shm_calloc
#define malloc_small	shm_malloc_small
#define valloc		shm_valloc
#define sbrk		shm_sbrk
#define brk		shm_brk
#define minit		abort
#define mresize		shm_mresize
#define msize		shm_msize
#define heapdump	shm_heapdump
#else
#ifdef INDIRECT
#define	malloc		_malloc
#define realloc		_realloc
#define free		_free
#define	calloc		_calloc
#define valloc		_valloc
#define mresize		_mresize
#define msize		_msize
#define malloc_small	_malloc_small
#define heapdump	_heapdump
#endif
extern void *sbrk(intptr_t);
extern int brk(void *);
#endif

#define _S(x) #x
#define S(x) _S(x)

/* these are the different locking schemes.  The numbers associated with
** them are unimportant; they need only be different */
#define	SYSVSEM		1	/* SysV Semaphores */
#define	FLOCK		2	/* File Locks */
#define SPINLOCK	3	/* atomic test-and-set spinlocks */
#define	PMUTEX		4	/* pthreads mutexes */

#if defined(SHM) || defined(_REENTRANT) || defined(_POSIX_THREADS)
#ifndef LOCKTYPE
#if defined(_POSIX_THREADS) /* && !defined(__CYGWIN__) */
#define LOCKTYPE PMUTEX
#elif  defined(__GNUC__) && (defined(mc68000) || defined(sparc) || \
			     defined(m88k) || defined(__alpha__) || \
			     defined(__ppc__) || defined(__i386__))
#define LOCKTYPE SPINLOCK
#else
#define LOCKTYPE FLOCK
#endif
#endif

#else /* !SHM && !_REENTRANT && !_POSIX_THREADS */

#undef LOCKTYPE

#endif /* SHM || _REENTRANT || _POSIX_THREADS */

#if defined(__CYGWIN__)
/* don't try to use thread-local vars on cygwin */
#define thread_local
#elif defined(__STDC__) && __STDC_VERSION__ >= 199901L
#define thread_local	__thread
#elif defined(__GNUC__) && __GNUC__ >= 4
#define thread_local	__thread
#else
#define thread_local
#endif

#include "malloc.h"

#if defined(__GNUC__) && (defined(__x86_64__) || defined(__i386__))
#undef SMLIST
static inline int SMLIST(int sz) {
    int rv;
    asm("bsr %1,%0" : "=r"(rv) : "r"((sz-1)|1));
    rv -= 7-size256;
    if (rv < 0) rv = 0;
    if (rv >= NUMSMALL) rv = -1;
    return rv;
}
#endif

#ifdef SHM
#include <sys/mman.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>

struct basepage * const membase =
#if __SIZEOF_POINTER__ == 8
#  define	membase		((struct basepage *)0x1000000000L)
#else
# if defined(sun)
#  define	membase		((struct basepage *)0xe0000000)
# elif defined(sgi)
#  define	membase		((struct basepage *)0x08000000)
# elif defined(_AIX)
#  define	membase		((struct basepage *)0x40000000)
# elif defined(__FreeBSD__)
#  define	membase		((struct basepage *)0x10000000)
# elif defined(__hpux__)
#  define	membase		((struct basepage *)0xa0000000)
# elif defined(__CYGWIN__)
#  define	membase		((struct basepage *)0x40000000)
# else
#  define	membase		((struct basepage *)0x80000000)
# endif
#endif
membase;

/* minimum number of additional pages to mmap when expanding the heap */
#define	MMAP_INCR	16

static void		*localbrk;
static int		mfd;

#else /* !SHM */

static struct basepage	*membase;

#endif /* SHM */

#if defined(SHM) || defined(_REENTRANT) || defined(_POSIX_THREADS)
#if LOCKTYPE == SYSVSEM
#if defined(_AIX) || defined(__osf__)
/* AIX and OSF/1 have eliminated union semun, but are otherwise compatable */
union semun {
    int                 val;
    struct semid_ds     *buf;
    ushort              *array;
};
#endif /* _AIX || __osf__ */

static int		semid;
static struct sembuf	sembuf;

#define FIRSTKEY	1	/* first semaphore key to try */
static int lock_init(int init)
{
    if (init) {
	int um = umask(0); umask(um);
	um = ~um & 0777;
	membase->semkey = FIRSTKEY;
	while ((semid = semget(membase->semkey, NUMSMALL+1,
			       IPC_CREAT|IPC_EXCL|um)) < 0 &&
	       errno == EEXIST)
	    membase->semkey++;
	if (semid >= 0) {
	    ushort arr[NUMSMALL+1];
	    int i;
	    union semun semu;
	    semu.array = arr;
	    for (i = 0; i<=NUMSMALL; i++)
		arr[i] = 1;
	    if (semctl(semid, 0, SETALL, semu) < 0) {
		semctl(semid, 0, IPC_RMID, semu);
		return -1; } } }
    else
	semid = semget(membase->semkey, 0, 0);
    return (semid < 0) ? -1 : 0;
}
#define	LOCK(q)	do { \
	sembuf.sem_num = q < NUMSMALL ? q : NUMSMALL;	\
	sembuf.sem_op = -1;				\
	sembuf.sem_flg = 0;				\
	while (semop(semid, &sembuf, 1)<0)		\
	    assert(errno == EINTR); } while(0)
#define UNLOCK(q)	do { \
	sembuf.sem_num = q < NUMSMALL ? q : NUMSMALL;	\
	sembuf.sem_op = 1;				\
	sembuf.sem_flg = 0;				\
	while (semop(semid, &sembuf, 1)<0)		\
	    assert(errno == EINTR); } while(0)
#define LOCK_FINI
#define LOCK_DESTROY do { \
	union semun semu;				\
	semu.val = 0;					\
	semctl(semid, 0, IPC_RMID, semu); } while(0)
#endif /* SYSVSEM */

#if LOCKTYPE == FLOCK
static int		lfd;
static struct flock	lock;

static int lock_init(int init)
{
char	lfile[1024];

    strcpy(lfile, membase->mfile);
    strcat(lfile, ".lock");
    lock.l_whence = SEEK_SET;
    lock.l_len = 1;
    if (!init) {
	if ((lfd = open(lfile, O_RDWR, 0)) < 0) return -1;
    } else if ((lfd = open(lfile, O_RDWR|O_CREAT, 0666)) < 0)
	return -1;
    else
	ftruncate(lfd, lfile, NUMSMALL+1);
    fcntl(lfd, F_SETFD, FD_CLOEXEC);
    return 0;
}
#define	LOCK(q)	do { \
	lock.l_type = F_WRLCK;				\
	lock.l_start = (q);				\
	while (fcntl(lfd, F_SETLKW, &lock) < 0)		\
	    assert(errno == EINTR); } while(0)
#define UNLOCK(q)	do { \
	lock.l_type = F_UNLCK;				\
	lock.l_start = (q);				\
	while (fcntl(lfd, F_SETLK, &lock) < 0)		\
	    assert(errno == EINTR); } while(0)
#define LOCK_FINI	close(lfd)
#define LOCK_DESTROY do { \
	char	lfile[1024];				\
	strcpy(lfile, membase->mfile);			\
	strcat(lfile, ".lock");				\
	unlink(lfile);					\
	close(lfd); } while(0)
#endif /* FLOCK */

#if LOCKTYPE == SPINLOCK
#include <sys/time.h>
static int lock_init(int init)
{
    if (init) {
	int i;
	for (i=NUMSMALL; i>=0; i--)
	    membase->locks[i] = 0; }
    return 0;
}
#define	LOCK(q) do { \
	volatile TAS_t *_l = &membase->locks[q];	\
	int _try = 10;					\
	while (_try > 0 && (*_l || TAS(*_l))) _try--;	\
	if (!_try) while (*_l || TAS(*_l)) {		\
	    struct timeval to = { 0, 1000 };		\
	    select(0, 0, 0, 0, &to); }			\
	MEMORY_BARRIER;					\
	} while(0)
#define UNLOCK(q) do { \
	MEMORY_BARRIER;					\
	membase->locks[q] = 0;				\
	} while(0)
#define LOCK_FINI
#define LOCK_DESTROY
#endif /* SPINLOCK */

#if LOCKTYPE == PMUTEX
static int lock_init(int init)
{
    if (init) {
	int i;
	for (i=NUMSMALL; i>=0; i--)
	    pthread_mutex_init(&membase->locks[i], 0); }
    return 0;
}

#define LOCK(q)		pthread_mutex_lock(&membase->locks[q])
#define UNLOCK(q)	pthread_mutex_unlock(&membase->locks[q])
#define LOCK_FINI
#define LOCK_DESTROY
#endif /* PMUTEX */

#else /* !SHM && !_REENTRANT && !_POSIX_THREADS */

#define	LOCK(q)
#define UNLOCK(q)
static int lock_init()
{
    return 0;
}

#endif /* SHM || _REENTRANT || _POSIX_THREADS */

typedef	unsigned long	U;

#define TARGET(l)	(2 << ((NUMSMALL-1 - (l))/2))
#define PAGENUM(p)	(((U)(p) - (U)membase) / PAGESIZE)
#define PAGEADDR(n)	((void *)((U)membase + (U)(n) * PAGESIZE))
#define PAGEBASE(p)	((U)p & ~(PAGESIZE-1))
#define I2(pn)		((pn) % (PAGESIZE/sizeof(struct page)))
#define I1(pn)		((pn) / (PAGESIZE/sizeof(struct page)))
#define ADDR2PAGE(p)	(&membase->pages[I1(PAGENUM(p))][I2(PAGENUM(p))])
#define NUM2PAGE(n)	(&membase->pages[I1(n)][I2(n)])
#define VALID(p)	(((U)(p) > (U)membase) && ((U)(p) < (U)membase->end))
#define FREEPAGE(n)	((struct freepage *)PAGEADDR(n))

#ifdef MALLOC_DEBUG
static unsigned long lcrng(unsigned long s)
{
unsigned long long	mod = (1LL<<31) - 1;
unsigned long long      t = s * 16807LL;

    t = (t&mod) + (t>>31);
    if (t>mod) t -= mod;
    return t;
}   

#define GUARD	0xa1962f8dU
#define	DB(code)	code
#else /* !MALLOC_DEBUG */
#define DB(code)
#endif /* MALLOC_DEBUG */

static inline int pcmp(unsigned _a, unsigned _b)
{
struct page	*a = NUM2PAGE(_a), *b = NUM2PAGE(_b);
int		v;

    v = a->count - b->count;
    return v ? v : (long)_a - (long)_b;
}

#if 0
/*
 * FIXME -- profile this sorter and maybe choose a better one?
 * FIXME -- this pivot choice is pessimal for a reversed list, but very
 * FIXME -- good (O(n)) for almost sorted lists, which should be our
 * FIXME -- common case.  Probably not a big deal as the lists should
 * FIXME -- rarely be big
 * FIXME -- we're also assuming the optimizer will do a good job CSEing
 * FIXME -- these NUM2PAGE macros after inlining pcmp
 *
 * This algorithm has very bad behavior with a list that is sorted except
 * for the last element, which turns out to be a somewhat common case here.
 *
 * Quicksort with last-sorted pivot
 */
unsigned page_list_sort(unsigned p, unsigned **tail)
{
unsigned a, *a_tail, b, *b_tail, pivot;

    if (!p) return p;
    pivot = a = p;
    a_tail = &a;
    p = NUM2PAGE(p)->page;
    while (p) {
	if (pcmp(pivot, p) > 0) break;
	a_tail = &NUM2PAGE(pivot)->page;
	pivot = p;
	p = NUM2PAGE(p)->page; }
    if (!p) {
	if (tail) *tail = &NUM2PAGE(pivot)->page;
	return a; }
    b_tail = &b;
    while (p) {
	if (pcmp(pivot, p) > 0) {
	    *a_tail = p;
	    a_tail = &NUM2PAGE(p)->page; }
	else {
	    *b_tail = p;
	    b_tail = &NUM2PAGE(p)->page; }
	p = NUM2PAGE(p)->page; }
    *a_tail = 0;
    *b_tail = 0;
    if (a) a = page_list_sort(a, &a_tail);
    if (b) b = page_list_sort(b, &b_tail);
    *a_tail = pivot;
    NUM2PAGE(pivot)->page = b;
    if (tail)
	*tail = b ? b_tail : &NUM2PAGE(pivot)->page;
    return a;
}
#else
/*
 * FIXME -- profile this sorter and maybe choose a better one?
 *
 * simple split/merge sort */
unsigned page_list_sort(unsigned p)
{
    unsigned a, b, *t;
    int asort = 0;

    if (!p) return p;
    a = b = p;
    b = NUM2PAGE(b)->page;
    if (!b) return p;
    while (b) {
	if (!(b = NUM2PAGE(b)->page)) break;
	unsigned l = a;
	a = NUM2PAGE(a)->page;
	if (!asort && pcmp(l, a) > 0)
	    asort = 1;
	b = NUM2PAGE(b)->page; }
    b = page_list_sort(NUM2PAGE(a)->page);
    NUM2PAGE(a)->page = 0;
    a = p;
    if (asort) a = page_list_sort(a);
    t = &p;
    while (a && b) {
	if (pcmp(a, b) <= 0) {
	    *t = a;
	    t = &NUM2PAGE(a)->page;
	    a = *t;
	} else {
	    *t = b;
	    t = &NUM2PAGE(b)->page;
	    b = *t; } }
    *t = a | b;
    return p;
}
#define page_list_sort(p, t) page_list_sort(p)
#endif

static thread_local struct localfree freelists[NUMSMALL];
#ifdef MALLOC_DEBUG
static thread_local struct backup {
    struct backup	*next;
    struct chunk	*item;
    } *backupfree[NUMSMALL], *backupaux[NUMSMALL], *spare;

static void tbackup(int i)
{
struct chunk	*p;
struct backup	*q;

    for (p=freelists[i].free, q=backupfree[i]; p && q; p=p->next, q=q->next)
	if (p != q->item) {
	    printf("***"S(free)" list for size %d corrupted\n", SIZE(i));
	    abort(); }
    if (p || q) {
	printf("***"S(free)" list for size %d corrupted\n", SIZE(i));
	abort(); }
    for (p=freelists[i].aux, q=backupaux[i]; p && q; p=p->next, q=q->next)
	if (p != q->item) {
	    printf("***"S(free)" list for size %d corrupted\n", SIZE(i));
	    abort(); }
    if (p || q) {
	printf("***"S(free)" list for size %d corrupted\n", SIZE(i));
	abort(); }
}

static struct backup *balloc()
{
struct backup	*p;
int		i;

    if (!spare) {
	p = valloc(PAGESIZE);
	i = PAGESIZE/sizeof(struct backup) - 1;
	p[i].next = 0;
	for (i--; i>=0; i--)
	    p[i].next = &p[i+1];
	spare = p; }
    p = spare;
    spare = p->next;
    return p;
}

static void bfree(struct backup *p)
{
    p->next = spare;
    spare = p;
}

static void *gcheck(void *_b)
{
    U *b = _b;
    if (b) {
	b -= 2;
	if(b[0] != GUARD || b[1] != lcrng((U)b)) {
	    printf("***guard corrupted at %p\n", b);
	    abort(); } }
    return b;
}

static void *gsetup(void *_b)
{
    U *b = _b;
    if (b) {
	*b++ = GUARD;
	*b++ = lcrng((U)_b); }
    return b;
}
#endif /* MALLOC_DEBUG */

void *malloc(size_t size)
{
int	sc;
void	*rv;

    DB( size += 2*sizeof(U); )
    sc = SMLIST(size);
    if (sc >= 0)
	rv = malloc_small(sc);
    else
	rv = valloc(size);
    DB( rv = gsetup(rv); )
    return rv;
}

static void msetup()
{
    memset(membase, 0, 3 * PAGESIZE);
    memcpy(membase->magic, "SHM ", 4);
    membase->param[0] = 0;
    membase->param[1] = sizeof(void *);
#ifdef LOCKTYPE
    membase->param[2] = LOCKTYPE;
#endif
#ifdef MALLOC_DEBUG
    membase->param[2] |= 0x80;
#endif
    membase->param[3] = NUMSMALL;
    membase->base = membase;
    membase->pages = (struct page **)((U)membase + PAGESIZE);
    membase->end = (void *)((U)membase + PAGESIZE*3);
    membase->pages[0] = (struct page *)((U)membase + PAGESIZE*2);
    membase->pages[0][0].code = BASE;
    membase->pages[0][1].code = BASE;
    membase->pages[0][2].code = BASE;
}

#ifdef SHM
static int msetup_valid()
{
    if (memcmp(membase->magic, "SHM ", 4)) return 0;
    if (membase->param[0] != 0) return 0;
    if (membase->param[1] != sizeof(void *)) return 0;
    if ((membase->param[2] & 0x7f) != LOCKTYPE) return 0;
#ifdef MALLOC_DEBUG
    if (!(membase->param[2] & 0x80)) return 0;
#else
    if (membase->param[2] & 0x80) return 0;
#endif
    if (membase->param[3] != NUMSMALL) return 0;
    if (membase->base != membase) return 0;
    return 1;
}
#endif

#ifndef SHM
static void minit()
{
U	p;

    p = (U)sbrk(0);
    if (p%PAGESIZE) {
	sbrk(PAGESIZE - p%PAGESIZE);
	p = (U)sbrk(0); }
    assert(p%PAGESIZE == 0);

    membase = (struct basepage *)p;
    sbrk(PAGESIZE * 3);
    msetup();
    lock_init(1);
}

#ifdef WINNT
int brk(void *p)
{
void	*op = sbrk(0);

    return (int)sbrk((int)p - (int)op);
}
#endif /* WINNT */

#else /* SHM */

#ifdef __CYGWIN__

/* Cygwin's mmap can't deal with multiple partial mappings of a file, so
 * in order to map more of our shared mem file, we need to unmap what we
 * have mapped and then remap the whole thing as one chunk.  This doesn't
 * work for anonymous mapping (we'd lose what was previously mapped), so
 * we always do them in multiples of 64K which seems to work out ok */

static void *cygwin_mmap(void *addr, size_t length, int prot, int flags,
		  int fd, off_t offset)
{
    if (fd >= 0 && addr != membase) {
	munmap(membase, offset);
	length += offset;
	addr = membase;
	offset = 0;
    } else if (fd < 0) {
	/* how much was already mapped by a previous mmap */
	size_t done = -(intptr_t)addr & 0xffff;
	if (length <= done)
	    return addr;
	addr = (char *)addr + done;
	length -= done;
	/* round up to 64K */
	length |= 0xffff;
	length++;
	offset = 0; /* should be ignored by mmap */
    }
    return mmap(addr, length, prot, flags, fd, offset);
}

#define mmap	cygwin_mmap

#endif /* __CYGWIN__ */

static struct sigaction oldsegv;

static void shm_segv()
{
void	*newbrk;
int	flags = MAP_SHARED|MAP_FIXED;

    /* if a SEGV occurred and there's new memory to be mapped, map it
    ** and retry */
    if (mfd < 0) flags |= MAP_ANONYMOUS;
    newbrk = membase->eof;
    if (newbrk > localbrk) {
	if (mfd >= 0) lseek(mfd, 0, SEEK_SET);
	mmap(localbrk, newbrk - localbrk, PROT_READ|PROT_WRITE,
	     flags, mfd, localbrk - (void *)membase);
	localbrk = newbrk; }
    else {
	/* no more to map, must be a real SEGV */
	sigaction(SIGSEGV, &oldsegv, 0); }
}

int shm_destroy()
{
    LOCK_DESTROY;
    unlink(membase->mfile);
    munmap(membase, localbrk - (void *)membase);
    close(mfd);
    return 0;
}

int shm_init(const char *mfile, void (*init_fn)())
{
int			tmp, wait = 5;
int			flags = MAP_SHARED|MAP_FIXED;
struct sigaction	segv;

    mfd = -1;
    if (!mfile) flags |= MAP_ANONYMOUS;
    while(mfd == -1) {
	if (mfile && (mfd = open(mfile, O_RDWR, 0)) >= 0) {
	    /* make sure the file isn't empty */
	    while (read(mfd, &tmp, sizeof(tmp)) == 0) {
		if (wait-- < 0) {
		    close(mfd);
		    errno = EINVAL;
		    return -1; }
		sleep(1); }
	    lseek(mfd, 0, SEEK_SET);
	    if ((long)mmap(membase, PAGESIZE, PROT_READ|PROT_WRITE,
			   flags, mfd, 0) == -1) {
		close(mfd);
		return -1; }
	    /* wait until initialization is complete */
	    while (!membase->init && wait-- > 0) sleep(1);
	    if (!membase->init || !msetup_valid()) {
		munmap(membase, PAGESIZE);
		close(mfd);
		errno = EINVAL;
		return -1; }
	    localbrk = membase->eof;
	    lseek(mfd, 0, SEEK_SET);
	    if ((long)mmap((void *)membase + PAGESIZE,
			   (localbrk - (void *)membase) - PAGESIZE,
			   PROT_READ|PROT_WRITE, flags, mfd, PAGESIZE) == -1) {
		close(mfd);
		return -1; } }
	else if (!mfile || (errno == ENOENT &&
		 (mfd = open(mfile, O_RDWR|O_CREAT|O_EXCL, 0666)) >= 0)) {
	    if (mfd >= 0) {	    
		if (ftruncate(mfd, 3*PAGESIZE) < 0) {
		    close(mfd);
		    return -1; }
		lseek(mfd, 0, SEEK_SET); }
	    if ((long)mmap(membase, 3*PAGESIZE, PROT_READ|PROT_WRITE,
			   flags, mfd, 0) == -1) {
		close(mfd);
		return -1; }
	    msetup();
	    localbrk = membase->brk = membase->eof = membase->end;
	    strcpy(membase->mfile, mfile ? mfile : "");
	    membase->global = 0;
	    break; }
	else if (errno != EEXIST)
	    return -1; }
    fcntl(mfd, F_SETFD, FD_CLOEXEC);
    if (lock_init(!membase->init) < 0) {
	munmap(membase, localbrk - (void *)membase);
	close(mfd);
	return -1; }
    if (!membase->init && init_fn)
	init_fn();
    segv.sa_flags = 0;
    sigemptyset(&segv.sa_mask);
    segv.sa_handler = shm_segv;
    sigaction(SIGSEGV, &segv, &oldsegv);
    membase->init = 1;
    return 0;
}

static void flush_to_global_freelist(int, struct chunk *, struct chunk *);

/* flush out local free lists, so we can exit leaving memory consistent */
int shm_fini()
{
int	l;

    for (l=0; l<NUMSMALL; l++) {
	if (freelists[l].aux || freelists[l].free)
	    flush_to_global_freelist(l, freelists[l].free, freelists[l].aux);
	freelists[l].aux = freelists[l].free = 0;
	freelists[l].count = 0; }
    //munmap(membase, localbrk - (void *)membase);
    //close(mfd);
    LOCK_FINI;
    return 0;
}

/* clear all the free lists, as they really belong to the parent */
int shm_child()
{
int	l;

    for (l=0; l<NUMSMALL; l++)
	freelists[l].aux = freelists[l].free = 0;
    return 0;
}

static int shm_brk(void *newbrk)
{
char 	tmp = 0;
int	flags = MAP_SHARED|MAP_FIXED;

    if (mfd < 0) flags |= MAP_ANONYMOUS;
    if (newbrk <= membase->brk) {
	if (ftruncate(mfd, newbrk - (void *)membase) < 0)
	    return -1;
	if (newbrk < membase->eof)
	    munmap(newbrk, membase->eof - newbrk);
	membase->brk = membase->eof = localbrk = newbrk; }
    else if (newbrk <= membase->eof) {
	membase->brk = newbrk;
	if (newbrk > localbrk) {
	    if (mfd >= 0) lseek(mfd, 0, SEEK_SET);
	    if ((long)mmap(localbrk, membase->eof - localbrk,
			   PROT_READ|PROT_WRITE, flags, mfd,
			   localbrk - (void *)membase) == -1)
		return -1;
	    localbrk = membase->eof; } }
    else {
	void *neweof = membase->brk + PAGESIZE * MMAP_INCR;
	if (newbrk > neweof)
	    neweof = newbrk;
	if (mfd >= 0) {
	    if (ftruncate(mfd, neweof - (void *)membase) < 0)
		return -1;
	    if (lseek(mfd, neweof - (void *)membase - 1, SEEK_SET) < 0)
		return -1;
	    if (write(mfd, &tmp, 1) != 1)
		return -1;
	    lseek(mfd, 0, SEEK_SET); }
	membase->eof = neweof;
	if ((long)mmap(localbrk, neweof - localbrk,
		       PROT_READ|PROT_WRITE, flags, mfd,
		       localbrk - (void *)membase) == -1)
	    return -1;
	localbrk = neweof;
	membase->brk = newbrk; }
    return 0;
}

static void *shm_sbrk(int delta)
{
void	*oldbrk = membase->brk;

    return shm_brk(membase->brk + delta) < 0 ? (void *)-1 : oldbrk;
}

void *shm_global()
{
    return membase->global;
}

void shm_set_global(void *v)
{
    membase->global = v;
}

#endif /* SHM */

/*
** The free page list contains all the entirely free pages.  It is organized
** as a `list of lists' with blocks of the same size in the same list.
** the lists are sorted order of size (smallest first), and each list is
** sorted in memory order (lowest address first)
*/

#ifdef MALLOC_DEBUG
/* check the global freepage lists to ensure consistency, and ensure that
 * 'p' is present (free) on there */
static void fp_verify(struct freepage *p)
{
struct freepage	*t1, *t2;
struct page	*pp;
int		i;

    if (membase->freepages && (!VALID(membase->freepages) ||
		   membase->freepages->parent != &membase->freepages)) {
	printf("***"S(free)"list corrupt (base table)\n");
	abort(); }
    for (t1=membase->freepages; t1; t1 = t1->bigger) {
	if (t1->bigger && (!VALID(t1->bigger) ||
			   t1->size >= t1->bigger->size ||
			   t1->bigger->parent != &t1->bigger)) {
	    printf("***"S(free)"list corrupt (page %p ?)\n", t1);
	    abort(); }
	for (t2=t1; t2; t2 = t2->next) {
	    if (p == t2) p = 0;
	    if (t2->next && (!VALID(t2->next) || t2->next->bigger ||
			     t2->size != t2->next->size ||
			     t2->next->parent != &t2->next)) {
		printf("***"S(free)"list corrupt (page %p ?)\n", t2);
		abort(); }
	    pp = ADDR2PAGE(t2);
	    if (pp->code != BIG+FREE ||
		PAGEADDR(pp->page - t2->size) != (void *)t2)
	    {
		printf("***page tables corrupt (page %p)\n", t2);
		abort(); }
	    for (i=1; i<t2->size; i++) {
		struct page *ip = NUM2PAGE(PAGENUM(t2) + i);
		if (ip->code != MIDDLE || PAGEADDR(ip->page) != (void *)t2) {
		    printf("***page tables corrupt (page %p)\n",
			   (char *)t2 + i*PAGESIZE);
		    abort(); } } } }
    if (p) {
	printf("***apparently free page %p not on "S(free)"list\n", p);
	abort(); }
}
#else  /* !MALLOC_DEBUG */
#define fp_verify(p)
#endif /* MALLOC_DEBUG */

static void fp_remove(struct freepage *p)
{
    fp_verify(p);
    if (p->next) {
	(*p->parent) = p->next;
	p->next->parent = p->parent;
	if ((p->next->bigger = p->bigger))
	    p->bigger->parent = &p->next->bigger; }
    else {
	if (((*p->parent) = p->bigger))
	    p->bigger->parent = p->parent; }
}

static void fp_add(struct freepage *p)
{
struct freepage	**t = &membase->freepages;

    fp_verify(0);
    while (*t && (*t)->size < p->size)
	t = &(*t)->bigger;
    if (*t && (*t)->size == p->size) {
	while (*t && (U)*t < (U)p)
	    t = &(*t)->next;
	if ((p->next = (*t))) {
	    if ((p->bigger = p->next->bigger)) {
		p->bigger->parent = &p->bigger;
		p->next->bigger = 0; }
	    p->next->parent = &p->next; }
	else
	    p->bigger = 0; }
    else {
	p->next = 0;
	if ((p->bigger = (*t)))
	    p->bigger->parent = &p->bigger; }
    *t = p;
    p->parent = t;
}

static struct freepage *fp_find(U size)
{
struct freepage *t;

    fp_verify(0);
    for (t=membase->freepages; t && t->size < (int)size; t = t->bigger);
    if (t) fp_remove(t);
    return t;
}

void *malloc_small(int l)
{
struct chunk	*new;

    if (!membase) minit();
    assert(l >= SMLIST(sizeof(void *)) && l < NUMSMALL);
    DB(tbackup(l));
    if (!freelists[l].free) {
	if (freelists[l].aux) {
	    freelists[l].free = freelists[l].aux;
	    freelists[l].aux = 0;
	    DB(backupfree[l] = backupaux[l]);
	    DB(backupaux[l] = 0); }
	else {
	    int			i;
	    struct chunk	*new_fl = 0;
	    if (!freelists[l].target)
		freelists[l].target = TARGET(l);
	    LOCK(l);
	    for (i=freelists[l].target; i; i--) {
		unsigned	pn;
		struct page	*p;
		if (!(pn = membase->freechunks[l])) {
		    int		j;
		    if (!(new = valloc(PAGESIZE))) {
			UNLOCK(l);
			return 0; }
		    pn = PAGENUM(new);
		    p = ADDR2PAGE(new);
		    p->code = l;
		    p->count = j = PERPAGE(l);
		    p->free = 0;
		    p->page = 0;
		    while (--j) {
			struct chunk *prev = new;
			new = (struct chunk *)((U)new + SIZE(l));
			prev->next = new; }
		    new->next = 0;
		    membase->freechunks[l] = pn; }
		p = NUM2PAGE(pn);
		new = (struct chunk *)((U)PAGEADDR(pn) + p->free*SIZE(l));
		if (new->next)
		    p->free = ((U)new->next - (U)PAGEADDR(pn))/SIZE(l);
		else {
		    p->free = 0;
		    assert(p->count == 1); }
		if (!--p->count) {
		    assert(p->free == 0);
		    membase->freechunks[l] = p->page; }
		new->next = new_fl;
		new_fl = new; }
	    freelists[l].free = new_fl;
	    DB({struct chunk	*p;
		struct backup	**q;
		for (p=new_fl, q=&backupfree[l]; p; p=p->next, q=&(*q)->next) {
		    *q = balloc();
		    (*q)->item = p; }
		*q = 0; });
	    UNLOCK(l); }
	freelists[l].count = freelists[l].target; }
    new = freelists[l].free;
    freelists[l].free = new->next;
    DB({struct backup *tmp = backupfree[l];
	backupfree[l] = tmp->next;
	bfree(tmp); });
    freelists[l].count--;
    DB(tbackup(l));
    return (void *)new;
}

/* allocate 'size' pages without expanding the heap.
 * Return 0 if that's not possible
 * must hold LOCK(NUMSMALL) before calling */
static void *alloc_pages(int size)
{
    unsigned	i;
    void *p = fp_find(size);
    if (p) {
	unsigned pn = PAGENUM(p);
	struct page *pg = NUM2PAGE(pn);
	pg->code = BIG;
	if (pg->page - pn > (int)size) {
	    unsigned extra = pn + size;
	    struct page *extrapg = NUM2PAGE(extra);
	    extrapg->code = BIG+FREE;
	    extrapg->page = pg->page;
	    FREEPAGE(extra)->size = i = pg->page - extra;
	    while (--i)
		NUM2PAGE(extra + i)->page = extra;
	    fp_add(FREEPAGE(extra)); } }
    return p;
}

/* Free a block of one or more pages, without shrinking the heap.
 * Coalesce with adjacent free block and return the resulting (possibly
 * larger) free block
 * Must hold LOCK(NUMSMALL) before calling. */
static struct freepage *free_pages(void *p)
{
    unsigned	i, adj;
    struct page *pg = ADDR2PAGE(p), *adjpg;
    struct freepage *fpage = p;
    assert(pg->code == BIG);
    pg->code = BIG+FREE;
    adj = PAGENUM(p)-1;
    adjpg = NUM2PAGE(adj);
    if (adjpg->code == MIDDLE) {
	adj = adjpg->page;
	adjpg = NUM2PAGE(adj); }
    if (adjpg->code == BIG+FREE) {
	fpage = FREEPAGE(adj);
	fp_remove(fpage);
	adjpg->page = pg->page;
	pg->code = MIDDLE;
	for (i = PAGENUM(p); i < adjpg->page; i++)
	    NUM2PAGE(i)->page = adj;
	pg = adjpg;
	fpage->size = adjpg->page - adj;
    } else
	fpage->size = pg->page - PAGENUM(p);
    if (PAGEADDR(pg->page) < membase->end) {
	adj = pg->page;
	adjpg = NUM2PAGE(adj);
	if (adjpg->code == BIG+FREE) {
	    fp_remove(FREEPAGE(adj));
	    adjpg->code = MIDDLE;
	    pg->page = adjpg->page;
	    for (i = adj; i < pg->page; i++)
		NUM2PAGE(i)->page = PAGENUM(fpage);
	    fpage->size = pg->page - PAGENUM(fpage); } }
    fp_add(fpage);
    return fpage;
}

/* Initialize the page descriptors for an extent of memory that is in use.
 * Must hold LOCK(NUMSMALL) before calling. */
static void setup_extent_descriptor(void *p, int size)
{
    struct page *pg = ADDR2PAGE(p);
    pg->page = PAGENUM(p) + size;
    pg->code = BIG;
    while (--size > 0) {
	pg = NUM2PAGE(PAGENUM(p)+size);
	pg->page = PAGENUM(p);
	pg->code = MIDDLE; }
}

/* Expand the master page descriptor table to contain descriptors for pages.
 * up to "to".  Must hold LOCK(NUMSMALL) before calling. */
static int expand_page_table(unsigned to)
{
    int i, added_pages = 0, newmastersize = 0;
    unsigned old = PAGENUM(membase->end) - 1;
    void *oldmaster = 0;
    if (PAGENUM(&membase->pages[I1(to)]) != PAGENUM(&membase->pages[I1(old)])) {
	/* FIXME -- there's a race condition here when we resize the top-level
	 * FIXME -- pages table, as everyone accesses it without aquiring a
	 * FIXME -- lock.  So we ensure that the old top-level table remains
	 * FIXME -- valid for awhile after being reallocated.  That way. if
	 * FIXME -- someone is in the middle of accessing it, they'll still
	 * FIXME -- get the right info. as long as they're not delayed */
	struct page **master;
	int oldmastersize = I1(old) / (PAGESIZE/sizeof(struct page *)) + 1;
	newmastersize = I1(to) / (PAGESIZE/sizeof(struct page *)) + 1;
	if (!(master = alloc_pages(newmastersize))) {
	    to += newmastersize;
	    newmastersize = I1(to) / (PAGESIZE/sizeof(struct page *)) + 1;
	    if ((master = sbrk(newmastersize * PAGESIZE)) == (void *)-1)
		return 0;
	    membase->end = (void *)((U)master + newmastersize * PAGESIZE); }
	memcpy(master, membase->pages, oldmastersize * PAGESIZE);
	memset((void *)((U)master + oldmastersize * PAGESIZE), 0,
	       (newmastersize - oldmastersize) * PAGESIZE);
	void *oldmaster = membase->pages;
	membase->pages = master;
	/* remark the old master as a generic extent, so we can free it */
	setup_extent_descriptor(oldmaster, oldmastersize); }
    for (i = I1(old)+1; i <= I1(to); i++) {
	assert(membase->pages[i] == 0);
	if ((membase->pages[i] = alloc_pages(1))) {
	    ADDR2PAGE(membase->pages[i])->code = BASE;
	} else {
	    if ((membase->pages[i] = sbrk(PAGESIZE)) == (void *)-1) {
		if (oldmaster)
		    free_pages(oldmaster);
		return 0; }
	    added_pages++; }
	memset(membase->pages[i], 0, PAGESIZE); }
    membase->end = PAGEADDR(to+1);
    if (newmastersize)
	for (i = 0; i < newmastersize; i++)
	    NUM2PAGE(PAGENUM(membase->pages) + i)->code = BASE;
    if (added_pages) {
	if (!expand_page_table(to+added_pages)) {
	    if (oldmaster)
		free_pages(oldmaster);
	    return 0; }
	for (i = I1(to); added_pages; i--, added_pages--)
	    ADDR2PAGE(membase->pages[i])->code = BASE;
    }
    if (oldmaster)
	free_pages(oldmaster);
    return 1;
}

void *valloc(size_t size)
{
void			*new;

    size = (size + PAGESIZE - 1)/PAGESIZE;	/* size in pages */
    if (!membase) minit();
    LOCK(NUMSMALL);
    if (!(new = alloc_pages(size))) {
	if ((new = sbrk(size * PAGESIZE)) == (void *)-1) {
	    UNLOCK(NUMSMALL);
	    return 0; }
	if ((U)new % PAGESIZE) {
	    if (sbrk(PAGESIZE - (U)new % PAGESIZE) == (void *)-1) {
		if (brk(new)) /* ignore return value */;
		UNLOCK(NUMSMALL);
		return 0; }
	    new += PAGESIZE - (U)new % PAGESIZE; }
	if (I1(PAGENUM(new)+size-1) != I1(PAGENUM(membase->end)-1)) {
	    if (!expand_page_table(PAGENUM(new)+size-1)) {
		if ((U)new > (U)membase->end) {
		    if (brk(new)) /* ignore return value */;
		    UNLOCK(NUMSMALL);
		    return 0; } }
	} else
	    membase->end = new + size*PAGESIZE;
	setup_extent_descriptor(new, size); }
    UNLOCK(NUMSMALL);
    return new;
}

static void flush_to_global_freelist(int l, struct chunk *cp, struct chunk *cp2)
{
struct chunk	*tmp;
struct page	*p;

    LOCK(l);
    if (!cp) {
	cp = cp2;
	cp2 = 0; }
    for (; cp; cp = tmp) {
	if (!(tmp = cp->next)) {
	    tmp = cp2;
	    cp2 = 0; }
	p = ADDR2PAGE(cp);
	cp->next = (void *)(p->count ? PAGEBASE(cp) + p->free*SIZE(l) : 0);
	p->free = ((U)cp - PAGEBASE(cp))/SIZE(l);
	if (!p->count) {
	    p->page = membase->freechunks[l];
	    membase->freechunks[l] = PAGENUM(cp); }
	if (++p->count >= PERPAGE(l)) {
	    p->count = -1; } }
    membase->freechunks[l] =
	page_list_sort(membase->freechunks[l], 0);
    while (membase->freechunks[l] && 
	   (p = NUM2PAGE(membase->freechunks[l]))->count < 0)
    {
	unsigned pn = membase->freechunks[l];
	void *pp = PAGEADDR(pn);
	membase->freechunks[l] = p->page;
	p->code = BIG;
	p->count = 0;
	p->free = 0;
	p->page = pn + 1;
	DB( pp = gsetup(pp); )
	free(pp); }
    UNLOCK(l);
}

void free(void *_old)
{
struct chunk	*old = _old;
struct page	*p;
int		l;
#ifdef MALLOC_DEBUG
struct chunk	*t,*last;
int		i;
#endif /* MALLOC_DEBUG */

    if (!old) return;
#ifdef MALLOC_DEBUG
    if ((U)old < (U)membase || (U)old >= (U)membase->end) {
	printf("***Invalid pointer given to "S(free)" %p\n", old);
	abort(); }
#endif /* MALLOC_DEBUG */
    DB( old = gcheck(old); )
    p = ADDR2PAGE(old);
    if ((l = p->code) < NUMSMALL) {
#ifdef MALLOC_DEBUG
	if(((U)old & (SIZE(l) - 1)) != 0) {
	    printf("***Invalid pointer given to "S(free)" %p\n", old);
	    abort(); }
	for (last=0, t=freelists[l].free, i=0; t; last=t, t=t->next, i++) {
	    if (t == old) {
		printf("***double "S(free)" of %p\n", old);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); }
	    if (!VALID(t) || ADDR2PAGE(t)->code != l) {
		printf("***"S(free)"list corrupt (freelist %d)\n", l);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); }
	    if (i > freelists[l].count) {
		printf("***"S(free)"list corrupt (freelist %d)\n", l);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); } }
	if (i != freelists[l].count) {
	    printf("***"S(free)"list corrupt (freelist %d)\n", l);
	    if (last) printf("   (block at %p ?)\n", last);
	    abort(); }
	for (last=0, t=freelists[l].aux, i=0; t; last=t, t=t->next, i++) {
	    if (t == old) {
		printf("***double "S(free)" of %p\n", old);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); }
	    if (!VALID(t) || ADDR2PAGE(t)->code != l) {
		printf("***"S(free)"list corrupt (auxlist %d)\n", l);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); }
	    if (i > freelists[l].target) {
		printf("***"S(free)"list corrupt (auxlist %d)\n", l);
		if (last) printf("   (block at %p ?)\n", last);
		abort(); } }
	if (i && i != freelists[l].target) {
	    printf("***"S(free)"list corrupt (auxlist %d)\n", l);
	    if (last) printf("   (block at %p ?)\n", last);
	    abort(); }
	if (p->count) {
	    t = (void *)(PAGEBASE(old) + p->free*SIZE(l));
	    for (last=0, i=0; t; last=t, t=t->next, i++) {
		if (t == old) {
		    printf("***double "S(free)" of %p\n", old);
		    if (last) printf("   (block at %p ?)\n", last);
		    abort(); }
		if ((U)t/PAGESIZE != (U)old/PAGESIZE) {
		    printf("***"S(free)"list corrupt (page %p)\n",
			   (void *)((U)old &~ (PAGESIZE-1)));
		    if (last) printf("   (block at %p ?)\n", last);
		    abort(); }
		if (i > p->count) {
		    printf("***"S(free)"list corrupt (page %p)\n",
			   (void *)((U)old &~ (PAGESIZE-1)));
		    if (last) printf("   (block at %p ?)\n", last);
		    abort(); } }
	    if (i != p->count) {
		printf("***"S(free)"list corrupt (page %p)\n",
		       (void *)((U)old &~ (PAGESIZE-1)));
		if (last) printf("   (block at %p ?)\n", last);
		abort(); } }
#endif /* MALLOC_DEBUG */
	DB(tbackup(l));
	if (freelists[l].count == freelists[l].target) {
	    if (freelists[l].aux) {
		struct chunk *tmp = freelists[l].aux;
		freelists[l].aux = 0;
		flush_to_global_freelist(l, tmp, 0);
		DB({struct backup *p;
		    for (p=backupaux[l]; p->next; p=p->next);
		    p->next = spare;
		    spare = backupaux[l];
		    backupaux[l] = 0; }) }
	    freelists[l].aux = freelists[l].free;
	    freelists[l].free = 0;
	    DB(backupaux[l] = backupfree[l]);
	    DB(backupfree[l] = 0);
	    freelists[l].count = 0; }
	old->next = freelists[l].free;
	freelists[l].count++;
	freelists[l].free = old;
	DB({struct backup *p = balloc();
	    p->next = backupfree[l];
	    p->item = old;
		backupfree[l] = p; })
	DB(tbackup(l));
    } else {
	struct freepage *fpage;
	assert(l == BIG);
	assert(((U)old & (PAGESIZE-1)) == 0);
	LOCK(NUMSMALL);
	fpage = free_pages(old);
	if ((void *)((U)fpage + fpage->size * PAGESIZE) == membase->end &&
	    sbrk(0) == membase->end)
	{
	    fp_remove(fpage);
	    sbrk((U)fpage - (U)membase->end);
	    membase->end = fpage; }
	UNLOCK(NUMSMALL); }
}

int mresize(void *old, U size)
{
unsigned	t, i;
struct page	*op, *tpg;
int		nl;
void		*pp;

    if (!old) return 0;
#ifdef MALLOC_DEBUG
    if ((U)old < (U)membase || (U)old >= (U)membase->end) {
	printf("***Invalid pointer given to "S(mresize)" %p\n", old);
	abort(); }
#endif /* MALLOC_DEBUG */
    DB( old = gcheck(old);
	size += 2*sizeof(U); )
    op = ADDR2PAGE(old);
    nl = SMLIST(size);
    if (op->code == nl)
	return 1;
    if (op->code == BIG && nl == -1) {
	size = (size + PAGESIZE - 1)/PAGESIZE;
	if ((int)size > op->page - PAGENUM(old)) {
	    LOCK(NUMSMALL);
	    if (PAGEADDR(op->page) == membase->end ||
		(tpg = NUM2PAGE(op->page))->code != BIG+FREE ||
		tpg->page - PAGENUM(old) < (int)size) {
		UNLOCK(NUMSMALL);
		return 0; }
	    fp_remove(FREEPAGE(op->page));
	    tpg->code = MIDDLE;
	    for (i = op->page, op->page = t = tpg->page; i < t; i++)
		NUM2PAGE(i)->page = PAGENUM(old);
	    UNLOCK(NUMSMALL); }
	if ((int)size < op->page - PAGENUM(old)) {
	    LOCK(NUMSMALL);
	    t = PAGENUM(old) + size;
	    tpg = NUM2PAGE(t);
	    tpg->code = BIG;
	    tpg->page = op->page;
	    for (i = op->page-1; i > t; i--)
		NUM2PAGE(i)->page = t;
	    op->page = t;
	    UNLOCK(NUMSMALL);
	    pp = PAGEADDR(t);
	    DB( pp = gsetup(pp); )
	    free(pp); }
	assert((int)size == op->page - PAGENUM(old));
	return 1; }
    return 0;
}

U msize(void *p)
{
struct page	*pg;
U		size;

#ifdef MALLOC_DEBUG
    if ((U)p < (U)membase || (U)p >= (U)membase->end) {
	printf("***Invalid pointer given to "S(msize)" %p\n", p);
	abort(); }
#endif /* MALLOC_DEBUG */
    DB( p = gcheck(p); )
    pg = ADDR2PAGE(p);
    if (pg->code < NUMSMALL) {
	assert(((U)p & (SIZE(pg->code)-1)) == 0);
	size = SIZE(pg->code); }
    else {
	assert((pg->code & ~FREE) == BIG);
	assert(((U)p & (PAGESIZE-1)) == 0);
	size = (pg->page - PAGENUM(p))* PAGESIZE; }
    DB(size -= 2*sizeof(U));
    return size;
}

void *realloc(void *old, size_t size)
{
    if (size == 0) {
	free(old);
	return 0;
    } else if (!old) {
	return malloc(size);
    } else if (mresize(old, size)) {
	return old;
    } else {
	U	osize = msize(old);
	void	*new = malloc(size);

	if (size > osize) size = osize;
	if (new) {
	    memcpy(new, old, size);
	    free(old); }
	return new; }
}

void *calloc(size_t n1, size_t n2)
{
U	size = n1 * n2;
void	*new = malloc(size);

    if (new)
	memset(new, 0, size);
    return new;
}

void heapdump()
{
void		*p;
struct page	*pg;
struct chunk	*cp;
unsigned	i, j, cnt, lbig = 0;
char		buffer[64];
struct freepage	*p1, *p2;

    cnt = ((U)membase->end - (U)membase)/PAGESIZE;
    printf("membase = %p, end = %p, %u pages total", membase,
	   membase->end, cnt);
    for (i=0, p=membase; p<membase->end; p += PAGESIZE, i++) {
	if (i%8 == 0)
	    printf("\n0x%08lx: ", (U)p);
	pg = NUM2PAGE(i);
	if (pg->code < NUMSMALL) {
	    sprintf(buffer, "%d(%d)", SIZE(pg->code), pg->count);
	    printf("%8s", buffer);
	    lbig = 0; }
	else switch(pg->code & ~FREE) {
	case BIG:
	    printf(" %c %-5d", pg->code & FREE ? 'F' : 'B', pg->page - i);
	    lbig = i;
	    break;
	case MIDDLE:
	    if (pg->page == lbig)
		printf("  <-->  ");
	    else
		printf("  ?--?  ");
	    break;
	case BASE:
	    printf(pg->code & FREE ? "  GAP   " : "  BASE  ");
	    lbig = 0;
	    break;
	default:
	    printf("  ????  ");
	    lbig = 0;
	    break; } }
    for (i=0; i<NUMSMALL; i++) {
	printf("\n\nSIZE %4d: local %d", SIZE(i), freelists[i].count);
	if (freelists[i].free) {
	    printf("[%p", freelists[i].free);
	    for (cp = freelists[i].free->next; cp; cp = cp->next)
		printf(", %p", cp);
	    printf("]"); }
	if (freelists[i].aux) {
	    printf(" + [%p", freelists[i].aux);
	    for (cp = freelists[i].aux->next; cp; cp = cp->next)
		printf(", %p", cp);
	    printf("]"); }
	printf("\n\t   global ");
	for (j = membase->freechunks[i]; j; j = pg->page) {
	    pg = NUM2PAGE(j);
	    if (pg->code != i)
		printf("<WRONG CODE %d>", pg->code);
	    printf("%d[", pg->count);
	    if (pg->count)
		for (cp = PAGEADDR(j) + pg->free*SIZE(i); cp; cp = cp->next)
		    printf("%p%s", cp, cp->next ? ", " : "]");
	    if (pg->page)
		printf(" + "); } }
    printf("\n\nBIG: ");
    for (p1 = membase->freepages; p1; p1 = p1->bigger) {
	printf("\t%d[%p", p1->size, p1);
	for (p2 = p1->next; p2; p2 = p2->next)
	    printf(", %p", p2);
	printf("]\n"); }
    printf("\n\n\n");
}
