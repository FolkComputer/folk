# Trie library

Implements the statement trie datatype and operations. This data
structure has 2 differences from the average trie you might have
seen before.

1. Its nodes are _entire tokens_, not characters.

   `someone -> wishes -> 30 -> is -> labelled -> Hello World`

   not

   `s -> o -> m -> e -> o -> n -> e -> SPACE -> w -> i -> ...`

   In other words, its alphabet is dynamic -- the set of all
   tokens that programs are using in statements -- not 26
   characters or whatever.

2. Both search patterns and nodes can contain 'wildcards'.

   This bidirectional matching is useful for incremental update.

## namespaces

### ctrie

Implementation of the trie in c, using `lib/c.tcl`.

#### Structs (in C)

- `trie_t`: has a `key` which is a pointer to a `Tcl_Obj`, a bool for whether it has a value, a 64 bit field for either a pointer (for example, to a reaction thunk) or a generational handle (for example, for a statement), a list of branches and the size of said list

#### Procs (in C)

- `create {}`: creates a trie and returns it
- `scanVariableC {Tcl_Obj* wordobj char* outVarName size_t sizeOutVarName}`: checks if the string in `wordobj` is viable??? (Not sure on this one)

These functions operate on the Tcl string representation of a
value _without_ coercing the value into a pure string first, so
they avoid shimmering / are more efficient than using Tcl
builtin functions like `regexp` and `string index`.

- `scanVariable {Tcl_Obj* wordobj}`: same as `scanVariable`, but just Tcl code
- `startsWithDollarSign {wordobj}`: returns whether `wordobj` starts with a '$'
- `addImpl {trie_t** trie int wordc Tcl_Obj** wordv uint64_t value}`: add the implementation `wordv[1..]` to `wordv[0]`, growing the trie if necessary
- `add {Tcl_Interp* interp trie_t** trie Tcl_Obj* clause uint64_t value}`: not sure, does something with adding an impl, and a tcl interpreter...
- `addWithVar {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause uint64_t value}`: same as above, but with a var?
- `removeImpl {trie_t* trie int wordc Tcl_Obj** wordv}`: remove the implementation of `wordv[0]`
- `remove {Tcl_Interp* interp trie_t* trie Tcl_Obj* clause}`: basically the same code as `add`, but with `removeImpl`
- `removeWithVar {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause}`: same as `addWithVar` but with `removeImpl`
- `lookupImpl {Tcl_Interp* interp uint64_t* results int* resultsidx size_t maxresults trie_t* trie int wordc Tcl_Obj** wordv}`: lookup the implementation of `wordv[0]`, storing a pointer in `results`
- `lookup {Tcl_Interp* interp uint64_t* results size_t maxresults trie_t* trie Tcl_Obj* pattern}`: same as `lookupImpl`, but returns the count and is safer?
- `lookupTclObjs {Tcl_Interp* interp trie_t* trie Tcl_Obj* pattern}`: looks up a Tcl object based on `pattern`, and return a Tcl list of the objects
- `tclify {trie_t* trie}`: returns a Tcl list based on `trie`

#### Proc

- `dot {trie}`: generate a dot graph of the trie

### trie

Compatibility with test/trie and old Tcl impl of trie.

Includes all of `ctrie`.
Renames `add` to `add_` and renames `addWithVar` to `add`.
Renames `remove` to `remove_` and renames `removeWithVar` to `remove`.
Renames `lookup` to `lookup_` and renames `lookupTclObjs` to `lookup`.

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)
