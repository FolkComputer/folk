---------------------------- MODULE MC_Cycle ----------------------------
(* A program with a cycle:                                                 *)
(*     When a { Claim b }        (r1)                                      *)
(*     When b { Claim c }        (r2)                                      *)
(*     When c { Claim b }        (r3)                                      *)
(* Hold! a, let it settle, clear the hold: b and c stay, each supported    *)
(* only by the match on the other.  AgreesWithDatalog fails; the reference *)
(* counts stay exact, which is why nothing in the runtime notices.         *)
EXTENDS Folk
CONSTANTS a, b, c, r1, r2, r3

CycleMatches(r, x) == (r = r1 /\ x = a) \/ (r = r2 /\ x = b) \/ (r = r3 /\ x = c)
CycleEmits(r, x) == IF r = r1 THEN {b} ELSE IF r = r2 THEN {c} ELSE {b}
=============================================================================
