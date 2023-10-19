# I need an expression for (x, p) -> y.
# I need a Jacobian expression for (x, p)
# There are 96 points.

from sympy import *
init_printing(use_unicode=True)

# x is model points
# y is image points

# p:
#   A is 3x3 -> 9 elements
#   r0s is Nx3 -> N*3 elements
#   r1s is Nx3 -> N*3 elements
#   ts is Nx3 -> N*3 elements

NUM_POINTS_PER_IMAGE = 96
NUM_IMAGES = 4

# Ground-truth data symbols
# ---
model = MatrixSymbol('Model', NUM_POINTS_PER_IMAGE, 2)
images = MatrixSymbol('Image', NUM_POINTS_PER_IMAGE * NUM_IMAGES, 2)

# Parameter symbols
# ---
A = MatrixSymbol('A', 3, 3)
r0s = MatrixSymbol('r0s', NUM_IMAGES, 3)
r1s = MatrixSymbol('r1s', NUM_IMAGES, 3)
ts = MatrixSymbol('ts', NUM_IMAGES, 3)

def reprojectionError():
    err = 0
    for imageNum in range(NUM_IMAGES):
        r0 = Matrix(r0s).row(imageNum)
        r1 = Matrix(r1s).row(imageNum)
        t = Matrix(ts).row(imageNum)
        for i in range(NUM_POINTS_PER_IMAGE):
            H = A * Matrix.vstack(r0, r1, t).T
            reprojectedImagePointHom = H * Matrix([model[i, 0], model[i, 1], 1])
            reprojectedImagePoint = Matrix([reprojectedImagePointHom[0, 0] / reprojectedImagePointHom[2, 0],
                                            reprojectedImagePointHom[1, 0] / reprojectedImagePointHom[2, 0]])

            imagePoint = images[NUM_POINTS_PER_IMAGE * imageNum + i, :]
            diff = imagePoint - reprojectedImagePoint.T
            err += sqrt(diff[0, 0]**2 + diff[0, 1]**2)

    return err

# TODO: Evaluate wrt concrete values, compare to Tcl error.
# model: NUM_POINTS_PER_IMAGEx2 matrix
# images: (NUM_POINTS_PER_IMAGE*NUM_IMAGES)x2 matrix
# A: 3x3 matrix
# r0s: NUM_IMAGESx3 matrix
# r1s: NUM_IMAGESx3 matrix
# ts: NUM_IMAGESx3 matrix
def computeReprojectionError(model_, images_, A_, r0s_, r1s_, ts_):
    fn = lambdify([model, images, A, r0s, r1s, ts], reprojectionError())
    return fn(model_, images_, A_, r0s_, r1s_, ts_)

# TODO: Compute C version of func & C version of Jacobian.
# TODO: Use C versions in levmarq.
