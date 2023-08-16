# Math library

Utility functions for math objects.  

## functions

- `rectanglesOverlap {P1 P2 Q1 Q2 strict}` determine if the rectangles defined by the corner points `P1 P2` and `Q1 Q2`. Strict is a bool that indicates if the answer is strictly determined. (From: Cormen, Leiserson, and Rivests' "Algorithms", page 889)
- `regionToBbox {r}`: converts a region `r` to its bounding box, returns a list of `{minimum_x minimum_y maximum_x maximum_y}`
- `boxCentroid {box}`: returns the centroid of the box `box`
- `boxWidth {box}`: returns the width of the box `box`
- `boxHeight {box}`: returns the height of the box `box`

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

### `region`

A region is an arbitrary oriented chunk of a plane. The
archetypal region is the region of a program/page, which is the
quadrilateral area of space that is covered by that page. A
region is defined by a set of vertices and a set of edges among
those vertices.

- `create {vertices edges {angle 0}}`: create a region with the given vertices and edges, and optional angle.
- `vertices {r}`: return the vertices of the region `r`
- `edges {r}`: return the edges of the region `r`
- `angle {r}`: return the angle of the region `r`
- `width {r}`: return the width of the region `r` in screen space, acounting for rotation.
- `height {r}`: return the height of the region `r` in screen space, acounting for rotation.
- `top {r}`: return the vec2 point at the top of the region `r`
- `left {r}`: return the vec2 point to the left of the region `r`
- `right {r}`: return the vec2 point to the right of the region `r`
- `bottom {r}`: return the vec2 point at the bottom of the region `r`
- `mapVertices {varname r body}`: apply the body for each vector `varname` in region `r`
- `distance {r1 r2}`: calculate the distance between regions `r1` and `r2`
- `contains {r p}`: check if the region `r` contains the point `p`
- `intersects {r1 r2}`: check if region `r1` intersects with region `r2`
- `centroid {r}`: only works for rectangular regions! returns the point that is the centroid of the region `r`
- `rotate {r angle}`: returns a region `r'` that has been rotated by `angle`
- `scale {r args}`: Accepts values in `px`, `%`, and unmarked. If 1 arg, scale all by that arg, otherwise accepts `X<unit> width Y<unit> height`
- `move {r args}`: Moves the region left/right/up/down on the x and y axies of the region, not the global x and y. Args in the format `<AMMOUNT><UNIT> <DIRECTION>` where unit is one of the units that scale supports, and direction is left/right/up/down.

## TODO:

- [ ] Rewrite in C
- [ ] Triangulate a region
- [ ] Average the centroids of all triangles in a region
- [ ] Rename `regionToBbox`
- [ ] Assert that `box` is actually a box
- [ ] Optimize `scale`
- [ ] Allow areas in regions to be filled/unfilled

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)