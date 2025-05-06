#define JIM_EMBEDDED
#include <jim.h>

#include <pthread.h>
#include <jim.h>
#include <stdio.h>

void* thread_interpreter(void* arg) {
    Jim_Interp* interp = Jim_CreateInterp();
    Jim_RegisterCoreCommands(interp);
    Jim_InitStaticExtensions(interp);
    
    const char* script = "puts \"Hello, world!\"";
    Jim_Eval(interp, script);
    
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
