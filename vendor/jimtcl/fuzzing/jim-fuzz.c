#include <string.h>
#include <stdint.h>

#include "../jim.h"
#include "../jimautoconf.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    int errorCode = 0;

    Jim_Interp *interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);

    // I'd rather not the fuzzer mess around with the file system, lol
    // if (Jim_InitStaticExtensions(interp) != JIM_OK) {
    //     JimPrintErrorMessage(interp);
    // }

    // make sure data ends with null
    char *dataWithNull = Jim_Alloc(size + 1);
    memcpy(dataWithNull, data, size);
    dataWithNull[size] = '\0';

    if (!Jim_IsStringValidScript(interp, dataWithNull)) {
        errorCode = -1;
        goto err;
    }

    Jim_Eval(interp, dataWithNull);

err:
    Jim_FreeInterp(interp);
    Jim_Free(dataWithNull);

    return errorCode;
}