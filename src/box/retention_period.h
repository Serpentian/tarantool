/*
 * Copyright (c) 2023 VK Company Limited. All Rights Reserved.
 *
 * The information and source code contained herein is the exclusive property
 * of VK Company Limited and may not be disclosed, examined, or reproduced in
 * whole or in part without explicit written authorization from the Company.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "trivia/config.h"

#if defined(ENABLE_RETENTION_PERIOD)
#include "retention_period_impl.h"
#else /* !defined(ENABLE_RETENTION_PERIOD) */

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

#include "vclock/vclock.h"
#include "xlog.h"

/**
 * Allocate vclock structure. In EE additional memory is allocated,
 * where expiration time is saved.
 */
static inline struct vclock*
retention_vclock_new(void)
{
	return (struct vclock *)xmalloc(sizeof(struct vclock));
}

/**
 * Set expiration time of the @retention_vclock to now + @period.
 */
static inline void
retention_vclock_set(struct vclock *retention_vclock, double period)
{
	(void)retention_vclock;
	(void)period;
}

/**
 * Update expiration time of all files. New period must be saved inside xdir.
 */
static inline void
retention_index_update(struct xdir *xdir, double old_period)
{
	(void)xdir;
	(void)old_period;
}

/**
 * Return vclock of the oldest file, which is protected from garbage collection.
 * Vclock is cleared, if none of the files are protected. Vclock must be
 * non-nil.
 */
static inline void
retention_index_get(vclockset_t *index, struct vclock *vclock)
{
	(void)index;
	assert(vclock != NULL);
	vclock_clear(vclock);
}

#if defined(__cplusplus)
} /* extern "C" */
#endif /* defined(__cplusplus) */

#endif /* !defined(ENABLE_RETENTION_PERIOD) */
