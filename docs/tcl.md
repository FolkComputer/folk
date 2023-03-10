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

### Folk 

- Use complete sentences when you word your claims and wishes.

  Bad: `Claim $this firstName Omar`

  Good: `Claim $this has first name Omar`

- Scope using `$this` where appropriate to prevent weird global
  interactions

  Bad: `Claim the value is 3`

  Good: `Claim $this has value 3`

### Tcl datatypes

Create a namespace for your datatype that is an ensemble command with
operations on that datatype.

(Examples: `statement`, `c`, `region`, `point`, `image`)

Call the constructor `create`, as in `dict create` and `statement
create`.

### Singletons

Capitalized namespace, like `Statements`.
