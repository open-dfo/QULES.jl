# Pairwise Jacobi frame learning (`rotation = true`) from existing evaluations.
# Recover only the two curvature functionals needed for each rotation:
#
#     uᵢⱼ = 2(QᵀHQ)ᵢⱼ,
#     vᵢⱼ = (QᵀHQ)ᵢᵢ - (QᵀHQ)ⱼⱼ.
#
# Eliminate the gradient with `D*w = 0`; minimum-norm SVD projections seek
#
#     D*Diag(w_off)*Dᵀ  = qᵢqⱼᵀ + qⱼqᵢᵀ,
#     D*Diag(w_diag)*Dᵀ = qᵢqᵢᵀ - qⱼqⱼᵀ,
#
# for columns `qᵢ`, `qⱼ` of `Q`, using the projection even if a target is not
# exactly representable. Set `θᵢⱼ = 0.5*atan(uᵢⱼ, vᵢⱼ)`. No objective
# evaluations are added; the envelope curvatures are not used.

"""
    build_givens(n, i, j, theta)

Return the n×n Givens rotation by `theta` in the `(i, j)` plane.
"""
function build_givens(n::Int, i::Int, j::Int, theta::Float64)
    G = Matrix{Float64}(I, n, n)
    c = cos(theta)
    s = sin(theta)
    G[i, i] = c
    G[i, j] = -s
    G[j, i] = s
    G[j, j] = c
    return G
end

"""
    svec_sym(X)

Frobenius-isometric vectorization of a symmetric matrix. Diagonal entries are
stored unchanged and upper-triangular off-diagonal entries are scaled by `sqrt(2)`.
"""
function svec_sym(X::AbstractMatrix{Float64})
    n = size(X, 1)
    v = Vector{Float64}(undef, div(n * (n + 1), 2))
    idx = 0
    for i in 1:n
        idx += 1
        v[idx] = X[i, i]
        for j in (i + 1):n
            idx += 1
            v[idx] = sqrt(2.0) * X[i, j]
        end
    end
    return v
end

"""
    target_functional_weights(D, T)

Find the minimum-norm weight vector `w` satisfying `D*w = 0` whose quadratic
moment `D*Diag(w)*D'` represents the symmetric target matrix `T`. The projection
is computed in an orthonormal nullspace basis with an SVD pseudoinverse; the
nullspace eliminates the unknown objective gradient.
"""
function target_functional_weights(D::AbstractMatrix{Float64},
                                   T::AbstractMatrix{Float64})
    _, M = size(D)
    dscale = maximum(norm(view(D, :, k)) for k in 1:M; init=0.0)
    target = svec_sym(T)
    target_norm = norm(target)

    if dscale == 0.0 || target_norm == 0.0
        return (w=zeros(Float64, M), success=true)
    end

    Dn = D ./ dscale
    N = nullspace(Dn)
    nullity = size(N, 2)
    if nullity == 0
        return (w=zeros(Float64, M), success=true)
    end

    L = zeros(Float64, length(target), nullity)
    for ell in 1:nullity
        w_ell = view(N, :, ell)
        A_ell = (Dn .* reshape(w_ell, 1, M)) * Dn'
        L[:, ell] = svec_sym(A_ell)
    end

    F = svd(L; full=false)
    sigma_max = isempty(F.S) ? 0.0 : maximum(F.S)
    svd_tol = max(size(L)...) * eps(Float64) * sigma_max
    keep = findall(sigma -> sigma > svd_tol, F.S)
    if isempty(keep)
        return (w=zeros(Float64, M), success=true)
    end

    z = F.V[:, keep] * ((F.U[:, keep]' * target) ./ F.S[keep])
    w_normalized = N * z

    # Dn*Diag(w_normalized)*Dn' = T implies
    # D*Diag(w)*D' = T for w = w_normalized/dscale^2.
    w = w_normalized ./ dscale^2
    success = all(isfinite, w)

    return (w=w, success=success)
end

"""
    pair_curvature_functionals(Q, D, delta, i, j)

Recover the cross-curvature `u = 2(Q' * H * Q)[i,j]` and diagonal contrast
`v = (Q' * H * Q)[i,i] - (Q' * H * Q)[j,j]` directly from function values.
"""
function pair_curvature_functionals(Q::AbstractMatrix{Float64},
                                    D::AbstractMatrix{Float64},
                                    delta::AbstractVector{Float64},
                                    i::Int,
                                    j::Int)
    qi = view(Q, :, i)
    qj = view(Q, :, j)
    T_off = qi * qj' + qj * qi'
    T_diag = qi * qi' - qj * qj'

    off = target_functional_weights(D, T_off)
    diag = target_functional_weights(D, T_diag)
    success = off.success && diag.success

    u = success ? 2.0 * dot(off.w, delta) : 0.0
    v = success ? 2.0 * dot(diag.w, delta) : 0.0
    success = success && isfinite(u) && isfinite(v)

    return (u=u, v=v, success=success)
end

"""
    jacobi_pair_update(Q, D, delta, i, j)

Rotate columns `i` and `j` of `Q` by `θ = 0.5*atan(u, v)` from the recovered
pair functionals. Return `Q` unchanged if recovery fails.
"""
function jacobi_pair_update(Q::AbstractMatrix{Float64},
                            D::AbstractMatrix{Float64},
                            delta::AbstractVector{Float64},
                            i::Int,
                            j::Int)
    n = size(Q, 1)

    res = pair_curvature_functionals(Q, D, delta, i, j)
    if !res.success
        return Q
    end

    # atan(0,0) returns 0.0 in Julia.
    theta = 0.5 * atan(res.u, res.v)
    G = build_givens(n, i, j, theta)
    Q_next = Q * G

    return Q_next
end

"""
    jacobi_orientation_sweep(Q, D, delta)

Apply one cyclic Jacobi sweep over the pairs (1,2), (1,3), ..., (n-1,n).
"""
function jacobi_orientation_sweep(Q::AbstractMatrix{Float64},
                                  D::AbstractMatrix{Float64},
                                  delta::AbstractVector{Float64})
    n = size(Q, 1)
    Qwork = copy(Q)

    for i in 1:(n - 1)
        for j in (i + 1):n
            Qwork = jacobi_pair_update(Qwork, D, delta, i, j)
        end
    end

    return Qwork
end

"""
    orientation_update(Q, p, S, delta, delta_plus)

Run one Jacobi sweep on `D = [-p S]` and `δ = [delta_plus; delta]`.
"""
function orientation_update(Q::AbstractMatrix{Float64},
                            p::AbstractVector{Float64},
                            S::AbstractMatrix{Float64},
                            delta::AbstractVector{Float64},
                            delta_plus::Float64)
    d0 = -p
    D = hcat(d0, S)
    del = vcat(delta_plus, delta)

    return jacobi_orientation_sweep(Q, D, del)
end
