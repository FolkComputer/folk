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

void folkZiclAssert(int rc);
Zicl_Val folkZiclCheck(int rc, Zicl_Val value);

const char *ziclString(Zicl_Val value);
const char *ziclListString(Zicl_List* list);
int ziclEquals(Zicl_Val a, Zicl_Val b);
const char *ziclShimString(Zicl_Shim* shim);
const char *ziclGetString(Zicl_Val value, int *len);
const char *ziclShimGetString(Zicl_Shim *shim, int *len);
Zicl_Val ziclNewString(const char *ptr, int len);
Zicl_List *ziclNewList(const Zicl_Val *values, int n_values);
Zicl_List *ziclNewListOwning(Zicl_Val *values, int n_values);
Zicl_List *ziclNewListFromShims(Zicl_Shim *values, int n_values);
void ziclListAppend(Zicl_List *list, Zicl_Val item);
void ziclListAppendOwning(Zicl_List *list, Zicl_Val item);
Zicl_Dict *ziclNewDict(Zicl_Val *values, int n_values);
void ziclDictPut(Zicl_Dict *dict, Zicl_Val key, Zicl_Val value);
Zicl_OptVal ziclDictGetNoFollow(const Zicl_Dict *dict, const char *key);
bool ziclDictGetStringNoFollow(const Zicl_Dict *dict, const char *key, const char **out);
Zicl_RetCode ziclDictGetIntNoFollow(Zicl_Interp *interp, const Zicl_Dict *dict, const char *key, int *out);
Zicl_RetCode ziclDictGetLongNoFollow(Zicl_Interp *interp, const Zicl_Dict *dict, const char *key, long *out);
Zicl_RetCode ziclShimDictGetInt(Zicl_Interp *interp, Zicl_Shim *dictShim, const char *key, int *out);
Zicl_RetCode ziclShimDictGetLong(Zicl_Interp *interp, Zicl_Shim *dictShim, const char *key, long *out);
void ziclDictRemove(Zicl_Dict *dict, const char *key);
