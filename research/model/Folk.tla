------------------------------- MODULE Folk -------------------------------
(***************************************************************************)
(* The core of Folk's evaluator: statements with support counts, rules,    *)
(* matches, and the removal cascade.  What it keeps and what it leaves out *)
(* is listed at the end of this comment.                                   *)
(*                                                                         *)
(* A statement is identified by its clause, as in db.c, where inserting a  *)
(* clause that is already present reuses the statement and increments its  *)
(* parentCount.  count[c] is that parentCount; 0 means "not in the         *)
(* database".  gen[c] counts how many times the statement has been         *)
(* created, standing in for the generation in a StatementRef, so that a    *)
(* queued reaction to an earlier incarnation is recognised as stale.       *)
(*                                                                         *)
(* A rule is a When.  Its pattern and body are abstract: Matches(r, c)     *)
(* says whether rule r's pattern matches clause c, and Emits(r, c) is the  *)
(* set of clauses its body claims when run on c.  A model supplies both.   *)
(*                                                                         *)
(* Support for a statement comes from Hold! keys (the environment) and     *)
(* from matches that claimed it.  A match has one parent statement; when   *)
(* the parent goes, the match goes, and each of its children loses one     *)
(* parent (statementRemoveSelf -> matchRemoveSelf ->                       *)
(* statementDecrParentCountAndMaybeRemoveSelf in db.c).                    *)
(*                                                                         *)
(* Kept: reuse and reference counting; reactions queued as work items and  *)
(* run later; stale work items dropped; the cascade one match at a time;   *)
(* optionally, the gap between indexing a statement and scanning for the   *)
(* rules it should fire (AtomicInsert = FALSE), which is how folk.c does   *)
(* it.                                                                     *)
(*                                                                         *)
(* Left out: -keep timers, -atomically versions, Subscribe/Notify,         *)
(* destructors, removal of rules, bodies that are interrupted, and the     *)
(* second parent of a match (the rule statement itself).                   *)
(***************************************************************************)
EXTENDS Integers, FiniteSets, TLC

CONSTANTS
    Clause,          \* every clause the model can mention
    Rule,            \* rule names
    Key,             \* Hold! keys
    Matches(_, _),   \* Matches(r, c): does rule r's pattern match clause c?
    Emits(_, _),     \* Emits(r, c): clauses claimed by r's body run on c
    InitialRules,    \* rules in the database from the start
    Holdable,        \* clauses the environment may Hold!
    AtomicInsert,    \* TRUE: index and reaction scan are one step
    MaxMatches,      \* bound on match ids, to keep the model finite
    MaxGen,          \* bound on incarnations of one statement
    None             \* "this key holds nothing"

ASSUME None \notin Clause

VARIABLES
    held,        \* held[k]: the clause Hold! key k holds, or None
    count,       \* count[c]: parentCount of the statement with clause c
    gen,         \* gen[c]: incarnation number of that statement
    rules,       \* rules currently in the database
    matches,     \* matches[m]: [rule, parent, pgen, children] of match m
    nextMatch,   \* next unused match id
    dying,       \* matches whose parent is gone, children not yet released
    queue,       \* queue[<<r, c, g>>]: pending RUN_WHEN items (a bag)
    toReact      \* indexed, reaction scan still to run (AtomicInsert = FALSE)

vars == <<held, count, gen, rules, matches, nextMatch, dying, queue, toReact>>

Item == Rule \X Clause \X (0..MaxGen)

Init ==
    /\ held = [k \in Key |-> None]
    /\ count = [c \in Clause |-> 0]
    /\ gen = [c \in Clause |-> 0]
    /\ rules = InitialRules
    /\ matches = << >>
    /\ nextMatch = 1
    /\ dying = {}
    /\ queue = [i \in Item |-> 0]
    /\ toReact = {}

-----------------------------------------------------------------------------
(* Bookkeeping shared by every step that changes support counts. *)

\* The counts after adding one parent to each clause in plus and taking one
\* from each clause in minus.
Bump(plus, minus) ==
    [c \in Clause |-> count[c] + (IF c \in plus THEN 1 ELSE 0)
                               - (IF c \in minus THEN 1 ELSE 0)]

Enqueue(q, items) == [i \in Item |-> q[i] + (IF i \in items THEN 1 ELSE 0)]

\* newCount   the counts after the step
\* gone       matches deleted by the step
\* fresh      matches created by the step (a function, possibly empty)
\* q          the queue after the step's own dequeue, before new reactions
Effects(newCount, gone, fresh, q) ==
    LET born == {c \in Clause : count[c] = 0 /\ newCount[c] > 0}
        died == {c \in Clause : count[c] > 0 /\ newCount[c] = 0}
        newGen == [c \in Clause |-> IF c \in born THEN gen[c] + 1 ELSE gen[c]]
        kept == [m \in (DOMAIN matches) \ gone |-> matches[m]] @@ fresh
        \* A statement that goes takes its matches with it.
        doomed == {m \in DOMAIN kept :
                      kept[m].parent \in died /\ kept[m].pgen = gen[kept[m].parent]}
        \* A statement that arrives fires the rules whose pattern matches it.
        reactions == {<<r, c, newGen[c]>> : <<r, c>> \in
                         {rc \in rules \X born : Matches(rc[1], rc[2])}}
    IN  /\ \A c \in born : gen[c] < MaxGen
        /\ count' = newCount
        /\ gen' = newGen
        /\ matches' = kept
        /\ dying' = (dying \ gone) \cup doomed
        /\ IF AtomicInsert
              THEN /\ queue' = Enqueue(q, reactions)
                   /\ toReact' = toReact
              ELSE /\ queue' = q
                   /\ toReact' = toReact \cup {<<"stmt", c>> : c \in born}

-----------------------------------------------------------------------------
(* The environment: Hold! and its removal, and adding a rule. *)

\* Hold! -key k <c>: replaces whatever k held before.
Hold(k, c) ==
    /\ c \in Holdable
    /\ held[k] # c
    /\ held' = [held EXCEPT ![k] = c]
    /\ Effects(Bump({c}, IF held[k] = None THEN {} ELSE {held[k]}),
               {}, << >>, queue)
    /\ UNCHANGED <<rules, nextMatch>>

\* Hold! -key k {}
Unhold(k) ==
    /\ held[k] # None
    /\ held' = [held EXCEPT ![k] = None]
    /\ Effects(Bump({}, {held[k]}), {}, << >>, queue)
    /\ UNCHANGED <<rules, nextMatch>>

\* A When is added.  It fires for the statements already present.
AddRule(r) ==
    /\ r \notin rules
    /\ rules' = rules \cup {r}
    /\ IF AtomicInsert
          THEN /\ queue' = Enqueue(queue,
                      {<<r, c, gen[c]>> : c \in {c \in Clause :
                          count[c] > 0 /\ Matches(r, c)}})
               /\ toReact' = toReact
          ELSE /\ queue' = queue
               /\ toReact' = toReact \cup {<<"rule", r>>}
    /\ UNCHANGED <<held, count, gen, matches, nextMatch, dying>>

-----------------------------------------------------------------------------
(* The evaluator. *)

\* reactToNewStatement, as a step of its own when AtomicInsert = FALSE.
\* A new statement looks for rules; a new rule looks for statements.  Each
\* sees whatever is indexed at the moment it looks.
React(t) ==
    /\ t \in toReact
    /\ toReact' = toReact \ {t}
    /\ IF t[1] = "stmt"
          THEN queue' = Enqueue(queue,
                   IF count[t[2]] > 0
                      THEN {<<r, t[2], gen[t[2]]>> : r \in
                               {r \in rules : Matches(r, t[2])}}
                      ELSE {})
          ELSE queue' = Enqueue(queue,
                   {<<t[2], c, gen[c]>> : c \in {c \in Clause :
                       count[c] > 0 /\ Matches(t[2], c)}})
    /\ UNCHANGED <<held, count, gen, rules, matches, nextMatch, dying>>

\* A worker takes a RUN_WHEN item.  If the statement it refers to is gone
\* (or is a later incarnation) the item is dropped; otherwise the body runs
\* and its claims become children of a new match.
RunWhen(i) ==
    LET r == i[1]
        c == i[2]
        g == i[3]
        q == [queue EXCEPT ![i] = @ - 1]
    IN  /\ queue[i] > 0
        /\ IF count[c] = 0 \/ gen[c] # g \/ r \notin rules
              THEN /\ queue' = q
                   /\ UNCHANGED <<held, count, gen, rules, matches,
                                  nextMatch, dying, toReact>>
              ELSE /\ nextMatch <= MaxMatches
                   /\ Effects(Bump(Emits(r, c), {}), {},
                              nextMatch :> [rule |-> r, parent |-> c,
                                            pgen |-> g,
                                            children |-> Emits(r, c)],
                              q)
                   /\ nextMatch' = nextMatch + 1
                   /\ UNCHANGED <<held, rules>>

\* matchRemoveSelf: the match's children each lose a parent.
ReleaseMatch(m) ==
    /\ m \in dying
    /\ Effects(Bump({}, matches[m].children), {m}, << >>, queue)
    /\ UNCHANGED <<held, rules, nextMatch>>

Next ==
    \/ \E k \in Key, c \in Clause : Hold(k, c)
    \/ \E k \in Key : Unhold(k)
    \/ \E r \in Rule : AddRule(r)
    \/ \E t \in toReact : React(t)
    \/ \E i \in Item : RunWhen(i)
    \/ \E m \in dying : ReleaseMatch(m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties. *)

TypeOK ==
    /\ held \in [Key -> Clause \cup {None}]
    /\ count \in [Clause -> Nat]
    /\ gen \in [Clause -> 0..MaxGen]
    /\ rules \subseteq Rule
    /\ DOMAIN matches \subseteq 1..MaxMatches
    /\ dying \subseteq DOMAIN matches
    /\ queue \in [Item -> Nat]

Present == {c \in Clause : count[c] > 0}
Live == (DOMAIN matches) \ dying

\* I1.  Reference counts are exact: a statement's count is the number of
\* Hold! keys holding it plus the number of matches that claimed it.
CountsExact ==
    \A c \in Clause :
        count[c] = Cardinality({k \in Key : held[k] = c})
                   + Cardinality({m \in DOMAIN matches :
                                     c \in matches[m].children})

\* I2.  A live match's parent statement is in the database.
ParentsPresent ==
    \A m \in Live :
        count[matches[m].parent] > 0 /\ gen[matches[m].parent] = matches[m].pgen

\* Nothing queued, nothing half removed.
Quiescent ==
    /\ \A i \in Item : queue[i] = 0
    /\ toReact = {}
    /\ dying = {}

\* What Datalog says should be in the database: the least set containing
\* the held clauses and closed under the rules.
RECURSIVE Close(_)
Close(S) ==
    LET step == S \cup UNION {Emits(rc[1], rc[2]) : rc \in
                    {rc \in rules \X S : Matches(rc[1], rc[2])}}
    IN  IF step = S THEN S ELSE Close(step)
Derivable == Close({held[k] : k \in Key} \ {None})

\* P1.  Once things settle, the database is the Datalog fixpoint.
\* Holds for rule sets with no cycle.  Fails for cyclic ones, where a
\* statement can end up supported only by matches that descend from itself.
AgreesWithDatalog == Quiescent => Present = Derivable

\* P1a.  The half of P1 that always holds: nothing derivable is missing.
NothingMissing == Quiescent => Derivable \subseteq Present

\* P2.  A rule's body runs at most once per statement it matches.
\* Fails when AtomicInsert = FALSE: a new rule and a new statement can each
\* find the other.
AtMostOnce ==
    \A m1, m2 \in Live :
        (/\ matches[m1].rule = matches[m2].rule
         /\ matches[m1].parent = matches[m2].parent
         /\ matches[m1].pgen = matches[m2].pgen) => m1 = m2

\* P3.  Once things settle, every rule has run on every statement it matches.
Complete ==
    Quiescent =>
        \A r \in rules, c \in Present :
            Matches(r, c) =>
                \E m \in Live : matches[m].rule = r /\ matches[m].parent = c

-----------------------------------------------------------------------------
\* How TLC prints a state in an error trace (ALIAS in the .cfg files).
Pretty ==
    [held    |-> held,
     present |-> [c \in Present |-> count[c]],
     rules   |-> rules,
     matches |-> {<<m, matches[m].rule, matches[m].parent,
                    matches[m].children,
                    IF m \in dying THEN "dying" ELSE "live">> :
                     m \in DOMAIN matches},
     queue   |-> {<<i[1], i[2], queue[i],
                    IF count[i[2]] > 0 /\ gen[i[2]] = i[3]
                       THEN "current" ELSE "stale">> :
                     i \in {i \in Item : queue[i] > 0}},
     toReact |-> toReact]

\* The VIEW used to draw a state graph (MC_Tiny): incarnation numbers and
\* match ids are left out, so that going round the lifecycle returns to the
\* same picture instead of unrolling forever.
Shape ==
    [held    |-> held,
     present |-> [c \in Present |-> count[c]],
     matches |-> {<<matches[m].rule, matches[m].parent,
                    IF m \in dying THEN "dying" ELSE "live">> :
                     m \in DOMAIN matches},
     queue   |-> {<<i[1], i[2],
                    IF count[i[2]] > 0 /\ gen[i[2]] = i[3]
                       THEN "current" ELSE "stale">> :
                     i \in {i \in Item : queue[i] > 0}}]
=============================================================================
