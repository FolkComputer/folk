#ifdef __linux__
	#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>

/* There are not many compilers yet which support threads.h natively.
 * We will fallback to a drop-in replacement which is based on pthreads.h */
#include "c11threads.h"

/* For thread_get_id() */
#ifdef __MACH__
  #include <pthread.h>
#elif defined(__linux__)
  #include <sys/types.h>
#endif

#include "spsc_ub_queue.h"
#include "memory.h"

size_t const thread_count = 1;
size_t const batch_size = 10;
size_t const iter_count = 20000000;
//size_t const queue_size = 1 << 10;

int volatile g_start = 0;

/** Get thread id as integer
 * In contrast to pthread_t which is an opaque type */
uint64_t thread_get_id()
{
#ifdef __MACH__
	uint64_t id;
	pthread_threadid_np(pthread_self(), &id);
	return id;
#elif defined(SYS_gettid)
	return (int) syscall(SYS_gettid);
#endif
	return -1;
}

/** Get CPU timestep counter */
__attribute__((always_inline)) static inline uint64_t rdtscp()
{
	uint64_t tsc;

	__asm__ ("rdtscp;"
		 "shl $32, %%rdx;"
		 "or %%rdx,%%rax"
		: "=a" (tsc)
		:
		: "%rcx", "%rdx", "memory");

	return tsc;
}

/** Sleep, do nothing */
__attribute__((always_inline)) static inline void nop()
{
	__asm__("rep nop;");
}

int thread_func_push(void *ctx)
{
	struct spsc_ub_queue *q = (struct spsc_ub_queue *) ctx;

	srand((unsigned) time(0) + thread_get_id());
	size_t pause = rand() % 1000;

	/* Wait for global start signal */
	while (g_start == 0)
		thrd_yield();

	/* Wait for a random time */
	for (size_t i = 0; i != pause; i += 1)
		nop();

	for (int iter = 0; iter != iter_count; ++iter) {
		for (size_t i = 0; i != batch_size; i += 1) {
			void *ptr = (void *) i;
			spsc_ub_queue_push(q, ptr);	//FIXME
		}
	}
	thrd_yield();

	return 0;
}

int thread_func_pull(void *ctx)
{
	struct spsc_ub_queue *q = (struct spsc_ub_queue *) ctx;

	srand((unsigned) time(0) + thread_get_id());
	size_t pause = rand() % 1000;

	/* Wait for global start signal */
	while (g_start == 0)
		thrd_yield();

	/* Wait for a random time */
	for (size_t i = 0; i != pause; i += 1)
		nop();

	for (int iter = 0; iter != iter_count; ++iter) {
		for (size_t i = 0; i != batch_size; i += 1) {
			void *ptr;
			while (!spsc_ub_queue_pull(q, &ptr)){
				continue;
			}	//FIXME
		}
	}
	thrd_yield(); // queue empty
	
	return 0;
}

int main()
{
	struct spsc_ub_queue queue;
	thrd_t threads[thread_count + 1];
	int ret;
	
	spsc_ub_queue_init(&queue, batch_size * iter_count, &memtype_heap);

	printf("spsc_ub_queue_init successful\n");
	//for (int i = 0; i != thread_count; ++i)
	thrd_create(&threads[0], thread_func_push, &queue);
	thrd_create(&threads[1], thread_func_pull, &queue);

	sleep(1);

	uint64_t start = rdtscp();
	g_start = 1;

	//for (int i = 0; i != thread_count; ++i)
	thrd_join(threads[0], NULL);
	thrd_join(threads[1], NULL);

	uint64_t end = rdtscp();
	
	printf("cycles/op = %lu\n", (end - start) / (batch_size * iter_count * 2 * thread_count));

	if (queue._tail->_next != NULL)
		printf("slots in use? There is something wrong with the test\n");
	
	ret = spsc_ub_queue_destroy(&queue);
	if (ret)
		printf("Failed to destroy queue: %d", ret);
	
	return 0;
}