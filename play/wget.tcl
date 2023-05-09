if {0} {
    example syntax: Wish $this downloads "URL"
    
    When someone wishes for a page to be downloaded we check to see if there's
    $title.html in the current directory. If there is, we don't download it.

    If there isn't, we download the page and save it as $title.html
}


# proc called findTitle that searches a string of HTML for the title using regexp and returns the text of the title
proc findTitle {webpage} {
    set title [regexp -inline -all -line -lineanchor {<title>(.*)</title>} $webpage]
    return [lindex $title 1]
}

# proc called getWebpage that takes a URL, uses exec & wget to print out the content as a string
proc getWebpage {URL} {
    set webpage [exec wget -q -O - $URL]
    return $webpage
}

# proc called download that takes a URL, uses getWebpage to download the content to a file
proc download {URL} {
    set webpage [getWebpage $URL]
    set title [string map {" " "_"} [findTitle $webpage]]
    puts "title: $title"
    puts "writing to file $title.html"
    set file [open $title.html w]
    puts $file $webpage
    close $file
}

# this works! downloads example.com to Example_Domain.html
download example.com