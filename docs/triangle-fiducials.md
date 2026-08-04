# TriTag: a triangle fiducial system for Folk

_Status: proposal / spec. A rendering of the marker family (drawn
through the real Vulkan pipeline) lives in
`user-programs/folk-cwe/triangle-fiducial-demo.folk`._

## 1. Motivation

Folk currently identifies and tracks physical programs with square
AprilTags (`tagStandard52h13`, see `builtin-programs/apriltags.folk`
and `builtin-programs/tags-to-quads.folk`). This spec follows on from
the earlier ruler-fiducial exploration — a 1D fiducial that encodes
position and scale along a single edge — and extends the same idea to
the natural next primitive: the triangle.

Why triangles?

- **Orientation from silhouette alone.** A circle blob gives you a
  position and nothing else. A square silhouette has 4-fold rotational
  symmetry: you cannot know its orientation until you have *decoded
  the payload* (AprilTag burns codebook capacity ensuring codewords
  are rotation-distinct for exactly this reason). An **isoceles
  triangle with a distinct apex angle has no rotational symmetry**:
  the detector recovers a full, unambiguous 2D orientation from the
  outline itself, before any bits are read. That makes each marker an
  *oriented landmark* even at distances/blur levels where the payload
  is unreadable — exactly what SLAM and floor/plane estimation want.

- **More codebook capacity per cell.** Because orientation is
  resolved geometrically, the code layout does not need to be
  rotation-disambiguating. All 2^N of an N-cell payload space is
  available to the coding scheme (spent on distance/parity instead of
  symmetry-breaking).

- **Cheapest polygon to fit.** A triangle is the minimal polygon: 3
  corner fits instead of 4, no saddle/collinearity degeneracies from a
  4th corner, and the quad-fitting stage of the AprilTag detector
  simplifies rather than complicates.

- **Triangles tessellate.** For floor fields (many small markers
  tiling a surface), triangles pack a plane with no wasted interstitial
  space and alternating up/down orientations give a free extra parity
  signal per neighborhood.

The tradeoff, stated honestly up front: **3 coplanar points are not
enough for a full homography or unique pose** (P3P has up to 4
solutions; 3 correspondences fix only an affine frame). TriTag
therefore includes a **4th interior correspondence point** (the
"keystone dot", §2), which restores full-homography rectification and
unique-pose recovery while keeping the silhouette a pure triangle.

## 2. Marker geometry

Marker frame: centroid at origin, y-down (matching camera/display
convention), apex pointing "up" (−y). Dimensions are fractions of the
marker scale `s` (the centroid→apex distance ≈ `1.05·s`).

```
              ▲ apex A = (0, −1.05)
             ╱ ╲
            ╱   ╲          outer border: black, filled
           ╱  ●  ╲         keystone dot: black disc, center (0, −0.60), r 0.10
          ╱ ┌───┐ ╲        interior: white, outer triangle scaled 0.70
         ╱  │▚▞▚│  ╲       code region: outer scaled 0.52, shifted (0, +0.14),
        ╱   └───┘   ╲                    side-3 triangular grid = 9 cells
       ╱             ╲
      C ─────────────── B
  (−0.68, 0.55)   (0.68, 0.55)
```

- **Silhouette**: isoceles triangle, apex angle ≈ 46°, base angles
  ≈ 67°. The apex is identified as the corner with the smallest
  interior angle; this is robust under moderate perspective (the
  ordering of angles survives homographies that keep the marker
  reasonably front-facing; the keystone dot arbitrates extreme
  cases — it always lies nearest the true apex).
- **Border**: black band between the outer triangle and the same
  triangle scaled 0.70 about the centroid (band ≈ 15% of scale, wide
  enough to survive 2× decimation like AprilTag's border).
- **Keystone dot**: black disc at `(0, −0.60)`, radius `0.10`. Dual
  role: (a) 4th point correspondence for homography/pose, (b) apex
  arbiter under strong perspective.
- **Code region**: triangular side-3 subdivision → **9 cells** (6
  upward, 3 downward), each cell painted black (1) or left white (0).
  Cell order: upward cells row-major from apex, then downward cells.

## 3. Encoding: the `tri9h3` family

- 9 payload bits, codebook generated (lexicode search, same procedure
  as AprilTag family generation) with **minimum Hamming distance 3**
  and two extra rejection rules: no codeword within distance 1 of
  all-black/all-white, and minimum 2 black + 2 white cells (so the
  code region always has internal contrast for the sampler).
- No rotation constraints are needed (orientation is geometric), so
  the search space is the full 512; the expected yield is roughly
  50–60 usable ids. That is small by AprilTag standards but TriTags
  are intended as *dense constellation markers* (many small identical-
  family markers), not as unique program ids; §6 shows how
  constellations multiply the effective id space.
- Larger family option `tri16h5`: side-4 subdivision → 16 cells, min
  distance 5, ≈ 200–300 ids, for when single-marker identity matters.
- Decode is a straight lookup with ≤1-bit error correction (d=3).

## 4. Detection pipeline

Reuses the shape of `apriltag_quad_thresh.c` with a smaller final
stage; new code lives in a `vendor/`-style C library plus a
`builtin-programs/tritags.folk` wrapper mirroring `apriltags.folk`.

1. **Adaptive threshold + connected components** — identical to
   AprilTag (tile min/max, union-find on black/white boundary).
2. **Contour → 3-gon fit** — for each boundary cluster, fit 3 corners
   instead of 4 (dominant-point selection over the convex hull; the
   quad stage's line-fit refinement applies unchanged with k=3).
   Reject if the best-fit triangle's interior angles don't match the
   family's (46°, 67°, 67°) within a perspective-tolerant band.
3. **Corner refinement** — subpixel line intersections of the 3 edge
   fits (cheaper than AprilTag: 3 lines, 3 intersections).
4. **Apex identification** — smallest interior angle; confirm with
   the keystone dot (search the affine-predicted location).
5. **Rectification** — homography from 4 correspondences (3 corners +
   keystone center) via `homography_compute` (already vendored).
6. **Decode** — sample the 9 cell centroids through the homography,
   threshold against the local black/white model from the border and
   interior, look up in the codebook (≤1-bit correction).

Expected cost per candidate is below AprilTag's (fewer corners, 9–16
samples vs 52). Steps 1–2 dominate and are shared, so a combined
detector can run both families over one segmentation pass — important
for a migration period where squares and triangles coexist on the
same table.

## 5. Pose recovery (6DOF)

`tags-to-quads.folk` already contains everything needed — its
`poseGaussNewton` is written for arbitrary `npoints`:

- Model points: `A=(0,−1.05s), B=(0.68s,0.55s), C=(−0.68s,0.55s),
  K=(0,−0.60s)`, z=0.
- Initial estimate: `estimate_pose_for_tag_homography` on the
  4-correspondence homography (unchanged from the square path).
- Refinement: `poseGaussNewton(wX, x, 4, …)` — the same virtual-servo
  Gauss-Newton loop, same warm-start-from-previous-frame trick, same
  stabilization/freezing logic.

Statement schema mirrors tags exactly:

```
tri /id/ has detection /det/ on camera /camera/ at timestamp /ts/
    (det: id, c, p {apex baseR baseL}, keystone, angle, size)
tri /id/ has pose /pose/ at timestamp /ts/
tri /id/ has quad /quad/            ;# bounding quad, for canvas reuse
```

so everything downstream of `has quad` (canvases, drawing,
calibration-space changers) works without modification.

## 6. SLAM and floor estimation

This is where triangles earn their keep.

- **Oriented landmarks.** Each detection contributes position *and*
  bearing even when unreadably small: a triangle whose silhouette
  spans only ~12 px still yields an oriented point (vs an anonymous
  blob for circles, or an orientation-ambiguous square). A bearing
  per landmark cuts the number of landmarks needed for a rigid 2D
  registration from 2 to 1, and for odometry gives rotation directly
  instead of deriving it from baselines between points.

- **Floor constellations.** Tile the floor (or table margin) with
  small TriTags in a triangular lattice. Because ids repeat, identity
  comes from the *constellation*: the ids of a marker and its ≤6
  lattice neighbors form a neighborhood word; with ~50 ids and 3
  neighbors the collision probability for a local word is already
  ~10⁻⁵, so a single camera glimpse of a few adjacent markers
  relocalizes globally (kidnapped-robot style) without any marker
  being globally unique.

- **6DOF floor-plane recovery.** Every marker pose is a plane sample
  (`R` z-column = local plane normal, `t` = point on plane). Robust
  aggregation (RANSAC over marker poses, then least-squares) yields
  the floor plane and the camera's height/tilt against it — the same
  quantities the current calibrate pipeline extracts from a dedicated
  board, but continuously and passively, from whatever markers are in
  view. Per-marker bearing then anchors yaw, completing drift-free
  6DOF against the floor.

- **Graph SLAM formulation.** Nodes: camera poses + marker poses.
  Edges: per-detection 6DOF constraints (from §5) with information
  weighted by silhouette area. Because markers are cheap (9 bits, no
  uniqueness requirement), map density is limited by print area, not
  by codebook exhaustion — the classic AprilTag-SLAM bottleneck.

## 7. Comparison

|                            | circle blob | square (AprilTag) | **TriTag** |
|----------------------------|-------------|-------------------|------------|
| orientation from silhouette| none        | mod-90° only      | **full**   |
| corners to fit             | —           | 4                 | **3 (+dot)**|
| payload for N cells        | 0           | < N (symmetry tax)| **N**      |
| min usable size            | small       | medium            | **small** (oriented even undecodable) |
| unique pose                | no          | yes (4 corners)   | yes (3 corners + keystone) |
| tessellates a floor        | poorly      | yes (square grid) | **yes (denser, alternating)** |
| ecosystem maturity         | n/a         | high              | none (this spec) |

## 8. Implementation plan

1. `vendor/tritag/` — detector library: fork the threshold/segment
   stages of `vendor/apriltag`, add the 3-gon fitter, keystone finder
   and 9-cell decoder; generate the `tri9h3` codebook.
2. `builtin-programs/tritags.folk` — detector wrapper: entire-frame +
   incremental detection, `tri /id/ has detection …` claims
   (mirroring `apriltags.folk`).
3. `builtin-programs/tris-to-quads.folk` — pose + quad claims via the
   existing `poseGaussNewton` (npoints=4).
4. `builtin-programs/print/` — marker generator for printing (the
   drawing code in the demo program is the reference renderer).
5. Floor-constellation library: neighborhood-word relocalization +
   plane aggregation (`the floor plane is /plane/` claims).

### Open questions

- Exact apex angle: sharper apex → stronger orientation signal but
  worse corner localization at the apex (acute corners blur). 46° is
  a starting point; needs empirical sweep.
- Whether step 2's 3-gon fitter should share candidate clusters with
  the square fitter permanently (one segmentation, two shape fits) or
  only during migration.
- Keystone dot vs. a notched border as the 4th feature (the dot costs
  interior area; a notch costs border robustness).
- `tri9h3` yield: run the lexicode search and lock the codebook.
