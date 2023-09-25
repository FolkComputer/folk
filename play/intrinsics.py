import numpy as np

def svd_solve(A):
    """Solve a homogeneous least squares problem with the SVD
       method.

    Args:
       A: Matrix of constraints.
    Returns:
       The solution to the system.
    """
    U, S, V_t = np.linalg.svd(A)
    idx = np.argmin(S)

    least_squares_solution = V_t[idx]

    return least_squares_solution


def generate_v_ij(H_stack, i, j):
    """Generate intrinsic orthogonality constraints. See Zhang pg. 6 for
       details.
    """ 
    M = H_stack.shape[0]

    v_ij = np.zeros((M, 6))
    v_ij[:, 0] = H_stack[:, 0, i] * H_stack[:, 0, j]
    v_ij[:, 1] = H_stack[:, 0, i] * H_stack[:, 1, j] + H_stack[:, 1, i] * H_stack[:, 0, j]
    v_ij[:, 2] = H_stack[:, 1, i] * H_stack[:, 1, j]
    v_ij[:, 3] = H_stack[:, 2, i] * H_stack[:, 0, j] + H_stack[:, 0, i] * H_stack[:, 2, j]
    v_ij[:, 4] = H_stack[:, 2, i] * H_stack[:, 1, j] + H_stack[:, 1, i] * H_stack[:, 2, j]
    v_ij[:, 5] = H_stack[:, 2, i] * H_stack[:, 2, j]

    return v_ij

def recover_intrinsics(homographies):
    """Use computed homographies to calculate intrinsic matrix.
       Requires >= 3 homographies for a full 5-parameter intrinsic matrix.
    """
    M = len(homographies)

    # Stack homographies
    H_stack = np.zeros((M, 3, 3))
    for h, H in enumerate(homographies):
        H_stack[h] = H

    # Generate constraints
    v_00 = generate_v_ij(H_stack, 0, 0)
    v_01 = generate_v_ij(H_stack, 0, 1)
    v_11 = generate_v_ij(H_stack, 1, 1)

    # Mount constraint matrix
    V = np.zeros((2 * M, 6))
    V[:M] = v_01
    V[M:] = v_00 - v_11
    print("V", V)

    # Use SVD to solve the homogeneous system Vb = 0
    b = svd_solve(V)
    print("b", b)

    B0, B1, B2, B3, B4, B5 = b

    # Form B = K_-T K_-1
    B = np.array([[B0, B1, B3],
                  [B1, B2, B4],
                  [B3, B4, B5]])

    # Form auxilliaries
    w = B0 * B2 * B5 - B1**2 * B5 - B0 * B4**2 + 2. * B1 * B3 * B4 - B2 * B3**2
    d = B0 * B2 - B1**2

    # Use Zhang's closed form solution for intrinsic parameters (Zhang, Appendix B, pg. 18)
    v0 = (B[0,1] * B[0,2] - B[0,0] * B[1,2]) / (B[0,0] * B[1,1] - B[0,1] * B[0,1])
    lambda_ = B[2,2] - (B[0,2] * B[0,2] + v0 * (B[0,1] * B[0,2] - B[0,0] * B[1,2])) / B[0,0]
    alpha = np.sqrt(lambda_ / B[0,0])
    beta = np.sqrt(lambda_ * B[0,0] / (B[0,0] * B[1,1] - B[0,1] * B[0,1]))
    gamma = -B[0,1] * alpha * alpha * beta / lambda_
    u0 = gamma * v0 / beta - B[0,2] * alpha * alpha / lambda_

    # Reconstitute intrinsic matrix
    K = np.array([[alpha, gamma, u0],
                  [   0.,  beta, v0],
                  [   0.,    0., 1.]])

    return K


Hs = [[
    [0.16049012153397643, 0.025140703661436413, -56.18443035035172],
    [0.03803332982400695, -0.1686580150644637, 84.98331034678388],
    [0.00012549119613814434, -9.513034013038792e-5, 1],
], [
    [0.1703557060271793, -0.010695915050475279, -54.86197805231042],
    [-0.005782351807719997, -0.18617759205607617, 125.39918777541205],
    [5.083591507797107e-6, -9.763536784095669e-5, 1],
], [
    [0.15510314590200447, -0.02983454051527247, -57.38376123976827],
    [0.008533999712687673, -0.17796796063024783, 88.01267738445614],
    [0.0002807280568875622, -0.0004580039739272952, 1],
], [
    [0.09876790983614021, -0.013792250737007372, -8.967749498005295],
    [-0.010801736412439119, -0.12458641332054761, 88.94995833626156],
    [-0.0001237806908555834, -0.0002224424659072042, 1],
]]
print(recover_intrinsics(Hs))
