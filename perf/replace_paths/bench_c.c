/**
 * C stored functions for the replace-path benchmark: the same
 * box_replace()/box_index_get() a Lua function would do, but
 * called from C, so the request never enters Lua.
 *
 * Registered by server.lua as
 *
 *   box.schema.func.create('bench_c.replace', {language = 'C'})
 *
 * The name is split at the last dot: the package 'bench_c'
 * resolves to bench_c.so on package.cpath, the symbol is the last
 * part.
 *
 * Two flavours of every write: the plain one returns the new
 * tuple (like IPROTO_REPLACE, which always sends it back), the
 * _noret one returns nothing (like the vshard/crud storage
 * functions the numbers are compared with).
 */
#include <stdint.h>
#include <string.h>

#include <msgpuck.h>
#include "module.h"

#define EXPORT __attribute__((visibility("default")))

/* ER_PROC_C from src/box/errcode.h. */
enum {
	ER_PROC_C_CODE = 102,
};

static int64_t
space_id_decode(const char **p)
{
	if (mp_typeof(**p) == MP_UINT)
		return mp_decode_uint(p);
	if (mp_typeof(**p) == MP_STR) {
		uint32_t len;
		const char *s = mp_decode_str(p, &len);
		uint32_t id = box_space_id_by_name(s, len);
		if (id == BOX_ID_NIL) {
			box_error_set(__FILE__, __LINE__, ER_PROC_C_CODE,
				      "space '%.*s' is not found", (int)len,
				      s);
			return -1;
		}
		return id;
	}
	box_error_set(__FILE__, __LINE__, ER_PROC_C_CODE,
		      "space must be an id or a name");
	return -1;
}

/** Decode {space, tuple} and run box_replace(). */
static int
replace_impl(box_function_ctx_t *ctx, const char *args, box_tuple_t **result)
{
	const char *p = args;
	if (mp_typeof(*p) != MP_ARRAY || mp_decode_array(&p) < 2) {
		box_error_set(__FILE__, __LINE__, ER_PROC_C_CODE,
			      "Usage: replace(space, tuple)");
		return -1;
	}
	int64_t space_id = space_id_decode(&p);
	if (space_id < 0)
		return -1;
	if (mp_typeof(*p) != MP_ARRAY) {
		box_error_set(__FILE__, __LINE__, ER_PROC_C_CODE,
			      "tuple must be an array");
		return -1;
	}
	(void)ctx;
	const char *tuple = p;
	mp_next(&p);
	return box_replace(space_id, tuple, p, result);
}

/** bench_c.replace(space, tuple) - returns the new tuple. */
EXPORT int
replace(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args_end;
	box_tuple_t *result = NULL;
	if (replace_impl(ctx, args, &result) != 0)
		return -1;
	if (result != NULL)
		return box_return_tuple(ctx, result);
	return 0;
}

/** bench_c.replace_noret(space, tuple) - returns nothing. */
EXPORT int
replace_noret(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	(void)args_end;
	return replace_impl(ctx, args, NULL);
}

/** bench_c.get(space, key) - box_index_get() from the pk. */
EXPORT int
get(box_function_ctx_t *ctx, const char *args, const char *args_end)
{
	const char *p = args;
	if (mp_typeof(*p) != MP_ARRAY || mp_decode_array(&p) < 2) {
		box_error_set(__FILE__, __LINE__, ER_PROC_C_CODE,
			      "Usage: get(space, key)");
		return -1;
	}
	int64_t space_id = space_id_decode(&p);
	if (space_id < 0)
		return -1;
	const char *key = p;
	if (mp_typeof(*p) != MP_ARRAY) {
		/* Allow a bare key part. */
		char *buf = box_region_alloc(mp_sizeof_array(1) +
					     (args_end - p));
		if (buf == NULL)
			return -1;
		char *e = mp_encode_array(buf, 1);
		const char *part = p;
		mp_next(&p);
		memcpy(e, part, p - part);
		e += p - part;
		key = buf;
		p = e;
	} else {
		mp_next(&p);
	}
	box_tuple_t *tuple;
	if (box_index_get(space_id, 0, key, p, &tuple) != 0)
		return -1;
	if (tuple != NULL)
		return box_return_tuple(ctx, tuple);
	return 0;
}
