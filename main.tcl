try {
    info version
} on error e { "Not running in Jim Tcl" }

# TODO: Fix this hack.
set thisPid [pid]
foreach pid [try { exec pgrep tclsh8.6 } on error e { list }] {
    if {$pid ne $thisPid} {
        try { exec kill -9 $pid } on error e { puts stderr $e }
    }
}
exec sleep 1

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set ::isLaptop [expr {$tcl_platform(os) eq "Darwin" ||
                          ([info exists ::env(XDG_SESSION_TYPE)] &&
                           $::env(XDG_SESSION_TYPE) ne "tty")}]
    if {[info exists ::env(FOLK_ENTRY)]} {
        set ::entry $::env(FOLK_ENTRY)
    } elseif {$::isLaptop} {
        set ::entry "laptop.tcl"
    } else {
        set ::entry "pi/pi.tcl"
    }
}

source "lib/c.tcl"
source "lib/trie.tcl"
source "lib/evaluator.tcl"
namespace eval Evaluator {
    source "lib/environment.tcl"
    proc tryRunInSerializedEnvironment {lambda env} {
        try {
            runInSerializedEnvironment $lambda $env
        } on error err {
            set this ""
            for {set i 0} {$i < [llength [lindex $lambda 0]]} {incr i} {
                if {[lindex $lambda 0 $i] eq "this"} {
                    set this [lindex $env $i]
                    break
                }
            }
            if {$this ne ""} {
                Say $this has error $err with info $::errorInfo
                puts stderr "$::thisProcess: Error in $this, match $::matchId: $err\n$::errorInfo"
            } else {
                Say $::matchId has error $err with info $::errorInfo
                puts stderr "$::thisProcess: Error in match $::matchId: $err\n$::errorInfo"
            }
        }
    }
}
set ::logsize -1 ;# Hack to keep metrics working

source "lib/language.tcl"

# invoke at top level, add/remove independent 'axioms' for the system
proc Assert {args} {
    if {[lindex $args 0] eq "when" && [lindex $args end-1] ne "environment"} {
        set args [list {*}$args with environment {}]
    }
    Evaluator::LogWriteAssert $args
}
proc Retract {args} { Evaluator::LogWriteRetract $args }

# invoke from within a When context, add dependent statements
proc Say {args} { Evaluator::LogWriteSay $::matchId $args }
proc Claim {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] claims {*}$args] }
proc Wish {args} { upvar this this; uplevel [list Say [expr {[info exists this] ? $this : "<unknown>"}] wishes {*}$args] }

proc When {args} {
    set body [lindex $args end]
    set pattern [lreplace $args end end]
    if {[lindex $pattern 0] eq "(non-capturing)"} {
        set argNames [list]; set argValues [list]
        set pattern [lreplace $pattern 0 0]
    } else {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
    }

    set varNamesWillBeBound [list]
    set negate false
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set word [lindex $pattern $i]
        if {$word eq "&"} {
            # Desugar this join into nested Whens.
            set remainingPattern [lrange $pattern $i+1 end]
            set pattern [lrange $pattern 0 $i-1]
            for {set j 0} {$j < [llength $remainingPattern]} {incr j} {
                set remainingWord [lindex $remainingPattern $j]
                if {[regexp {^/([^/ ]+)/$} $remainingWord -> remainingVarName] &&
                    $remainingVarName in $varNamesWillBeBound} {
                    lset remainingPattern $j \$$remainingVarName
                }
            }
            set body [list When {*}$remainingPattern $body]
            break

        } elseif {[set varName [trie scanVariable $word]] != "false"} {
            if {$varName in $statement::blanks} {
            } elseif {$varName in $statement::negations} {
                # Rewrite this entire clause to be negated.
                set negate true
            } else {
                # Rewrite subsequent instances of this variable name /x/
                # (in joined clauses) to be bound $x.
                if {[string range $varName 0 2] eq "..."} {
                    set varName [string range $varName 3 end]
                }
                lappend varNamesWillBeBound $varName
            }
        } elseif {[trie startsWithDollarSign $word]} {
            lset pattern $i [uplevel [list subst $word]]
        }
    }

    if {$negate} {
        set negateBody [list if {[llength $__matches] == 0} $body]
        uplevel [list Say when the collected matches for $pattern are /__matches/ [list [list {*}$argNames __matches] $negateBody] with environment $argValues]
    } else {
        lappend argNames {*}$varNamesWillBeBound
        uplevel [list Say when {*}$pattern [list $argNames $body] with environment $argValues]
    }
}
proc Every {event args} {
    if {$event eq "time"} {
        set body [lindex $args end]
        set pattern [lreplace $args end end]
        set level 0
        foreach word $pattern { if {$word eq "&"} {incr level} }
        uplevel [list When {*}$pattern "$body\nEvaluator::Unmatch $level"]
    }
}

proc On {event args} {
    if {$event eq "process"} {
        if {[llength $args] == 2} {
            lassign $args name body
        } elseif {[llength $args] == 1} {
            # Generate a unique name.
            set this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
            set subprocessId [uplevel {incr __subprocessId}]
            set name "${this}-${::matchId}-${subprocessId}"
            set body [lindex $args 0]
        }
        # Serialize the lexical environment at the callsite so we can
        # send that to the subprocess.
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        uplevel [list On-process $name [list apply [list $argNames $body] {*}$argValues]]
        set name ;# Return the name to the caller in case they want it.

    } elseif {$event eq "unmatch"} {
        set body [lindex $args 0]
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        Statements::matchAddDestructor $::matchId [list $argNames $body] $argValues

    } else {
        error "Unknown On $event $args"
    }
}

proc After {n unit body} {
    if {$unit eq "milliseconds"} {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        after $n [list apply [list $argNames [subst {
            $body
            Step
        }]] {*}$argValues]
    } else { error }
}
set ::committed [dict create]
set ::toCommit [dict create]
proc Commit {args} {
    upvar this this
    set body [lindex $args end]
    set key [list Commit [expr {[info exists this] ? $this : "<unknown>"}] {*}[lreplace $args end end]]
    if {$body eq ""} {
        dict set ::toCommit $key $body
    } else {
        lassign [uplevel Evaluator::serializeEnvironment] argNames argValues
        set lambda [list {this} [list apply [list $argNames $body] {*}$argValues]]
        dict set ::toCommit $key $lambda
    }
}

set ::stepCount 0
set ::stepTime -1
source "lib/peer.tcl"
proc StepImpl {} {
    incr ::stepCount
    Assert $::thisProcess has step count $::stepCount
    Retract $::thisProcess has step count [expr {$::stepCount - 1}]

    # Receive statements from all peers.
    foreach peerNs [namespace children ::Peers] {
        upvar ${peerNs}::process peer
        Commit $peer [list Say $peer is sharing statements [${peerNs}::receive]]
    }

    while {[dict size $::toCommit] > 0 || ![Evaluator::LogIsEmpty]} {
        dict for {key lambda} $::toCommit {
            if {$lambda ne ""} {
                Assert $key has program $lambda
            }
            if {[dict exists $::committed $key] && [dict get $::committed $key] ne $lambda} {
                Retract $key has program [dict get $::committed $key]
            }
            if {$lambda ne ""} {
                dict set ::committed $key $lambda
            }
        }
        set ::toCommit [dict create]
        Evaluator::Evaluate
    }

    # Share statements to all peers.
    set ::peerTime [baretime {
        set shareStatements [dictset create]
        if {[llength [Statements::findMatches [list /someone/ wishes $::thisProcess shares all wishes]]] > 0} {
            foreach match [Statements::findMatches [list /someone/ wishes /...anything/]] {
                set id [lindex [dict get $match __matcheeIds] 0]
                set clause [statement clause [Statements::get $id]]
                dictset add shareStatements $clause
            }
        }
        if {[llength [Statements::findMatches [list /someone/ wishes $::thisProcess shares all claims]]] > 0} {
            foreach match [Statements::findMatches [list /someone/ claims /...anything/]] {
                set id [lindex [dict get $match __matcheeIds] 0]
                set clause [statement clause [Statements::get $id]]
                dictset add shareStatements $clause
            }
        }

        set matches [Statements::findMatches [list /someone/ wishes $::thisProcess shares statements like /pattern/]]
        ::addMatchesToShareStatements shareStatements $matches

        foreach peerNs [namespace children ::Peers] {
            ${peerNs}::share $shareStatements
        }
    }]
}

set ::frames [list]
proc Step {} {
    set ::stepRunTime 0
    set stepTime [baretime StepImpl]
    
    set framesInLastSecond 0
    set now [clock milliseconds]
    lappend ::frames $now
    foreach frame $::frames {
        if {$frame > $now - 1000} {
            incr framesInLastSecond
        }
    }
    set ::frames [lreplace $::frames 0 end-$framesInLastSecond]

    set ::stepTime "$stepTime us (peer $::peerTime us, run $::stepRunTime us) ($framesInLastSecond fps)"
}

source "lib/math.tcl"


# this defines $this in the contained scopes
# it's also used to implement Commit
Assert when /this/ has program /__program/ {{this __program} {
    apply $__program $this
}}
# For backward compat(?):
Assert when /__this/ has program code /__programCode/ {{__this __programCode} {
    Claim $__this has program [list {this} $__programCode]
}}

Assert when /someone/ is sharing statements /statements/ {{statements} {
    foreach stmt $statements { Say {*}$stmt }
}}

set ::thisNode "[info hostname]"
set ::nodename $::thisNode ;# for backward compat

namespace eval ::Heap {
    # Folk has a shared heap among all processes on a given node
    # (physical machine).
    #
    # Memory allocated from the Folk heap should be accessible, at
    # exactly the same virtual address, from any Folk process.
    #
    # This allocator is meant to be used as 1. a base allocator for
    # higher-level interprocess data structures (including the
    # mailboxes below) and 2. an allocator for large, immutable,
    # persistent objects (images -- think images). You probably
    # shouldn't be calling it in a tight loop or making small
    # allocations from it. It stores a lot of metadata per
    # allocation. I would expect at most tens of allocations from here
    # in play at any given time, and most/all of those over 1MB.
    proc init {} {
        variable cc [c create]
        $cc cflags -I./vendor

        $cc include <sys/mman.h>
        $cc include <sys/stat.h>
        $cc include <fcntl.h>
        $cc include <unistd.h>
        $cc include <stdlib.h>
        $cc include <string.h>
        $cc include <errno.h>
        $cc include <pthread.h>

        $cc code {
            size_t folkHeapSize = 400000000; // 400MB
            uint8_t* folkHeapBase;

            typedef struct folk_heap_allocation_entry_t {
                void* base;
                size_t sz;
                uint64_t version;
            } folk_heap_allocation_entry_t;
            typedef struct folk_heap_state_t {
                pthread_mutex_t mutex;

                uint8_t* brk;

                uint64_t rndState;
                folk_heap_allocation_entry_t allocations[256];

                char mallocState[0];
            } folk_heap_state_t;
            // This state must be carved out of the heap itself -- it
            // cannot be standard C global or static -- so that all
            // subprocesses share it when allocating and deallocating.
            folk_heap_state_t* folkHeapState;

            #define USE_DL_PREFIX 1
            #define HAVE_MMAP 0
            #define MORECORE folkSbrk
            #define get_malloc_state() ((struct malloc_state*) folkHeapState->mallocState)
            void* folkSbrk(intptr_t increment) {
                if (folkHeapState->brk + increment >= folkHeapBase + folkHeapSize) {
                    fprintf(stderr, "folkSbrk: out of memory\n"); exit(1);
                }
                void* ptr = folkHeapState->brk; folkHeapState->brk += increment;
                return ptr;
            }
            #include "dlmalloc/malloc.c"
        }
        # The memory mapping of the heap will be inherited by all
        # subprocesses, since it's established before the creation of
        # the zygote.
        $cc proc folkHeapMount {} void {
            (void) av_; // just to suppress unuse warning in malloc.c.

            shm_unlink("/folk-heap"); // Try to delete the old heap if there is one.
            int fd = shm_open("/folk-heap", O_RDWR | O_CREAT, S_IROTH | S_IWOTH | S_IRUSR | S_IWUSR);
            if (fd == -1) { fprintf(stderr, "folkHeapMount: shm_open failed\n"); exit(1); }
            if (ftruncate(fd, folkHeapSize) == -1) { fprintf(stderr, "folkHeapMount: ftruncate failed\n"); exit(1); }
            folkHeapBase = (uint8_t*) mmap(0, folkHeapSize,
                                           PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (folkHeapBase == NULL || folkHeapBase == (void *) -1) {
                fprintf(stderr, "folkHeapMount: mmap failed: '%s'\n", strerror(errno)); exit(1);
            }
            folkHeapState = (folk_heap_state_t*) folkHeapBase;
            memset(folkHeapState, 0, sizeof(*folkHeapState));
            folkHeapState->brk = folkHeapBase + sizeof(*folkHeapState) + sizeof(struct malloc_state);

            pthread_mutexattr_t att; pthread_mutexattr_init(&att);
            pthread_mutexattr_setpshared(&att, PTHREAD_PROCESS_SHARED);
            pthread_mutex_init(&folkHeapState->mutex, &att);
        }
        $cc code {
            uint64_t rnd64(uint64_t n) {
                const uint64_t z = 0x9FB21C651E98DF25;

                n ^= ((n << 49) | (n >> 15)) ^ ((n << 24) | (n >> 40));
                n *= z;
                n ^= n >> 35;
                n *= z;
                n ^= n >> 28;

                return n;
            }
        }
        # On each allocation, the heap stores a random 64-bit
        # 'version' for that allocation (which can then be remembered
        # by the caller). You can query the heap with any address and
        # it will try to give you the 'version' if there is an
        # allocation containing that address. This is used to check
        # for staleness of images that have been copied to the GPU
        # (like camera slices). If the version mismatches the one we
        # stored at previous copy-time, then we know we have to recopy
        # that image to the GPU.
        # 
        # TODO: This implementation is pretty inefficient and unsafe
        # (it walks a capped-256 array of all allocations) and we may
        # want to replace it with an interval tree or something at
        # some point.
        $cc proc folkHeapAlloc {size_t sz} void* {
            /* fprintf(stderr, "folkHeapAlloc %zu\n", sz); */
            pthread_mutex_lock(&folkHeapState->mutex);

            uint64_t version = rnd64(folkHeapState->rndState++);
            void* ptr = dlmalloc(sz);
            for (int i = 0;
                 i < sizeof(folkHeapState->allocations)/sizeof(folkHeapState->allocations[0]);
                 i++) {
                if (folkHeapState->allocations[i].base == 0) {
                    folkHeapState->allocations[i].base = ptr;
                    folkHeapState->allocations[i].sz = sz;
                    folkHeapState->allocations[i].version = version;

                    pthread_mutex_unlock(&folkHeapState->mutex);
                    return ptr;
                }
            }
            pthread_mutex_unlock(&folkHeapState->mutex);
            fprintf(stderr, "folkHeapAlloc: Ran out of allocation slots\n"); exit(1);
        }
        $cc proc folkHeapFree {void* ptr} void {
            /* fprintf(stderr, "folkHeapFree %p\n", ptr); */
            pthread_mutex_lock(&folkHeapState->mutex);

            for (int i = 0;
                 i < sizeof(folkHeapState->allocations)/sizeof(folkHeapState->allocations[0]);
                 i++) {
                if (folkHeapState->allocations[i].base <= ptr &&
                    ptr < folkHeapState->allocations[i].base + folkHeapState->allocations[i].sz) {
                    folkHeapState->allocations[i].base = 0;
                    folkHeapState->allocations[i].sz = 0;
                    folkHeapState->allocations[i].version = 0;
                    dlfree(ptr);

                    pthread_mutex_unlock(&folkHeapState->mutex);
                    return;
                }
            }

            pthread_mutex_unlock(&folkHeapState->mutex);
            fprintf(stderr, "folkHeapFree: Tried to free invalid Folk heap pointer\n");
        }
        $cc proc folkHeapGetVersion {void* ptr} uint64_t {
            pthread_mutex_lock(&folkHeapState->mutex);

            for (int i = 0;
                 i < sizeof(folkHeapState->allocations)/sizeof(folkHeapState->allocations[0]);
                 i++) {
                if (folkHeapState->allocations[i].base <= ptr &&
                    ptr < folkHeapState->allocations[i].base + folkHeapState->allocations[i].sz) {
                    uint64_t version = folkHeapState->allocations[i].version;
                    pthread_mutex_unlock(&folkHeapState->mutex);
                    return version;
                }
            }

            pthread_mutex_unlock(&folkHeapState->mutex);
            return 0;
        }
        if {$::tcl_platform(os) eq "Linux"} {
            $cc cflags -lrt
            c loadlib [lindex [exec /usr/sbin/ldconfig -p | grep librt.so | head -1] end]
        }
        $cc compile
        folkHeapMount
    }
}
Heap::init

namespace eval ::Mailbox {
    set cc [c create]
    $cc include <stdlib.h>
    $cc include <string.h>
    $cc include <pthread.h>
    $cc import ::Heap::cc folkHeapAlloc as folkHeapAlloc
    $cc code {
        typedef struct mailbox_t {
            bool active;

            pthread_mutex_t mutex;

            char from[100];
            char to[100];

            int mailLen;
            char mail[1000000];
        } mailbox_t;

        #define NMAILBOXES 100
        mailbox_t* mailboxes;
    }
    $cc proc init {} void {
        /* fprintf(stderr, "Before: mailboxes = %p\n", mailboxes); */
        mailboxes = folkHeapAlloc(sizeof(mailbox_t) * NMAILBOXES);
        memset(mailboxes, 0, sizeof(mailbox_t) * NMAILBOXES);
        /* fprintf(stderr, "After: mailboxes = %p\n", mailboxes); */
    }
    $cc proc create {char* from char* to} void {
        if (find(from, to) != NULL) return;
        fprintf(stderr, "Mailbox create %s -> %s\n", from, to);
        for (int i = 0; i < NMAILBOXES; i++) {
            if (!mailboxes[i].active) {
                mailboxes[i].active = true;
                
                pthread_mutexattr_t mattr;
                pthread_mutexattr_init(&mattr);
                pthread_mutexattr_setpshared(&mattr, PTHREAD_PROCESS_SHARED);
                pthread_mutex_init(&mailboxes[i].mutex, &mattr);

                snprintf(mailboxes[i].from, 100, "%s", from);
                snprintf(mailboxes[i].to, 100, "%s", to);
                mailboxes[i].mail[0] = '\0';
                return;
            }
        }
        fprintf(stderr, "Out of available mailboxes.\n");
        exit(1);
    }
    $cc code {
        mailbox_t* find(char* from, char* to) {
            for (int i = 0; i < NMAILBOXES; i++) {
                if (mailboxes[i].active &&
                    strcmp(mailboxes[i].from, from) == 0 &&
                    strcmp(mailboxes[i].to, to) == 0) {
                    return &mailboxes[i];
                }
            }
            return NULL;
        }
    }
    $cc proc share {char* from char* to char* statements} void {
        mailbox_t* mailbox = find(from, to);
        if (!mailbox) {
            fprintf(stderr, "Could not find mailbox for '%s -> %s'.\n", from, to);
            exit(1);
        }
        pthread_mutex_lock(&mailbox->mutex); {
            mailbox->mailLen = snprintf(mailbox->mail, sizeof(mailbox->mail), "%s", statements);
        } pthread_mutex_unlock(&mailbox->mutex);
    }
    $cc proc receive {char* from char* to} Tcl_Obj* {
        mailbox_t* mailbox = find(from, to);
        if (!mailbox) { return Tcl_NewStringObj("", -1); }
        Tcl_Obj* ret;
        pthread_mutex_lock(&mailbox->mutex); {
            ret = Tcl_NewStringObj(mailbox->mail, mailbox->mailLen);
        } pthread_mutex_unlock(&mailbox->mutex);
        return ret;
    }
    $cc compile
    init
}

if {[info exists ::entry]} {
    source "lib/process.tcl"
    Zygote::init

    # Everything below here only runs if we're in the primary Folk
    # process.
    set ::thisProcess $::thisNode

    proc ::loadVirtualPrograms {} {
        set ::rootVirtualPrograms [dict create]
        proc loadProgram {programFilename} {
            # this is a proc so its variables don't leak
            set fp [open $programFilename r]
            dict set ::rootVirtualPrograms $programFilename [read $fp]
            close $fp
        }
        foreach programFilename [list {*}[glob virtual-programs/*.folk] \
                                     {*}[glob -nocomplain "user-programs/[info hostname]/*.folk"]] {
            loadProgram $programFilename
        }
        Assert $::thisNode is providing root virtual programs $::rootVirtualPrograms

        # So we can retract them all at once if some other node connects and
        # wants to impose its root virtual programs:
        Assert when the collected matches for \
                    [list /node/ is providing root virtual programs /rootVirtualPrograms/] \
                    are /roots/ {{roots} {

            if {[llength $roots] == 0} {
                error "No root virtual programs available for entry Tcl node."
            }

            # Are there foreign root virtual programs that should take priority over ours?
            foreach root $roots {
                if {[dict get $root node] ne $::thisNode} {
                    set chosenRoot $root
                    break
                }
            }
            if {![info exists chosenRoot]} {
                # Default to first in the list if no foreign root.
                set chosenRoot [lindex $roots 0]
            }

            dict for {programFilename programCode} [dict get $chosenRoot rootVirtualPrograms] {
                Say [dict get $chosenRoot node] claims $programFilename has program code $programCode
            }
        }}

        # Watch for virtual-programs/ changes.
        # try {
        #     set fd [open "|fswatch virtual-programs" r]
        #     fconfigure $fd -buffering line
        #     fileevent $fd readable [list apply {{fd} {
        #         set changedFilename [file tail [gets $fd]]
        #         if {[string index $changedFilename 0] eq "." ||
        #             [string index $changedFilename 0] eq "#" ||
        #             [file extension $changedFilename] ne ".folk"} {
        #             return
        #         }
        #         set changedProgramName "virtual-programs/$changedFilename"
        #         puts "$changedProgramName updated, reloading."

        #         set fp [open $changedProgramName r]; set programCode [read $fp]; close $fp
        #         EditVirtualProgram $changedProgramName $programCode
        #     }} $fd]
        # } on error err {
        #     puts stderr "Warning: could not invoke `fswatch` ($err)."
        #     puts stderr "Will not watch virtual-programs for changes."
        # }
    }
    proc ::EditVirtualProgram {programName programCode} {
        set oldRootVirtualPrograms $::rootVirtualPrograms
        if {[dict exists $oldRootVirtualPrograms $programName] &&
            [dict get $oldRootVirtualPrograms $programName] eq $programCode} {
            # Code hasn't changed.
            return
        }
        dict set ::rootVirtualPrograms $programName $programCode

        Assert $::thisNode is providing root virtual programs $::rootVirtualPrograms
        Retract $::thisNode is providing root virtual programs $oldRootVirtualPrograms
        Step
    }

    source "./web.tcl"
    source $::entry
}
