Assert C is a programming language
Assert Java is a programming language
Assert JavaScript is a programming language

Assert when /pl/ is a programming language {{pl} {
    puts "On thread [__threadId]: $pl"
    Claim $pl really is a PL
}} with environment {}

Assert we are done
Assert when we are done {{} {
    sleep 1
    Retract /any/ is a programming language
    sleep 1; __exit 0
}} with environment {}
