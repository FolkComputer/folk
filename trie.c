typedef struct Clause {
    int32_t nterms;
    char* terms[];
} Clause;

typedef struct Trie {
    char* key;

    // We generally store a pointer (for example, to a reaction thunk)
    // in this 64-bit value slot.
    bool hasValue;
    uint64_t value;

    int32_t nbranches;
    Trie* branches[];
} Trie;
#define SIZEOF_TRIE(nbranches) (sizeof(Trie) + (nbranches)*sizeof(Trie*))

Trie* trieCreate() {
    size_t size = sizeof(Trie) + 10*sizeof(Trie*);
    Trie* ret = (Trie*) calloc(size, 1);
    *ret = (Trie) {
        .key = NULL,
        .hasValue = false,
        .value = 0,
        .nbranches = 10
    };
    return ret;
} 

Trie* trieAddImpl(const Trie* trie, int32_t nterms, char* terms[], uint64_t value) {
    char* term = terms[0];

    Trie* match = NULL;

    int j;
    for (j = 0; j < trie->nbranches; j++) {
        Trie* branch = trie->branches[j];
        if (branch == NULL) { break; }

        if (branch->key == term || strcmp(branch->key, term) == 0) {
            match = branch;
            break;
        }
    }

    if (match == NULL) { // add new branch
        if (j == trie->nbranches) {
            // We're out of room; need to grow trie.
            Trie* old = trie;
            trie = malloc(SIZEOF_TRIE(2*trie->nbranches));
            memcpy(trie, old, SIZEOF_TRIE(old->nbranches));

            trie->nbranches *= 2;
            memset(trie->branches[j], 0, (trie->nbranches/2)*sizeof(Trie*));
            // TODO: Free old.
        }

        Trie* branch = calloc(SIZEOF_TRIE(10), 1);
        branch->key = word;
        Tcl_IncrRefCount(branch->key);
        branch->value = 0;
        branch->hasValue = false;
        branch->nbranches = 10;

        // TODO: Need to change trie if branch changes.
        trie->branches[j] = branch;
        match = trie->branches[j];
    }

    return trieAddImpl(trie, nterms - 1, terms + 1, value);
}

Trie* trieAdd(Trie* trie, Clause* c, uint64_t value) {
    return trieAddImpl(trie, c->nterms, c->terms, value);
}

