#ifndef _shm_malloc_h_
#define _shm_malloc_h_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

extern int	shm_init(const char *, void (*)()), shm_fini(), shm_destroy(),
		shm_child();

extern void	*shm_malloc(size_t), *shm_calloc(size_t, size_t),
		*shm_realloc(void *, size_t), *shm_valloc(size_t);
extern void	shm_free(void *);
extern int	shm_mresize(void *, size_t);
extern size_t	shm_msize(void *);

extern void	*shm_global(), shm_set_global(void *);

#define FIRST_TWO_ARGS(a, b, ...)	a, b
#define shm_init(...)	shm_init(FIRST_TWO_ARGS(__VA_ARGS__, 0))

#ifdef __cplusplus
    }
#endif

#endif /* _shm_malloc_h_ */
