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

#include <libzicl.h>

void folkZiclAssert(int rc) {
    if (rc != 0) {
        fprintf(stderr, "folk: could not allocate %s (zicl status %d)\n", rc);
        abort();
    }
}

Zicl_Value folkZiclCheck(int rc, Zicl_Value value) {
    folkZiclAssert(rc);
    return value;
}

const char *ziclString(Zicl_Value value) {
    const char *str = Zicl_String(value);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

int ziclEquals(Zicl_Value a, Zicl_Value b) {
    int out; folkZiclAssert(Zicl_Equals(a, b, &out));
    return out;
}

const char *ziclShimString(Zicl_Shimmerable *shim) {
    const char *str = Zicl_ShimString(shim);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

const char *ziclGetString(Zicl_Value value, int *len) {
    const char *str = Zicl_GetString(value, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

const char *ziclShimGetString(Zicl_Shimmerable *shim, int *len) {
    const char *str = Zicl_ShimGetString(shim, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

Zicl_Value ziclNewString(const char *ptr, int len) {
    Zicl_Value out; int rc = Zicl_NewString(&out, ptr, len);
    return folkZiclCheck(rc, out);
}

Zicl_Value ziclValuePrintf(const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buf[10000]; vsnprintf(buf, 10000, format, args);
    va_end(args);
    return ziclNewString(buf, -1);
}

Zicl_List *ziclNewList(Zicl_Value *values, int n_values) {
    Zicl_List *list = Zicl_NewList(values, n_values);
    folkZiclAssert(list == NULL ? ZICL_OOM : ZICL_OK);
    return list;
}

Zicl_List *ziclNewListFromShimmerables(Zicl_Shimmerable *values, int n_values) {
    Zicl_List *list = Zicl_NewListFromShimmerables(values, n_values);
    folkZiclAssert(list == NULL ? ZICL_OOM : ZICL_OK);
    return list;
}

void ziclListAppend(Zicl_List *list, Zicl_Value item) {
    folkZiclAssert(Zicl_ListAppend(list, item));
}

Zicl_Dict *ziclNewDict(Zicl_Value *values, int n_values) {
    Zicl_Dict *dict = Zicl_NewDict(values, n_values);
    folkZiclAssert(dict == NULL ? ZICL_OOM : ZICL_OK);
    return dict;
}

void ziclDictPut(Zicl_Dict *dict, Zicl_Value key, Zicl_Value value) {
    folkZiclAssert(Zicl_DictPut(dict, key, value));
}

