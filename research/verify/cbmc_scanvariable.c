// CBMC harness for trieScanVariable (trie.c).
//
// Asks whether any term of up to 110 bytes can make trieScanVariable write
// outside the 100-byte buffer that every caller passes it.
//
//   make -C research/verify cbmc
//
// Expected with the code as it is: FAILED, with a counterexample in which
// the term is "/" + 100 bytes + "/" and the terminating NUL goes to
// outVarName[100].

#include "trie.c"

int nondet_int(void);
char nondet_char(void);

int main(void) {
    int len = nondet_int();
    __CPROVER_assume(len >= 0 && len <= 110);

    Term *term = malloc(sizeof(int32_t) + len);
    __CPROVER_assume(term != NULL);
    term->len = len;
    for (int i = 0; i < len; i++) { term->buf[i] = nondet_char(); }

    char varName[100];
    trieScanVariable(term, varName, sizeof(varName));
    return 0;
}
