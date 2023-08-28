# Tcl extensions

'Language' utilities that extend and customize base Tcl.

## Language features

- `fn {name args body}`: creates a lexically scoped function in folk
    Example:

    ```tcl
    fn text {coords text angle} {
        Display::text [lindex $coords 0] [lindex $coords 1] 2 $text $angle
    }
    ```

- `forever { ... }`: Works like `while true { ... }`, but yiels to the event loop, so it's safe to use in the context of folk
- `assert { condition }`: if condition evaluates to not true, it will error out and return the error code

## Functions

- `python3 { ... }`: evaluate the body in python3
- `lenumerate { list }`: enumarate over a list, that is, return each of the elements in the list in the form `{ index element }`
- `ltrim { list }`: remove empty items at the beginning and the end of the list
- `undent { msg }`: trims the indentation from msg, as long as it is made of spaces

## Imports

`language.tcl` brings all of `::tcl::mathop` and `::tcl::mathfunc` into the global namespace.

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)