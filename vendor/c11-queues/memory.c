/** 
 *
 */
#ifdef __linux__
	#define _GNU_SOURCE
#endif
 
#include <stdlib.h>
#include <sys/mman.h>
#include <stdio.h>		//DELETEME

/* Required to allocate hugepages on Apple OS X */
#ifdef __MACH__
  #include <mach/vm_statistics.h>
#endif

#include "memory.h"

void * memory_alloc(const struct memtype *m, size_t len)
{
	return m->alloc(len);
}

int memory_free(const struct memtype *m, void *ptr, size_t len)
{
	return m->dealloc(ptr, len);
}

static void * memory_heap_alloc(size_t len)
{
	return malloc(len);
}

int memory_heap_dealloc(void *ptr, size_t len)
{
	free(ptr);
	
	return 0;
}

/** Allocate memory backed by hugepages with malloc() like interface */
static void * memory_hugepage_alloc(size_t len)
{
	int prot = PROT_READ | PROT_WRITE;
	int flags = MAP_PRIVATE | MAP_ANONYMOUS;
	
#ifdef __MACH__
	flags |= VM_FLAGS_SUPERPAGE_SIZE_2MB;
#elif defined(__linux__)
	flags |= MAP_HUGETLB | MAP_LOCKED;
#endif
	
	return mmap(NULL, len, prot, flags, -1, 0);
}

static int memory_hugepage_dealloc(void *ptr, size_t len)
{
	return munmap(ptr, len);
}

/* List of available memory types */
const struct memtype memtype_heap = {
	.name = "heap",
	.flags = MEMORY_HEAP,
	.alloc = memory_heap_alloc,
	.dealloc = memory_heap_dealloc,
	.alignment = 1
};

const struct memtype memtype_hugepage = {
	.name = "mmap_hugepages",
	.flags = MEMORY_MMAP | MEMORY_HUGEPAGE,
	.alloc = memory_hugepage_alloc,
	.dealloc = memory_hugepage_dealloc,
	.alignment = 1 << 21  /* 2 MiB hugepage */
};

/** @todo */
const struct memtype memtype_dma = {
	.name = "dma",
	.flags = MEMORY_DMA | MEMORY_MMAP,
	.alloc = NULL, .dealloc = NULL,
	.alignment = 1 << 12
};
