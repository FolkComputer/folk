#include "zicl-helpers.h"

void folkZiclAssert(int rc) {
    if (rc != 0) {
        fprintf(stderr, "folk: failed to perform operation (zicl status %d)\n", rc);
        abort();
    }
}

Zicl_Val folkZiclCheck(int rc, Zicl_Val value) {
    folkZiclAssert(rc);
    return value;
}

const char *ziclString(Zicl_Val value) {
    const char *str = Zicl_String(value);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

const char *ziclListString(Zicl_List* list) {
    const char *str = Zicl_String(Zicl_BoxList(list));
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

int ziclEquals(Zicl_Val a, Zicl_Val b) {
    int out; folkZiclAssert(Zicl_Equals(a, b, &out));
    return out;
}

const char *ziclShimString(Zicl_Shim* shim) {
    const char *str = Zicl_ShimString(shim);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

const char *ziclGetString(Zicl_Val value, int *len) {
    const char *str = Zicl_GetString(value, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

const char *ziclShimGetString(Zicl_Shim *shim, int *len) {
    const char *str = Zicl_ShimGetString(shim, len);
    if (!str) folkZiclAssert(ZICL_OOM);
    return str;
}

Zicl_Val ziclNewString(const char *ptr, int len) {
    Zicl_Val out; int rc = Zicl_NewString(&out, ptr, len);
    return folkZiclCheck(rc, out);
}

Zicl_List *ziclNewList(const Zicl_Val *values, int n_values) {
    Zicl_List *list = Zicl_NewList(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

Zicl_List *ziclNewListOwning(Zicl_Val *values, int n_values) {
    Zicl_List *list = Zicl_NewList(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    Zicl_DropRefArrayItems(values, n_values);
    return list;
}

Zicl_List *ziclNewListFromShims(Zicl_Shim *values, int n_values) {
    Zicl_List *list = Zicl_NewListFromShims(values, n_values);
    if (list == NULL) folkZiclAssert(ZICL_OOM);
    return list;
}

void ziclListAppend(Zicl_List *list, Zicl_Val item) {
    folkZiclAssert(Zicl_ListAppend(list, item));
}

void ziclListAppendOwning(Zicl_List *list, Zicl_Val item) {
    folkZiclAssert(Zicl_ListAppend(list, item));
    Zicl_DropRef(item);
}

Zicl_Dict *ziclNewDict(Zicl_Val *values, int n_values) {
    Zicl_Dict *dict = Zicl_NewDict(values, n_values);
    if (dict == NULL) folkZiclAssert(ZICL_OOM);
    return dict;
}

void ziclDictPut(Zicl_Dict *dict, Zicl_Val key, Zicl_Val value) {
    folkZiclAssert(Zicl_DictPut(dict, key, value));
}

Zicl_OptVal ziclDictGetNoFollow(const Zicl_Dict *dict, const char *key) {
    Zicl_OptVal out = ZICL_NONE;
    folkZiclAssert(Zicl_DictGetNoFollow(dict, Zicl_InternStr(key), &out));
    return out;
}

bool ziclDictGetStringNoFollow(const Zicl_Dict *dict, const char *key, const char **out) {
    Zicl_OptVal val = ziclDictGetNoFollow(dict, key);
    if (Zicl_IsNone(val)) return false;
    *out = ziclString(Zicl_Unwrap(val));
    return true;
}

Zicl_RetCode ziclDictGetIntNoFollow(Zicl_Interp *interp, const Zicl_Dict *dict, const char *key, int *out) {
    Zicl_OptVal val = ziclDictGetNoFollow(dict, key);
    if (Zicl_IsNone(val)) return ZICL_OK;
    Zicl_Shim shim = Zicl_NewShim(Zicl_Unwrap(val));
    defer { Zicl_ShimDiscardChanges(&shim); }
    return Zicl_GetInt(interp, &shim, out);
}

Zicl_RetCode ziclDictGetLongNoFollow(Zicl_Interp *interp, const Zicl_Dict *dict, const char *key, long *out) {
    Zicl_OptVal val = ziclDictGetNoFollow(dict, key);
    if (Zicl_IsNone(val)) return ZICL_OK;
    Zicl_Shim shim = Zicl_NewShim(Zicl_Unwrap(val));
    defer { Zicl_ShimDiscardChanges(&shim); }
    return Zicl_GetLong(interp, &shim, out);
}

Zicl_RetCode ziclShimDictGetInt(Zicl_Interp *interp, Zicl_Shim *dictShim, const char *key, int *out) {
    Zicl_OptVal opt;
    Zicl_RetCode rc = Zicl_ShimDictGet(interp, dictShim, Zicl_InternStr(key), &opt);
    if (rc != ZICL_OK) return rc;
    if (!Zicl_IsSome(opt)) return ZICL_ERR;
    Zicl_Shim valShim = Zicl_NewShim(Zicl_Unwrap(opt));
    defer { Zicl_ShimDiscardChanges(&valShim); }
    return Zicl_GetInt(interp, &valShim, out);
}

Zicl_RetCode ziclShimDictGetLong(Zicl_Interp *interp, Zicl_Shim *dictShim, const char *key, long *out) {
    Zicl_OptVal opt;
    Zicl_RetCode rc = Zicl_ShimDictGet(interp, dictShim, Zicl_InternStr(key), &opt);
    if (rc != ZICL_OK) return rc;
    if (!Zicl_IsSome(opt)) return ZICL_ERR;
    Zicl_Shim valShim = Zicl_NewShim(Zicl_Unwrap(opt));
    defer { Zicl_ShimDiscardChanges(&valShim); }
    return Zicl_GetLong(interp, &valShim, out);
}

void ziclDictRemove(Zicl_Dict *dict, const char *key) {
    folkZiclAssert(Zicl_DictRemove(dict, Zicl_InternStr(key), NULL));
}
