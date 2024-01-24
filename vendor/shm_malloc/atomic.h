#ifndef __atomic_h__
#define __atomic_h__

#ifndef __GNUC__
#error This file requires GCC
#else

#if defined(mc68000)
typedef unsigned int	word_t;

typedef unsigned int	TAS_t;
#define TAS(m)  ({ \
    register TAS_t _t_tas; \
    asm volatile ("tas (%1); smi %0" : "=g" (_t_tas) : "a" (&(m))); \
    _t_tas; })

#if defined(mc68020)
#define	CAS(m, c, u) ({ \
    register word_t	_o;						\
    asm volatile ("cas %0,%1,(%2)" : "=d" (_o)				\
				   : "d" (u), "a" (&(m)), "0" (c));	\
    _o; })
#define CAS2(m1, c1, u1, m2, c2, u2) \
    asm volatile ("cas2 %0:%1,%2:%3,(%4):(%5)" : "=d" (c1), "=d" (c2) : \
	"d" (u1), "d" (u2), "g" (&(m1)), "g" (&(m2)), "0" (c1), "1" (c2))
#endif /* mc68020 */

#elif defined(__i386__)
typedef unsigned int	word_t;
#define SWAP(m, v) ({ \
    register word_t	_o;						\
    asm volatile ("xchg %0, %2" : "=r" (_o) : "0" (v) , "m" (m));	\
    _o; })
#define SWAPB(m, v) ({ \
    register unsigned char	_o;					\
    asm volatile ("xchg %0, %2" : "=r" (_o) : "0" (v) , "m" (m));	\
    _o; })

#elif defined(__x86_64__)
typedef unsigned long	word_t;
#define SWAP(m, v) ({ \
    register word_t	_o;						\
    asm volatile ("xchg %0, %2" : "=r" (_o) : "0" (v) , "m" (m));	\
    _o; })
#define SWAPB(m, v) ({ \
    register unsigned char	_o;					\
    asm volatile ("xchg %0, %2" : "=r" (_o) : "0" (v) , "m" (m));	\
    _o; })

#elif defined(sparc)
typedef unsigned int	word_t;

#define SWAP(m, v) ({ \
    register word_t	_o;						\
    asm volatile ("swap [%2],%0" : "=r" (_o) : "0" (v) , "r" (&(m)));	\
    _o; })

#define SWAPB(m, v) ({ \
    register word_t	_o;						\
    asm volatile ("ldstub [%2],%0" : "=r" (_o) : "0" (v) , "r" (&(m)));	\
    _o; })

#elif defined(m88k)
typedef unsigned int	word_t;

#define SWAP(m, v) ({ \
    register word_t	_o;						\
    asm volatile ("xmem %0,%1,0" : "=r" (_o) : "r" (&(m)) , "0" (v));	\
    _o; })

#elif defined(__alpha__)
typedef unsigned long	word_t;

#define	RW_NONSTRICT	1
#define	MEMORY_BARRIER	asm volatile("mb")
#define LOAD_LOCK(m) ({							\
    register word_t	_o;						\
    asm volatile("ldq_l %0,%1" : "=r"(_o) : "m"(m));			\
    _o; })
#define STORE_LOCK(m, v) ({						\
    register word_t	_o;						\
    asm volatile("stq_c %0,%1" : "=r"(_o) : "m"(m), "0"(v));		\
    _o; })

#elif defined(__ppc__)
typedef unsigned long	word_t;

#define RW_NONSTRICT	1
#define MEMORY_BARRIER	asm volatile("eieio")
#define LOAD_LOCK(m) ({							\
    register word_t	_o;						\
    asm volatile("lwarx %0,0,%1" : "=r"(_o) : "r"(&(m)));		\
    _o; })
#define STORE_LOCK(m, v) ({						\
    register int	_o = 0;						\
    asm volatile("stwcx. %2,0,%1\n"					\
		"\tbc 5,2,$+8\n"					\
		"\tori %0,%0,1"						\
		: "=r"(_o) : "r"(&(m)), "r"(v), "0"(_o));		\
    _o; })

#else
#error Unknown machine type
#endif

#if !defined(MEMORY_BARRIER)
#define MEMORY_BARRIER
#endif /* !MEMORY_BARRIER */

#if !defined(ATOMSET)
#define ATOMSET(m, v) ({ \
    register word_t	_o;	\
    MEMORY_BARRIER;		\
    _o = (m) = (v);		\
    MEMORY_BARRIER;		\
    _o; })
#endif /* !ATOMSET */

#if defined(LOAD_LOCK) && !defined(TAS)
typedef word_t	TAS_t;
#define	TAS(m)	({				\
    register word_t *_m = (word_t *)&(m);	\
    LOAD_LOCK(*_m) ? 1 : !STORE_LOCK(*_m, 1); })
#endif

#if defined(LOAD_LOCK) && !defined(CAS)
#define CAS(m, c, u) ({				\
    register word_t	_o, _t = (u);		\
    register word_t	 *_m = (word_t *)&(m);	\
    do {					\
	if ((_o = LOAD_LOCK(*_m)) != (c)) 	\
	    break;				\
    } while(!STORE_LOCK(*_m, _t));		\
    _o; })
#endif

#if defined(LOAD_LOCK) && !defined(SWAP)
#define SWAP(m, v) ({				\
    register word_t	_o, _v = (v);		\
    register word_t	 *_m = (word_t *)&(m);	\
    do {					\
	_o = LOAD_LOCK(*_m);			\
    } while(!STORE_LOCK(*_m, _v));		\
    _o; })
#endif

#if defined(LOAD_LOCK) && !defined(ATOMADD)
#define ATOMADD(m, v) ({			\
    register word_t	_o, _v = (v);		\
    register word_t	 *_m = (word_t *)&(m);	\
    do {					\
	_o = LOAD_LOCK(*_m) + _v;		\
    } while(!STORE_LOCK(*_m, _o));		\
    _o; })
#endif

#if defined(SWAPB) && !defined(TAS)
typedef unsigned char	TAS_t;
#define TAS(m)	SWAPB(m, 1)
#endif

#if defined(SWAP) && !defined(TAS)
typedef word_t	TAS_t;
#define TAS(m)	SWAP(m, 1)
#endif

#if defined(CAS) && !defined(TAS)
typedef word_t	TAS_t;
#define TAS(m)	CAS(m, 0, 1)
#endif

#if defined(CAS) && !defined(SWAP)
#define	SWAP(m, v) ({					\
    register word_t _t_c1, _t_c2;			\
    _t_c2 = _t_c1 = (m);				\
    while ((_t_c1 = CAS(m, _t_c1, v)) != _t_c2);	\
	_t_c2 = _t_c1;					\
    _t_c1; })
#endif

#if defined(CAS) && !defined(ATOMADD)
#define ATOMADD(m, d) ({				\
    word_t	_v, _ov, _d;				\
    _d = (d);						\
    _ov = _v = (m);					\
    while ((_v = CAS(m, _v, _v+_d)) != _ov)		\
	_ov = _v;					\
    _v+_d; })
#endif

#if defined(SWAP) && !defined(ATOMADD)
#define ATOMADD(m, d) ({ 	\
    word_t _v, _ov, _d;		\
    _d = d;			\
    _v = m;			\
    while(_d) {			\
	_ov = _v;		\
	_v = SWAP(m, _v+_d);	\
	_d = _v - _ov; }	\
    _v+_d; })
#endif

#endif /* __GNUC__ */

#endif /* __atomic_h__ */
