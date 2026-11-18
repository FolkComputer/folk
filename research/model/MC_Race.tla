----------------------------- MODULE MC_Race -----------------------------
(* One rule, `When a { Claim b }`, added while the environment holds a,    *)
(* with indexing and the reaction scan as separate steps (as in folk.c:    *)
(* dbInsertOrReuseStatement, then reactToNewStatement).  The rule's scan   *)
(* finds the statement and the statement's scan finds the rule, so the     *)
(* body is queued twice.  AtMostOnce fails.                                *)
EXTENDS Folk
CONSTANTS a, b, r1

RaceMatches(r, x) == r = r1 /\ x = a
RaceEmits(r, x) == {b}
=============================================================================
