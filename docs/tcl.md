# Tcl

## Tcl for JavaScripters

JS:
```
let names = ["64", "GameCube", "Wii", "Switch"];
names = names.map(name => `Nintendo ${name}`);
console.log(names);

function add(a, b) { return a + b; }
const numbers = [1, 2];
console.log(add(...numbers));
```

Tcl:
```
set names [list 64 GameCube Wii Switch]
set names [lmap name $names {expr {"Nintendo $name"}}]
puts $names

proc add {a b} { expr {$a + $b} }
set numbers [list 1 2]
puts [add {*}$numbers]
```

## Style guide

### Tcl code vs. virtual programs vs. printed programs

In general, avoid adding new .tcl files to the Git repo. Pure Tcl
libraries are an antipattern; we should only need them for the hard
core of the system.

Most new code (both libraries and applications) should be virtual
programs (which ilve as .folk files in the virtual-programs/
subfolder) or printed programs.

### Folk 

- Use complete sentences when you word your claims and wishes.

  Bad: `Claim $this firstName Omar`

  Good: `Claim $this has first name Omar`

- Scope using `$this` where appropriate to prevent weird global
  interactions

  Bad: `Claim the value is 3`

  Good: `Claim $this has value 3`

### Tcl

#### Error handling

Use `try` (and `on error`) in new code. Avoid using `catch`; it's
older and easier to get wrong.

#### Tcl datatypes

Create a namespace for your datatype that is an ensemble command with
operations on that datatype.

(Examples: `statement`, `c`, `region`, `point`, `image`)

Call the constructor `create`, as in `dict create` and `statement
create`.

#### Singletons

Capitalized namespace, like `Statements`.


### Working with regions

A common pattern I've found myself doing is:

```tcl
When /thing/ has region /r/ {
  lassign $r vertices edges
  lassign $vertices a b c d
}
```

Now you can think about addressing

```
a - b
|   |
d - c
```
