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

#ifndef _MPMC_QUEUE_H_
#define _MPMC_QUEUE_H_

#include <stdint.h>
#include <stdatomic.h>

#include "memory.h"

#define CACHELINE_SIZE 64

typedef char cacheline_pad_t[CACHELINE_SIZE];

struct mpmc_queue {
	cacheline_pad_t _pad0;	/**< Shared area: all threads read */
	struct memtype const * mem;
	size_t buffer_mask;
	struct mpmc_queue_cell {
		atomic_size_t sequence;
		void *data;
	} *buffer;
	cacheline_pad_t	_pad1;	/**> Producer area: only producers read & write */
	atomic_size_t	tail;	/**> Queue tail pointer */
	cacheline_pad_t	_pad2;	/**> Consumer area: only consumers read & write */
	atomic_size_t	head;	/**> Queue head pointer */
	cacheline_pad_t	_pad3;	/**> @todo Why needed? */
};

/** Initialize MPMC queue */
int mpmc_queue_init(struct mpmc_queue *q, size_t size, const struct memtype *mem);

/** Desroy MPMC queue and release memory */
int mpmc_queue_destroy(struct mpmc_queue *q);

/** Return estimation of current queue usage.
 *
 * Note: This is only an estimation and not accurate as long other
 *       threads are performing operations.
 */ 
size_t mpmc_queue_available(struct mpmc_queue *q);

int mpmc_queue_push(struct mpmc_queue *q, void *ptr);

int mpmc_queue_pull(struct mpmc_queue *q, void **ptr);

int mpmc_queue_push_many(struct mpmc_queue *q, void *ptr[], size_t cnt);

int mpmc_queue_pull_many(struct mpmc_queue *q, void **ptr[], size_t cnt);

#endif /* _MPMC_QUEUE_H_ */