/** Lock-free Unbounded Single-Producer Single-consumer (SPSC) queue.
 *
 * Based on Dmitry Vyukov's Unbounded SPSC queue:
 *   http://www.1024cores.net/home/lock-free-algorithms/queues/unbounded-spsc-queue
 *
 * @author Umar Farooq <umar1.farooq1@gmail.com>
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

#include "spsc_ub_queue.h"

int spsc_ub_queue_init(struct spsc_ub_queue* q, size_t size, const struct memtype *mem)
{
	q->mem = mem;
	struct node* n = memory_alloc(q->mem, sizeof(struct node) * size);
	n->_next = NULL;
	q->_tail = q->_head = q->_first= q->_tailcopy = n;
	
	/** Alloc memory at start for total size for efficiency */
	void *v = NULL;
	for(unsigned long i = 0; i < size; i++)		/** @todo fix this hack in bounded implementation */
		spsc_ub_queue_push(q, v);
	for(unsigned long i = 0; i < size; i++)
		spsc_ub_queue_pull(q, &v);
	
	return 0;
}

int spsc_ub_queue_destroy(struct spsc_ub_queue* q)
{
	struct node* n = q->_first;

	do {
		struct node* next = n->_next;
		memory_free(q->mem, (void *) n, sizeof(struct node));
		n = next;
	} while (n);
	
	return 0;
}

struct node* spsc_ub_alloc_node(struct spsc_ub_queue* q)
{
	/* First tries to allocate node from internal node cache,
	 * if attempt fails, allocates node via mmap() */

	if (q->_first != q->_tailcopy) {
		struct node* n = q->_first;
		q->_first = q->_first->_next;
		return n;
	}

	//q->_tailcopy = load_consume(q->_tail);
	q->_tailcopy = atomic_load_explicit(&q->_tail, memory_order_acquire);
	
	if (q->_first != q->_tailcopy) {
		struct node* n = q->_first;
		q->_first = q->_first->_next;
		return n;
	}

	return (struct node*) memory_alloc(q->mem, sizeof(struct node));
}

int spsc_ub_queue_push(struct spsc_ub_queue* q, void * v)
{
	struct node* n = spsc_ub_alloc_node(q);
	
	atomic_store_explicit(&(n->_next), NULL, memory_order_release);
	//n->_next = NULL;
	n->_value = v;
	
	//store_release(&(q->_head->_next), n);
	atomic_store_explicit(&(q->_head->_next), n, memory_order_release);
	
	q->_head = n;
	
	return 1;
}

int spsc_ub_queue_pull(struct spsc_ub_queue* q, void** v)
{
	if (atomic_load_explicit(&(q->_tail->_next), memory_order_acquire)) {
		*v = q->_tail->_next->_value;
		
		//store_release(&q->_tail, q->_tail->_next);
		atomic_store_explicit(&q->_tail, q->_tail->_next, memory_order_release);
		
		return 1;
	}
	
	return 0;
}
