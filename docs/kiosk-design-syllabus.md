# Kiosk Design

**SVA MA in Products of Design — Elective Studio**
**Semester:** Fall · 15 weeks · 3 credits
**Meets:** Thursdays, 12:00–2:50pm, 136 W 21st St, 7th Floor Studio
**Instructor:** TBD · Office hours by appointment
**Course site & crit archive:** posted on first day of class

---

## Course description

The kiosk is the most public computer there is. It has no owner and a
thousand users a day. It must explain itself in five seconds to someone
in a hurry, in the rain, holding a coffee, who has never seen it before
and will never read a manual. It gets kicked, spilled on, rebooted by
strangers, and left running for years. It is also one of the last
computers that lives in *shared physical space* — a machine you walk up
to, together, in public.

This studio treats the kiosk as a complete design problem: industrial
design (enclosure, ergonomics, materials, vandal-resistance), interaction
design (walk-up-and-use interfaces, session design, accessibility),
service design (the kiosk as one touchpoint in a larger system, including
the technician who services it), and civic design (trust, surveillance,
and who a public machine actually serves).

New York City is our lab. The MTA vending machine, the LinkNYC totem, the
pharmacy self-checkout, the bodega ATM, the halal cart's Square stand, the
photo booth, the library catalog terminal, and the voting machine are all
a subway ride away. We will study them, break them down, and then design
and deploy our own.

The class culminates in a **working kiosk installed in a real public or
semi-public space for at least one day**, observed in use by strangers.

## Learning objectives

By the end of the semester, students will be able to:

1. **Read a kiosk** — analyze an unattended machine as an integrated
   artifact of hardware, software, service, and policy, and articulate
   why it succeeds or fails for its actual users.
2. **Design for the walk-up user** — create interfaces that require zero
   onboarding, degrade gracefully, respect a stranger's time and privacy,
   and meet accessibility standards (ADA reach ranges, WCAG, one-switch
   and non-visual access).
3. **Design the enclosure as honestly as the screen** — make informed
   decisions about materials, sightlines, weather, heat, cable runs,
   mounting, and abuse-resistance.
4. **Prototype cheaply and test in the wild** — use cardboard,
   Wizard-of-Oz techniques, projection, and off-the-shelf hardware to get
   a kiosk in front of real strangers early and often.
5. **Argue a civic position** — take a defensible stance on data
   collection, advertising, and public benefit in shared machines, and
   embody that stance in a design.

## Prerequisites

None beyond program admission. Comfort with basic prototyping (foamcore,
laser cutting) is assumed; no coding experience required, though students
who code are encouraged to use it. Teams will be balanced so that every
group has fabrication and screen-prototyping capability.

---

## Course structure

Three projects of increasing ambition, threaded with field visits,
readings, and guest critics.

- **Project 1 — The Kiosk Autopsy** (weeks 1–5, individual)
- **Project 2 — Fix a Broken Kiosk** (weeks 5–9, pairs)
- **Project 3 — A Kiosk for the Public** (weeks 9–15, teams of 3–4)

### Weekly schedule

#### Week 1 — What is a kiosk?
A history of unattended machines: the Ottoman *köşk*, the Parisian
newsstand and Morris column, the automat, the phone booth, the vending
machines of Japan, the ATM (Shepherd-Barron, 1967), the photo booth, the
airport check-in terminal, the McDonald's order kiosk, LinkNYC. What
survives, what dies, and why. The kiosk as the opposite of the phone:
place-bound, shared, ownerless.
*In class:* course overview; kiosk taxonomy exercise.
*Assign:* Project 1; Kiosk Safari logbook (runs all semester).
*Read:* Weiser, "The Computer for the 21st Century"; Mattern, "Interfacing Urban Intelligence."

#### Week 2 — Kiosk Safari (field day)
Full session in the field, in small groups: Penn Station / Herald Square
circuit — MTA fare machines, LinkNYC, pharmacy self-checkout, Amtrak
Quik-Trak, parking meters, a photo booth. Structured observation
protocol: time a stranger's session, log failure and abandonment,
photograph wear patterns (grime is data — it shows you where people
actually touch).
*Assign:* field notes due week 3.
*Read:* Suchman, *Plans and Situated Actions*, ch. 1 & the photocopier
studies (excerpt).

#### Week 3 — The walk-up-and-use problem
Interaction design for strangers: the five-second contract, attract
loops and idle states, session boundaries (when does "my turn" start and
end?), timeout design, error recovery without a staff member, language
selection, the receipt as interface. Why kiosk UIs are the hardest UIs.
*In class:* safari debrief; heuristic evaluation of MTA fare machine flows.
*Read:* Norman, *The Design of Everyday Things*, ch. 1–2; Chisnell &
Quesenbery, *Anywhere Ballot* field guides (excerpt).

#### Week 4 — The body at the machine
Ergonomics and accessibility as form-givers: ADA reach ranges and
approach clearances, wheelchair and standing dual use, screen height and
glare, audio jacks and tactile keypads for non-visual access, one-switch
access, designing for gloves, children, and carried bags. Guest critic:
an accessibility consultant or blind kiosk user (schedule permitting).
*In class:* full-scale cardboard mockup exercise — everyone builds a
reach-range-correct front panel in one hour.
*Read:* U.S. Access Board §707 (self-service machines); Hendren, *What
Can a Body Do?*, introduction.

#### Week 5 — Project 1 crit: The Kiosk Autopsy
Each student presents a complete teardown-style analysis of one existing
NYC kiosk: its hardware, software flows, service ecosystem, failure
modes, wear patterns, and a one-page verdict — *who is this machine
actually for?*
*Assign:* Project 2 (pairs): choose a demonstrably broken kiosk
experience from the autopsies and redesign it.

#### Week 6 — The enclosure
Industrial design for public machines: sheet metal vs. injection
molding, IP ratings and weather, thermal management (screens cook in
sunlight), anti-vandalism and tamper resistance, cable runs and power in
the wild, mounting and ballast, sightlines and approach geometry, the
service door as a first-class interface (the technician is a user too).
*In class:* teardown of a donated/surplus kiosk or ATM enclosure.
*Read:* selections on street furniture from Gehl, *Life Between
Buildings*; case study: CityBench and LinkNYC hardware RFPs.

#### Week 7 — Software for machines nobody owns
Kiosk-mode software patterns: locked-down OSes, watchdogs and automatic
recovery, remote fleet management, offline-first design, payment
integration, printing (the most failure-prone peripheral in the world).
Privacy by architecture: what a public machine should refuse to
remember. Session data, cameras, and the difference between *counting*
and *identifying*.
*In class:* prototype an attract loop and a full session flow in the
tool of your choice (Figma, ProtoPie, web, or paper).
*Read:* Schüll, *Addiction by Design*, ch. on machine-gambler ergonomics
(what happens when kiosk design is *too* effective); LinkNYC privacy
policy vs. its critics (NYCLU letters).

#### Week 8 — Prototyping in public + guest session
Wizard-of-Oz kiosks, cardboard fronts with humans behind them,
projection as instant kiosk. Guest session with practitioners from the
physical-computing world (e.g., **Folk Computer** — projector-camera
systems that make ordinary surfaces and objects computational) on what
becomes possible when the interface escapes the touchscreen entirely:
tangible controls, paper as UI, machines you operate with objects
instead of menus.
*In class:* pairs run 10-minute Wizard-of-Oz tests of Project 2
prototypes on volunteers from other departments.
*Read:* Victor, "Seeing Spaces" (talk); Folk Computer / Dynamicland
materials.

#### Week 9 — Project 2 crit: Fix a Broken Kiosk
Pairs present before/after: evidence of the failure, the redesign
(enclosure and interface), and a tested prototype of the critical flow.
External critic from a design consultancy or the MTA/civic tech world.
*Assign:* Project 3 (teams): design, build, and deploy a kiosk for a
real public need, installed in the wild for at least one day.

#### Week 10 — The civic machine
Trust, surveillance, and public benefit. Who pays for a "free" kiosk?
Advertising-funded street furniture, data as rent, the voting machine as
the highest-stakes kiosk (butterfly ballots, Help America Vote Act, why
paper persists). Kiosks that replace people vs. kiosks that extend
services no person was providing. Municipal procurement and why so many
civic kiosks are bad.
*Read:* Mattern, *A City Is Not a Computer* (excerpt); Chisnell on
ballot design; case study: Intersection/Sidewalk Labs and LinkNYC.

#### Week 11 — The kiosk as service
Service design week: the kiosk as one touchpoint in a journey. Blueprint
the whole system — restocking, cash collection, cleaning, software
updates, the phone number on the sticker, what happens when it breaks at
2am. Maintenance as design material; designing for the fleet, not the
unit.
*In class:* teams service-blueprint their Project 3 concept end-to-end.
*Read:* Polaine, Løvlie & Reason, *Service Design* (excerpt); "The
Maintainers" manifesto (Russell & Vinsel).

#### Week 12 — Studio + technical reviews
Full working session. Rolling desk crits on enclosures, flows, and
deployment plans. Site permissions must be locked this week (campus
lobby, partner café, library, community space, or a sanctioned sidewalk
activation).

#### Week 13 — Studio + dress rehearsal
Kiosks fully assembled and run in the studio hallway for a day.
Instrumentation check: how will you observe and count real use without
surveilling people? Fix what the hallway breaks.

#### Week 14 — Deployment week
Kiosks live in their real sites. Teams observe in shifts, log sessions,
photograph, interview willing users. Instructor site visits.

#### Week 15 — Final crit & public exhibition
Teams present the kiosk itself plus evidence from the field: usage
data, observed behavior, failures, and what they'd change for version
two. Guest critics from industrial design, civic tech, and interaction
design. Kiosks exhibited running in the 7th-floor commons for the
program's end-of-semester open studio.

---

## Projects & deliverables

### Project 1 — The Kiosk Autopsy *(individual, 20%)*
A rigorous field analysis of one existing NYC kiosk. Deliverables:
annotated photo study (including wear patterns), reconstructed
interaction flow diagram, service-ecosystem map, accessibility audit
against §707, and a one-page verdict. Format: 10-minute presentation +
PDF dossier.

### Project 2 — Fix a Broken Kiosk *(pairs, 25%)*
A grounded redesign of a demonstrably failing kiosk experience.
Deliverables: evidence of failure (field data), redesigned enclosure
(scale model or full-size cardboard) and interface (clickable or
Wizard-of-Oz prototype of the critical path), one round of user testing
with at least 5 strangers, before/after presentation.

### Project 3 — A Kiosk for the Public *(teams of 3–4, 35%)*
Design, build, and deploy an original kiosk serving a real need, live in
a public or semi-public site for at least one full day. It may be
screen-based, tangible, paper-emitting, projection-based, or none of the
above — but it must work unattended, be usable by a stranger with no
instruction, and embody an explicit position on privacy and public
benefit. Deliverables: the working kiosk, service blueprint, deployment
field report with observed-use evidence, and final presentation.

### Kiosk Safari logbook *(individual, 10%)*
A running field journal, all semester: at least one new kiosk
observation per week (photo + 100 words). Due at final crit.

### Participation & critique *(10%)*
Studio presence, quality of feedback in crits, field-day engagement.

## Grading

| Component | Weight |
|---|---|
| Project 1 — Kiosk Autopsy | 20% |
| Project 2 — Fix a Broken Kiosk | 25% |
| Project 3 — A Kiosk for the Public | 35% |
| Kiosk Safari logbook | 10% |
| Participation & critique | 10% |

Late work drops one letter grade per week. A missed crit cannot be made
up except for documented emergencies — crits are the class.

## Materials & budget

Cardboard, foamcore, and shop materials as needed (typical semester
spend $60–120 individually). Project 3 teams receive a **$250 hardware
budget** from the course for screens, single-board computers, printers,
buttons, and enclosure materials; scavenging surplus hardware is
encouraged and will be celebrated. The studio provides a shared kit:
two Raspberry Pis, a thermal receipt printer, an arcade-button set, a
short-throw projector, and a webcam.

## Readings

All excerpts provided as PDFs on the course site. Core books worth
owning:

- Don Norman, *The Design of Everyday Things* (revised ed.)
- Lucy Suchman, *Plans and Situated Actions* / *Human-Machine Reconfigurations*
- Shannon Mattern, *A City Is Not a Computer*
- Natasha Dow Schüll, *Addiction by Design*
- Sara Hendren, *What Can a Body Do?*
- Jan Gehl, *Life Between Buildings*
- Polaine, Løvlie & Reason, *Service Design: From Insight to Implementation*

Shorter pieces: Weiser, "The Computer for the 21st Century"; Victor,
"Seeing Spaces"; Russell & Vinsel, "Hail the Maintainers"; U.S. Access
Board §707; Chisnell & Quesenbery, *Anywhere Ballot* research; LinkNYC
privacy debate primary sources.

## Policies

**Attendance.** This is a studio; presence is the work. Two unexcused
absences affect the participation grade; four risk course failure, per
SVA policy.

**Field conduct.** We observe machines, not people. Never photograph an
identifiable person at a kiosk without consent; never interfere with
someone completing a real task (buying a MetroCard is not a game to
them). During deployments, all data collection must be disclosed on the
kiosk itself in plain language — practice the privacy stance you design.

**Accessibility.** Students who need accommodations should contact SVA
Disability Resources; come talk to me as well — this class is *about*
designing for every body, and your accommodations are part of the studio's
knowledge.

**Tools & AI.** Any tool is fair game for production work (CAD, code
assistants, image generation) with disclosure in your process
documentation. Field observations, user testing, and your design
judgment must be your own — the whole point of this class is contact
with reality.

**Safety.** Deployed kiosks must be stable (tip-tested), electrically
safe (GFCI, strain relief, no exposed mains), and approved by the
instructor and the site owner before going live.

---

*"The kiosk is a promise made in public: walk up, and this machine will
help you, no questions asked. This class is about learning to keep that
promise."*
