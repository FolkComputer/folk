/** Lock-free Single-Producer Single-consumer (SPSC) queue.
 *
 * @author Umar Farooq
 * @copyright 2016 Umar Farooq <umar1.farooq1@gmail.com>
 * @license BSD 2-Clause License
 * 
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
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

#include "spsc_queue.h"

struct spsc_queue * spsc_queue_init(struct spsc_queue * q, size_t size, const struct memtype *mem)
{
	/* Queue size must be 2 exponent */
	if ((size < 2) || ((size & (size - 1)) != 0))
		return NULL;
	
	q = memory_alloc(mem, sizeof(struct spsc_queue) + (sizeof(q->pointers[0]) * size));
	if (!q)
		return NULL;
	
	q->mem = mem;
	
	q->capacity = size - 1;

	atomic_init(&q->_tail, 0);
	atomic_init(&q->_head, 0);

	return q;
}

int spsc_queue_destroy(struct spsc_queue *q)
{
	const struct memtype mem = *(q->mem);	/** @todo Memory is not being freed properly??? */
	return memory_free(&mem, q, sizeof(struct spsc_queue) + ((q->capacity + 1) * sizeof(q->pointers[0])));
}

int spsc_queue_get_many(struct spsc_queue *q, void **ptrs[], size_t cnt)
{
	if (q->capacity <= spsc_queue_available(q))
		cnt = 0;
	else if (cnt > q->capacity - spsc_queue_available(q))
		cnt = q->capacity - spsc_queue_available(q);
	
	/**@todo Is atomic_load_explicit needed here for loading q->_head? */
	for (int i = 0; i < cnt; i++)
		ptrs[i] = &(q->pointers[q->_head % (q->capacity + 1)]);
	
	return cnt;
}

int spsc_queue_push_many(struct spsc_queue *q, void *ptrs[], size_t cnt)
{
	//int free_slots = q->_tail < q->_head ? q->_head - q->_tail - 1 : q->_head + (q->capacity - q->_tail);
	size_t free_slots = spsc_queue_available(q);
	
	if (cnt > free_slots)
		cnt = free_slots;
	
	for (size_t i = 0; i < cnt; i++) {
		q->pointers[q->_tail] = ptrs[i];
		atomic_store_explicit(&q->_tail, (q->_tail + 1)%(q->capacity + 1), memory_order_release);
	}
	
	return cnt;
}

int spsc_queue_pull_many(struct spsc_queue *q, void **ptrs[], size_t cnt)
{
	if (q->capacity <= spsc_queue_available(q))
		cnt = 0;
	else if (cnt > q->capacity - spsc_queue_available(q))
		cnt = q->capacity - spsc_queue_available(q);
	
	for (size_t i = 0; i < cnt; i++) {
		*ptrs[i] = q->pointers[q->_head];
		atomic_store_explicit(&q->_head, (q->_head + 1)%(q->capacity + 1), memory_order_release);
	}
	
	return cnt;
}

int spsc_queue_available(struct spsc_queue *q)
{
	if (atomic_load_explicit(&q->_tail, memory_order_acquire) < atomic_load_explicit(&q->_head, memory_order_acquire))
		return q->_head - q->_tail - 1;
	else
		return q->_head + (q->capacity - q->_tail);
}
