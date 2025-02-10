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

#ifndef _SPSC_UB_QUEUE_H_
#define _SPSC_UB_QUEUE_H_

#include <stdatomic.h>

#include "memory.h"

//static size_t const cacheline_size = 64;
#define CACHELINE_SIZE 64
typedef char cacheline_pad_t[CACHELINE_SIZE];

struct node {
	struct node * _Atomic _next;		/**> Single linked list of nodes */
	void *_value;
};

struct spsc_ub_queue 
{
	struct memtype const *mem;		/**> Memory type to use for allocations of new nodes. */
	
	/** Delimiter between consumer part and producer part, 
	 * so that they situated on different cache lines */
	cacheline_pad_t _pad0;	

	/* Consumer part 
	 * accessed mainly by consumer, infrequently be producer */
	struct node* _Atomic _tail; 		/**> Tail of the queue. */

	cacheline_pad_t _pad1;

	/* Producer part 
	 * accessed only by producer */
	struct node* _head;		/**> Head of the queue. */
	cacheline_pad_t _pad2;
	struct node* _first;		/**> Last unused node (tail of node cache). */
	cacheline_pad_t _pad3;
	struct node* _tailcopy;	/**> Helper which points somewhere between _first and _tail */
	cacheline_pad_t _pad4;
};

/** Initialize SPSC queue */
int spsc_ub_queue_init(struct spsc_ub_queue *q, size_t size, const struct memtype *mem);

/** Destroy SPSC queue and release memory */
int spsc_ub_queue_destroy(struct spsc_ub_queue *q);

/** Allocate memory for new node. Each node stores a pointer 
 * value pushed to unbounded SPSC queue 
 */
struct node * spsc_ub_alloc_node(struct spsc_ub_queue *q);

/** Push a value from unbounded SPSC queue 
 *  return : 1 always as its an unbounded queue
 */
int spsc_ub_queue_push(struct spsc_ub_queue *q, void *v);

/** Pull a value from unbounded SPSC queue 
 *  return : 1 if success else 0
 */
int spsc_ub_queue_pull(struct spsc_ub_queue *q, void **v);

#endif /* _SPSC_UB_QUEUE_H_ */