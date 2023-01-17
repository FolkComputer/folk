namespace eval Whatever {
    variable nice 3
    
    proc cool {} {
        variable nice
        
        puts $nice
    }
}
Whatever::cool
