# research/

Tools and results behind [`FINDINGS.md`](FINDINGS.md) and
[`docs/pl-research.md`](../docs/pl-research.md). Nothing in this directory is
loaded by Folk; it only reads the tree and runs the `folk` binary.

Everything is Tcl (run with the vendored `jimsh`), C, or shell, apart from the
TLA+ model, which is in the model checker's own language.

| Directory | What it is | Run it with |
|---|---|---|
| `extract/` | A parser for Folk programs that evaluates nothing, and the static analysis built on it: corpus metrics, grammar and pattern lints, the graph of which rule's statements reach which rule. | `make -C research/extract` |
| `model/` | A TLA+ model of statements, matches and the removal cascade, with the configurations that pass and the two that fail on purpose. | `make -C research/model` |
| `verify/` | Sanitizer and Tracy builds of `folk` next to the normal one, the test suite run under them, a CBMC harness and two GenMC harnesses. | see the scripts and `Makefile`s there |
| `repro/` | A small Folk program for each of the defects E1 to E13 in `FINDINGS.md` (two for E10), each saying in its header what was expected and what happens. | `research/repro/run.sh` |
| `bench/` | Headless benchmarks, wrappers that profile them with perf + FlameGraph and with Tracy, and one what-if patch. | `research/bench/run-all.sh` |
| `out/` | What all of the above produced on the machine described in `FINDINGS.md`. Generated; safe to delete and rebuild. | |

`setup.sh` installs the tools (Graphviz, perf, FlameGraph, Tracy's capture
tools, TLA+, CBMC, GenMC) on Ubuntu 24.04 and builds the instrumented variants.
