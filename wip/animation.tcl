proc When {args} {
    foreach arg $args {
        puts $arg
    }
}

set this "<Page 10013>"

When $this has region /region/, \
    $this has width /width/, \
    $this has height /height/ {

        set dir [vec normalize [vec sub region(2) region(1)]]
        set offset [vec mul dir [vec add width spacing]]
        
}

     
     
