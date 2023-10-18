# I need an expression for (x, p) -> y.
# I need a Jacobian expression for (x, p)
# There are 96 points.

from sympy import *
init_printing(use_unicode=True)

# x is model points
# y is image points

# p:
#   A is 3x3 -> 9 elements
#   r0s is Nx3x1 -> N*3 elements
#   r1s is Nx3x1 -> N*3 elements
#   ts is Nx3x1 -> N*3 elements

NUM_POINTS_PER_IMAGE = 96
NUM_IMAGES = 4

N = NUM_POINTS_PER_IMAGE * NUM_IMAGES

# Ground-truth data symbols
# ---
model = []
for i in range(NUM_POINTS_PER_IMAGE): model.append(symbols(f"model{i}_x model{i}_y"))

images = []
for imageNum in range(NUM_IMAGES):
    image = []
    for i in range(NUM_POINTS_PER_IMAGE):
        image.append(Matrix(MatrixSymbol(f"image{imageNum}_{i}", 2, 1)))

    images.append(image)

# Parameter symbols
# ---
A = Matrix(MatrixSymbol('A', 3, 3))
r0s = []
r1s = []
ts = []
for imageNum in range(NUM_IMAGES):
    r0s.append(Matrix(MatrixSymbol(f"r0_{imageNum}", 3, 1)))
    r1s.append(Matrix(MatrixSymbol(f"r1_{imageNum}", 3, 1)))
    ts.append(Matrix(MatrixSymbol(f"t_{imageNum}", 3, 1)))

def reprojectionError():
    err = 0
    for imageNum, image in enumerate(images):
        r0 = r0s[imageNum]
        r1 = r1s[imageNum]
        t = ts[imageNum]
        for i in range(NUM_POINTS_PER_IMAGE):
            H = A * Matrix.hstack(r0, r1, t).T
            reprojectedImagePointHom = H * Matrix([model[i][0], model[i][1], 1])
            reprojectedImagePoint = Matrix([reprojectedImagePointHom[0] / reprojectedImagePointHom[2],
                                            reprojectedImagePointHom[1] / reprojectedImagePointHom[2]])

            imagePoint = images[imageNum][i]
            diff = imagePoint - reprojectedImagePoint
            err += sqrt(diff[0]**2 + diff[1]**2)

    return err

# TODO: Evaluate wrt concrete values, compare to Tcl error.
def computeReprojectionError(model, images, A, r0s, r1s, ts):
    values = {}

    for i in range(NUM_POINTS_PER_IMAGE):
        values[f"model{i}_x"], values[f"model{i}_y"] = model[i, 0], model[i, 1]

    for imageNum in range(NUM_IMAGES):
        for i in range(NUM_POINTS_PER_IMAGE):
            values[f"image{imageNum}_{i}"] = images[imageNum]

    values["A"] = A

    for imageNum in range(NUM_IMAGES):
        r0 = r0s[imageNum]; r1 = r1s[imageNum]; t = ts[imageNum]
        values[f"r0_{imageNum}"] = r0
        values[f"r1_{imageNum}"] = r1
        values[f"t_{imageNum}"] = t

    return reprojectionError().evalf(subs=values).doit()

# TODO: Compute C version of func & C version of Jacobian.
# TODO: Use C versions in levmarq.
