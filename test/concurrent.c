#define JIM_EMBEDDED
#include <jim.h>

#include <pthread.h>
#include <jim.h>
#include <stdio.h>

Jim_Obj* _Atomic sharedObj = NULL;

void* thread_interpreter(void* arg) {
    Jim_Interp* interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);

    if (sharedObj == NULL) {
        const char* script = "return {A B C}";
        Jim_Eval(interp, script);
        sharedObj = Jim_GetResult(interp);
        // this is needed since we're retaining the ref
        Jim_IncrRefCount(sharedObj); 

    } else {
        printf("sharedObj: %p, typePtr: %p, rc: %d\n",
               sharedObj,
               sharedObj->typePtr, sharedObj->refCount);
        const char* lambda = "{sharedObj} {\
llength $sharedObj; \
puts \"sharedObj is ($sharedObj)\"; \
return $sharedObj; \
}";
        Jim_Obj* objv[] = {
            Jim_NewStringObj(interp, "apply", -1),
            Jim_NewStringObj(interp, lambda, -1),
            sharedObj
        };
        Jim_EvalObjVector(interp, sizeof(objv)/sizeof(objv[0]), objv);
        printf("  -> result: %p\n", Jim_GetResult(interp));
    }
    
    Jim_FreeInterp(interp);
    return NULL;
}

int main() {
    pthread_t threads[10];
    
    for (int i = 0; i < 10; i++) {
        pthread_create(&threads[i], NULL, thread_interpreter, NULL);
    }
    
    for (int i = 0; i < 10; i++) {
        pthread_join(threads[i], NULL);
    }
    
    return 0;
}
