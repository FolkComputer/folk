#ifdef __linux__
	#define _GNU_SOURCE
#endif
	
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>

#include "mpmc_queue.h"
#include "memory.h"
#include "c11threads.h"

/* Usage example */

#define N 20000000

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
	/** @todo not recommended to use rdtsc on multicore machine */
	__asm__ ("rdtsc;"
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

/* Static global storage */
int fibs[N];

int producer(void *ctx)
{
	//printf("producer\n"); //DELETEME
	struct mpmc_queue *q = (struct mpmc_queue *) ctx;
	
	srand((unsigned) time(0) + thread_get_id());
	size_t pause = rand() % 1000;

	/* Wait for global start signal */
	while (g_start == 0)
		thrd_yield();
	
		/* Wait for a random time */
	for (size_t i = 0; i != pause; i += 1)
		nop();
	
	/* Enqueue */
	for (unsigned long count = 0, n1 = 0, n2 = 1; count < N; count++) {
		fibs[count] = n1 + n2;
		
		void *fibptr = (void *) &fibs[count];
		
		if (!mpmc_queue_push(q, fibptr)) {
			printf("Queue push failed at count %lu\n", count);
			return -1;
		}
		
		n1 = n2; n2 = fibs[count];
	}
	
	return 0;
}

int consumer(void *ctx)
{
	//printf("consumer\n"); 	//DELETEME
	struct mpmc_queue *q = (struct mpmc_queue *) ctx;
	
	srand((unsigned) time(0) + thread_get_id());
	size_t pause = rand() % 1000;

	/* Wait for global start signal */
	while (g_start == 0)
		thrd_yield();
	
	/* Wait for a random time */
	for (size_t i = 0; i != pause; i += 1)
		nop();
	
	/* Dequeue */
	for (unsigned long count = 0, n1 = 0, n2 = 1; count < N; count++) {
		int fib = n1 + n2;
		int *pulled;
		
		while (!mpmc_queue_pull(q, (void **) &pulled)) {
			//printf("Queue empty: %d\n", temp);
			//return -1;
		}
		
		if (*pulled != fib) {
			printf("Pulled != fib\n");
			return -1;
		}		
		
		n1 = n2; n2 = fib;
	}
	
	return 0;
}

int test_single_threaded(struct mpmc_queue *q)
{
	int resp, resc;
	g_start = 1;
	
	resp = producer(q);
	if (resp)
		printf("Enqueuing failed\n");
	
	resc = consumer(q);
	if (resc)
		printf("Consumer failed\n");
	
	if (resc || resp)
		printf("Single Thread Test Failed\n");
	else
		printf("Single Thread Test Complete\n");
	
	return 0;
}

int test_multi_threaded(struct mpmc_queue *q)
{
	thrd_t thrp, thrc;
	int resp, resc;
	
	g_start = 0;
	
	thrd_create(&thrp, consumer, q);	/** @todo Why producer thread runs earlier? */
	thrd_create(&thrc, producer, q);
	
	sleep(1);

	uint64_t start_tsc_time, end_tsc_time;

	start_tsc_time = rdtscp();
	g_start = 1;

	thrd_join(thrp, &resp);
	thrd_join(thrc, &resc);
	
	end_tsc_time = rdtscp();

	if (resc || resp)
		printf("Queue Test failed\n");
	else
		printf("Two-thread Test Complete\n");
	
	printf("cycles/op for rdtsc %lu\n", (end_tsc_time - start_tsc_time)/N);

	size_t used = mpmc_queue_available(q);
	if (used > 0)
		printf("%zu slots in use? There is something wrong with the test\n", used);
	
	int ret = mpmc_queue_destroy(q);
	if (ret)
		printf("Failed to destroy queue: %d\n", ret);
	
	return 0;
}

int main()
{
	struct mpmc_queue q;
	mpmc_queue_init(&q, 1<<20, &memtype_heap);	/** @todo change size>1 in case of bounded queue impl. memtype_hugepage impl for un_spsc */
	
	test_multi_threaded(&q);
	
	return 0;
}
