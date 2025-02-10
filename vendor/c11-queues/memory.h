/** 
 *
 */

#ifndef _MEMORY_H_
#define _MEMORY_H_

#ifdef __linux__
	#include <stdint.h>
	#include <stddef.h>
#endif

typedef void *(*memzone_allocator_t)(size_t);
typedef int (*memzone_deallocator_t)(void *, size_t);

enum memtype_flags {
	MEMORY_MMAP	= (1 << 0),
	MEMORY_DMA	= (1 << 1),
	MEMORY_HUGEPAGE	= (1 << 2),
	MEMORY_HEAP	= (1 << 3)
};

struct memtype {
	const char *name;
	int flags;
	
	size_t alignment;
	
	memzone_allocator_t alloc;
	memzone_deallocator_t dealloc;
};

/** @todo Unused for now */
struct memzone {
	struct memtype * const type;
	
	void *addr;
	uintptr_t physaddr;
	size_t len; 
};

void * memory_alloc(const struct memtype *m, size_t len);
int memory_free(const struct memtype *m, void *ptr, size_t len);

extern const struct memtype memtype_heap;
extern const struct memtype memtype_hugepage;

#endif /* _MEMORY_H_ */