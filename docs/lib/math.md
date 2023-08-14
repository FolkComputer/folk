# Math library

## namespaces

### `vec2`

A `vec2` is a 2d vector, i.e. a structure that stores 2 number, and can preform operations upon it. In Tcl they are represented by a list of 2 numbers.

- `add {a b}`: adds the respective pairs of x and y values together
- `sub {a b}`: subracts the respective pairs of Xb and Yb from Xa and Ya
- `scale {a args}`: if args is 1 value, scale both values by it, if it's 2 values, scale Xa by Xargs and Ya by Yargs
- `rotate {a theta}`: rotate the values in a by theta
- `distance {a b}`: calculates the euclidean distance (the length of a line segment between the two points)
- `normalize {a}`: normalizes the vector by dividing each value by the magnitude of the vector
- `dot {a b}`: calculate the dot product of the two vectors, basically, calculates how much two vectors point in the same direction.
- `distanceToLineSegment {a v w}`: returns the distance to the line segment defined by v and w
- `midpoint {a b}`: returns the midpoint of the line segment defined by `a b`. 


---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)