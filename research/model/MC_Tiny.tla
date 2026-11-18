----------------------------- MODULE MC_Tiny -----------------------------
(* The smallest program there is, `When a { Claim b }`, with one Hold! key *)
(* that the environment sets to a and clears.  Small enough to draw: the   *)
(* state graph TLC dumps for this model is the statement and match         *)
(* lifecycle figure in FINDINGS.md.                                        *)
EXTENDS Folk
CONSTANTS a, b, r1, k1

TinyMatches(r, x) == x = a
TinyEmits(r, x) == {b}

\* For the figure only: the environment waits for things to settle before
\* it holds a again.  Without this the graph has 35 states instead of 6,
\* the extra ones being re-holds that overlap an unfinished removal.
CalmHold == (held[k1] = None /\ held'[k1] # None) => Quiescent
=============================================================================
