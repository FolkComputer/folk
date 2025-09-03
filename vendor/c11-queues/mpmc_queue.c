/** Lock-free Multiple-Producer Multiple-consumer (MPMC) queue.
 *
 * Based on Dmitry Vyukov#s Bounded MPMC queue:
 *   http://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue
 *
 * @author Steffen Vogel <post@steffenvogel.de>
 * @copyright 2016 Steffen Vogel
 * @license BSD 2-Clause License
 * 
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modiffication, are permitted provided that the following conditions are met:
 * 
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * 
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "mpmc_queue.h"

/** Initialize MPMC queue */
int mpmc_queue_init(struct mpmc_queue *q, size_t size, const struct memtype *mem)
{
	/* Queue size must be 2 exponent */
	if ((size < 2) || ((size & (size - 1)) != 0))
		return -1;

	q->mem = mem;
	q->buffer_mask = size - 1;
	q->buffer = memory_alloc(q->mem, sizeof(q->buffer[0]) * size);
	if (!q->buffer)
		return -2;
	
	for (size_t i = 0; i != size; i += 1)
		atomic_store_explicit(&q->buffer[i].sequence, i, memory_order_relaxed);

	atomic_store_explicit(&q->tail, 0, memory_order_relaxed);
	atomic_store_explicit(&q->head, 0, memory_order_relaxed);
	
	return 0;
}

int mpmc_queue_destroy(struct mpmc_queue *q)
{
	return memory_free(q->mem, q->buffer, (q->buffer_mask + 1) * sizeof(sizeof(q->buffer[0])));
}

/** Return estimation of current queue usage.
 *
 * Note: This is only an estimation and not accurate as long other
 *       threads are performing operations.
 */ 
size_t mpmc_queue_available(struct mpmc_queue *q)
{
	return  atomic_load_explicit(&q->tail, memory_order_relaxed) -
		atomic_load_explicit(&q->head, memory_order_relaxed);
}

int mpmc_queue_push(struct mpmc_queue *q, void *ptr)
{
	struct mpmc_queue_cell *cell;
	size_t pos, seq;
	intptr_t diff;

	pos = atomic_load_explicit(&q->tail, memory_order_relaxed);
	for (;;) {
		cell = &q->buffer[pos & q->buffer_mask];
		seq = atomic_load_explicit(&cell->sequence, memory_order_acquire);
		diff = (intptr_t) seq - (intptr_t) pos;

		if (diff == 0) {
			if (atomic_compare_exchange_weak_explicit(&q->tail, &pos, pos + 1, memory_order_relaxed, memory_order_seq_cst))
				break;
		}
		else if (diff < 0)
			return 0;
		else
			pos = atomic_load_explicit(&q->tail, memory_order_relaxed);
	}

	cell->data = ptr;
	atomic_store_explicit(&cell->sequence, pos + 1, memory_order_release);

	return 1;
}

int mpmc_queue_pull(struct mpmc_queue *q, void **ptr)
{
	struct mpmc_queue_cell *cell;
	size_t pos, seq;
	intptr_t diff;
	
	pos = atomic_load_explicit(&q->head, memory_order_relaxed);
	for (;;) {
		cell = &q->buffer[pos & q->buffer_mask];
		
		seq = atomic_load_explicit(&cell->sequence, memory_order_acquire);
		diff = (intptr_t) seq - (intptr_t) (pos + 1);

		if (diff == 0) {
			if (atomic_compare_exchange_weak_explicit(&q->head, &pos, pos + 1, memory_order_relaxed, memory_order_seq_cst))
				break;
		}
		else if (diff < 0)
			return 0;
		else
			pos = atomic_load_explicit(&q->head, memory_order_relaxed);
	}

	*ptr = cell->data;
	atomic_store_explicit(&cell->sequence, pos + q->buffer_mask + 1, memory_order_release);

	return 1;
}

int mpmc_queue_push_many(struct mpmc_queue *q, void *ptr[], size_t cnt)
{
	int ret;
	size_t i;

	for (i = 0; i < cnt; i++) {
		ret = mpmc_queue_push(q, ptr[i]);
		if (!ret)
			break;
	}
	
	return i;
}

int mpmc_queue_pull_many(struct mpmc_queue *q, void **ptr[], size_t cnt)
{
	int ret;
	size_t i;

	for (i = 0; i < cnt; i++) {
		ret = mpmc_queue_pull(q, ptr[i]);
		if (!ret)
			break;
	}
	
	return i;
}
