---------------------------- MODULE MC_Chain ----------------------------
(* An acyclic program:                                                     *)
(*     When a { Claim b }        (r1)                                      *)
(*     When b { Claim c }        (r2)                                      *)
(* with the environment free to Hold! a or b under two keys.  Every        *)
(* property of Folk.tla holds.                                             *)
EXTENDS Folk
CONSTANTS a, b, c, r1, r2

ChainMatches(r, x) == (r = r1 /\ x = a) \/ (r = r2 /\ x = b)
ChainEmits(r, x) == IF r = r1 THEN {b} ELSE {c}
=============================================================================
