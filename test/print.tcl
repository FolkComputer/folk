loadVirtualPrograms [list "virtual-programs/print.folk"]

Assert $::thisNode claims printer my-printer is a cups printer with url "ipp://10.3.2.20/ipp/print" driver "everywhere"
Assert $::thisNode claims printer my-printer can print double-sided a4 paper
Assert $::thisNode claims printer my-printer can print single-sided letter paper
Assert $::thisNode claims printer my-printer is the default printer
Assert $::thisNode claims paper format a4 is the default paper format

Assert $::thisNode claims printer simple-printer can print single-sided letter paper
Step

Assert printProgram-[incr i] has program {{this} {
    set code { Wish $this to be outlined green }
    Wish to print $code with job-id [expr {rand()}] printer my-printer format a4
}}
Step

Assert printProgram-[incr i] has program {{this} {
    set code { Wish $this to be outlined green }
    Wish to print $code with job-id [expr {rand()}] printer my-printer
}}
Step

Assert printProgram-[incr i] has program {{this} {
    set code { Wish $this to be outlined green }
    Wish to print $code with job-id [expr {rand()}]
}}

Assert printProgram-[incr i] has program {{this} {
    set code { Wish $this to be outlined green }
    Wish to print $code with job-id front-back format letter
}}
Step

Assert printProgram-[incr i] has program {{this} {
    set code { Wish $this to be outlined green }
    Wish to print the back of job-id front-back
}}
Step
