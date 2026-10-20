#pragma once

/* Value constructors in folk's own shape.
 *
 * Zicl reports allocation failure as a status code and writes its result
 * through an out-parameter, so that a consumer can recover. Folk has no such
 * path: values get built deep inside unification and clause conversion, where
 * the only failure channel is a NULL Clause* that callers read as "no match"
 * rather than "out of memory". Rather than route a status through all of that
 * and get it subtly wrong, folk stops at the point of failure.
 *
 * That policy lives here so it is one edit to change. If folk ever grows real
 * recovery, these go away and their callers take the status directly. */

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#include <libzicl.h>

/* `defer` implementation for Clang and GCC. */
#if __has_include(<stddefer.h>)
# include <stddefer.h>
# if defined(__clang__)
#  if __is_identifier(_Defer)
#   error "clang may need the option -fdefer-ts for the _Defer feature"
#  endif
# endif
#elif __GNUC__ > 8
# define defer _Defer
# define _Defer      _Defer_A(__COUNTER__)
# define _Defer_A(N) _Defer_B(N)
# define _Defer_B(N) _Defer_C(_Defer_func_ ## N, _Defer_var_ ## N)
# define _Defer_C(F, V)                                                 \
  auto void F(int*);                                                    \
  __attribute__((__cleanup__(F), __deprecated__, __unused__))           \
     int V;                                                             \
  __attribute__((__always_inline__, __deprecated__, __unused__))        \
    inline auto void F(__attribute__((__unused__)) int*V)
#else
# error "The _Defer feature seems not available"
#endif

static inline void folkZiclAssert(int rc) {
    if (rc != 0) {
        fprintf(stderr, "folk: failed to perform operation (zicl status %d)\n", rc);
        abort();
    }
}

static inline Zicl_Val folkZiclCheck(int rc, Zicl_Val value) {
    folkZiclAssert(rc);
    return value;
}

static inline const char *ziclString(Zicl_Val value) {
    const char *str = Zicl_String(value);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclListString(Zicl_List* list) {
    const char *str = Zicl_String(Zicl_BoxList(list));
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline int ziclEquals(Zicl_Val a, Zicl_Val b) {
    int out; folkZiclAssert(Zicl_Equals(a, b, &out));
    return out;
}

static inline const char *ziclShimString(Zicl_Shim* shim) {
    const char *str = Zicl_ShimString(shim);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclGetString(Zicl_Val value, int *len) {
    const char *str = Zicl_GetString(value, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclShimGetString(Zicl_Shim *shim, int *len) {
    const char *str = Zicl_ShimGetString(shim, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline Zicl_Val ziclNewString(const char *ptr, int len) {
    Zicl_Val out; int rc = Zicl_NewString(&out, ptr, len);
    return folkZiclCheck(rc, out);
}

static inline Zicl_List *ziclNewList(const Zicl_Val *values, int n_values) {
    Zicl_List *list = Zicl_NewList(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

static inline Zicl_List *ziclNewListFromShims(Zicl_Shim *values, int n_values) {
    Zicl_List *list = Zicl_NewListFromShims(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

static inline void ziclListAppend(Zicl_List *list, Zicl_Val item) {
    folkZiclAssert(Zicl_ListAppend(list, item));
}

static inline Zicl_Dict *ziclNewDict(Zicl_Val *values, int n_values) {
    Zicl_Dict *dict = Zicl_NewDict(values, n_values);
    if (dict == NULL) folkZiclAssert(ZICL_OOM);
    return dict;
}

static inline void ziclDictPut(Zicl_Dict *dict, Zicl_Val key, Zicl_Val value) {
    folkZiclAssert(Zicl_DictPut(dict, key, value));
}

