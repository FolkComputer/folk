set UVX "$::env(HOME)/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

package require oo

class Uvx [list stdin "" stdout "" UVX $UVX]
Uvx method constructor args {
    lassign [pipe] stdin_read stdin_write
    lassign [pipe] stdout_read stdout_write

    set harness_code {import sys
for line in sys.stdin:
    try:
        result = eval(line.strip())
        print(f"___RESULT___{result}")
    except Exception as e:
        print(f"___ERROR___{e}")
    print("___DONE___")
    sys.stdout.flush()}

    exec $UVX {*}$args python -u -c $harness_code <@$stdin_read >@$stdout_write 2>@stderr &

    close $stdin_read
    close $stdout_write

    set stdin $stdin_write
    set stdout $stdout_read

    fconfigure $stdin -buffering line -blocking 1
    fconfigure $stdout -buffering line -blocking 1
}
Uvx method run {code} {
    puts $stdin $code
    flush $stdin

    set result ""
    set has_error 0

    while {[gets $stdout line] >= 0} {
        if {[string match "___RESULT___*" $line]} {
            set result [string range $line 12 end]
        } elseif {[string match "___ERROR___*" $line]} {
            set result [string range $line 11 end]
            set has_error 1
        } elseif {$line eq "___DONE___"} {
            break
        }
    }

    if {$has_error} {
        error $result
    }

    return $result
}
