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

static inline void folkZiclAssert(int rc) {
    if (rc != 0) {
        fprintf(stderr, "folk: failed to perform operation (zicl status %d)\n", rc);
        abort();
    }
}

static inline Zicl_Value folkZiclCheck(int rc, Zicl_Value value) {
    folkZiclAssert(rc);
    return value;
}

static inline const char *ziclString(Zicl_Value value) {
    const char *str = Zicl_String(value);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclListString(Zicl_List* list) {
    const char *str = Zicl_String(Zicl_BoxList(list));
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline int ziclEquals(Zicl_Value a, Zicl_Value b) {
    int out; folkZiclAssert(Zicl_Equals(a, b, &out));
    return out;
}

static inline const char *ziclShimString(Zicl_Shimmerable* shim) {
    const char *str = Zicl_ShimString(shim);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclGetString(Zicl_Value value, int *len) {
    const char *str = Zicl_GetString(value, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline const char *ziclShimGetString(Zicl_Shimmerable *shim, int *len) {
    const char *str = Zicl_ShimGetString(shim, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

static inline Zicl_Value ziclNewString(const char *ptr, int len) {
    Zicl_Value out; int rc = Zicl_NewString(&out, ptr, len);
    return folkZiclCheck(rc, out);
}

static inline Zicl_List *ziclNewList(const Zicl_Value *values, int n_values) {
    Zicl_List *list = Zicl_NewList(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

static inline Zicl_List *ziclNewListFromShimmerables(Zicl_Shimmerable *values, int n_values) {
    Zicl_List *list = Zicl_NewListFromShimmerables(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

static inline void ziclListAppend(Zicl_List *list, Zicl_Value item) {
    folkZiclAssert(Zicl_ListAppend(list, item));
}

static inline Zicl_Dict *ziclNewDict(Zicl_Value *values, int n_values) {
    Zicl_Dict *dict = Zicl_NewDict(values, n_values);
    if (dict == NULL) folkZiclAssert(ZICL_OOM);
    return dict;
}

static inline void ziclDictPut(Zicl_Dict *dict, Zicl_Value key, Zicl_Value value) {
    folkZiclAssert(Zicl_DictPut(dict, key, value));
}

