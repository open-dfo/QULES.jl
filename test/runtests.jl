using Test
using LinearAlgebra
using QULES

BLAS.set_num_threads(1)

function reference_columns(samples, a, Delta)
    columns = Vector{Vector{Float64}}()
    for (point, value) in zip(samples.points, samples.y)
        isfinite(value) && all(isfinite, point) || continue
        d = point - a
        push!(columns, (d / Delta) / (1 + (norm(d) / Delta)^2))
    end
    return isempty(columns) ? zeros(length(a), 0) : reduce(hcat, columns)
end

function coordinate_bank(a, Delta; radii=ones(length(a)))
    points = [copy(a)]
    for j in eachindex(a), sign in (-1.0, 1.0)
        point = copy(a)
        point[j] += sign * radii[j] * Delta
        push!(points, point)
    end
    return SampleSet(points, zeros(length(points)))
end

function check_reference(samples, a, Delta)
    Z = reference_columns(samples, a, Delta)
    state = QULES.build_weighted_svd(samples, a, Delta)
    @test isapprox(state.Z, Z; atol=2e-13, rtol=2e-12)
    smallest = size(Z, 2) < length(a) ? 0.0 : minimum(svd(Z).S)
    actual = state.m0 < length(a) ? 0.0 : state.F.S[end]
    @test isapprox(actual, smallest; atol=2e-12, rtol=2e-9)
end

function repair(samples, objective, a, Delta; max_evals, evals=1)
    config = QULESConfig(max_evals=max_evals, verbose=false)
    return QULES.prepare_sample_geometry!(samples, objective, a, Delta, config, evals, 1)
end

@testset "Weighted sample geometry" begin
    @testset "Independent SVD reference" begin
        for n in (1, 3, 10), Delta in (1e-4, 1e4)
            a = [0.3 * sin(j) for j in 1:n]
            points = [copy(a)]
            for i in 1:(3n + 4)
                push!(points, a + Delta * [sin(0.37i + 1.19j) + 0.4cos(0.17i*j) for j in 1:n])
            end
            check_reference(SampleSet(points, zeros(length(points))), a, Delta)
        end
    end

    @testset "Known weak direction" begin
        a = [2.0, -3.0, 4.0]
        Delta = 0.2
        samples = coordinate_bank(a, Delta; radii=[1.0, 1.0, 100.0])
        @test abs(least_represented_direction(samples, a, Delta)[3]) >= 1 - 1e-12
        @test sample_geometry_ok(samples, a, Delta, 0.01)
        @test !sample_geometry_ok(samples, a, Delta, 0.02)
    end

    @testset "Rank deficiency and nonfinite samples" begin
        deficient = SampleSet([[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [-1.0, 0.0, 0.0]], [0.0, 1.0, 1.0])
        @test abs(least_represented_direction(deficient, zeros(3), 1.0)[1]) <= 1e-12
        @test !sample_geometry_ok(deficient, zeros(3), 1.0, 0.01)
        check_reference(deficient, zeros(3), 1.0)

        invalid = SampleSet([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0], [0.0, -1.0], [NaN, 1.0], [1.0, Inf]],
                            [0.0, 1.0, Inf, NaN, 1.0, 1.0])
        check_reference(invalid, zeros(2), 1.0)
        @test !sample_geometry_ok(invalid, zeros(2), 1.0, 0.01)
        @test abs(least_represented_direction(invalid, zeros(2), 1.0)[2]) >= 1 - 1e-12
    end

    @testset "Far points do not certify a shrunken radius" begin
        samples = coordinate_bank(zeros(3), 1.0)
        @test !sample_geometry_ok(samples, zeros(3), 0.001, 0.01)
        before = deepcopy(samples.points)
        calls = Ref(0)
        result = repair(samples, x -> (calls[] += 1; sum(abs2, x)), zeros(3), 0.001;
                        max_evals=20, evals=7)
        @test result.certified
        @test result.evals == 7 + calls[]
        @test 1 <= calls[] <= 3
        @test all(p -> any(==(p), samples.points), before)
    end

    @testset "Repair fills every missing direction" begin
        for n in (1, 3, 10)
            samples = SampleSet([zeros(n)], [0.0])
            queries = Vector{Float64}[]
            result = repair(samples, x -> (push!(queries, copy(x)); sum(abs2, x)), zeros(n), 0.7;
                            max_evals=n + 1)
            @test result.certified
            @test length(queries) == n
            @test all(x -> isapprox(norm(x), 0.7; atol=2e-14), queries)
        end
    end

    @testset "No evaluation when geometry is sufficient" begin
        samples = coordinate_bank(zeros(5), 1.0)
        calls = Ref(0)
        result = repair(samples, x -> (calls[] += 1; 0.0), zeros(5), 1.0; max_evals=20, evals=11)
        @test result.certified
        @test result.evals == 11
        @test calls[] == 0
    end

    @testset "Budget stop leaves geometry uncertified" begin
        for allowed in 0:3
            samples = SampleSet([zeros(3)], [0.0])
            result = repair(samples, x -> sum(abs2, x), zeros(3), 1.0; max_evals=1 + allowed)
            @test result.evals == 1 + allowed
            @test result.certified == (allowed == 3)
            @test result.stop_reason == (allowed == 3 ? nothing : "max_evals")
        end
    end

    @testset "Nonfinite repair and opposite-sign fallback" begin
        u = least_represented_direction(SampleSet([[0.0]], [0.0]), [0.0], 1.0)
        samples = SampleSet([[0.0]], [0.0])
        result = repair(samples, x -> dot(x, u) > 0 ? Inf : sum(abs2, x), [0.0], 1.0; max_evals=3)
        @test result.certified
        @test result.evals == 3

        for budget in (2, 3)
            result = repair(SampleSet([[0.0]], [0.0]), x -> Inf, [0.0], 1.0; max_evals=budget)
            @test !result.certified
            @test result.stop_reason == (budget == 2 ? "max_evals" : "nonfinite_geometry")
        end
    end

    @testset "Unrepresentable repair stops without a duplicate evaluation" begin
        calls = Ref(0)
        result = repair(SampleSet([[1e20]], [0.0]), x -> (calls[] += 1; 0.0), [1e20], 1.0; max_evals=5)
        @test !result.certified
        @test result.stop_reason == "geometry_stall"
        @test calls[] == 0
    end
end

@testset "optimize_qules" begin
    quadratic(x) = (x[1] - 1.0)^2 + 10.0 * (x[2] + 2.0)^2
    rotated(x) = (x[1] + x[2] - 1.0)^2 + 100.0 * (x[1] - x[2])^2

    @testset "Converges on a quadratic (rotation = $rotation)" for rotation in (false, true)
        result = optimize_qules(quadratic, [3.0, 1.0]; max_evals=150, rotation=rotation, verbose=false)
        @test result.f_best < 1e-6
        @test isapprox(result.x_best, [1.0, -2.0]; atol=1e-3)
        @test result.evals <= 150
    end

    @testset "Rotation learns an orthonormal frame" begin
        result = optimize_qules(rotated, [3.0, 1.0]; max_evals=150, rotation=true, verbose=false)
        @test result.f_best < 1e-6
        @test isapprox(result.Q_frame' * result.Q_frame, I; atol=1e-10)
    end

    @testset "Evaluation budget" begin
        calls = Ref(0)
        result = optimize_qules(x -> (calls[] += 1; quadratic(x)), [3.0, 1.0];
                                max_evals=10, verbose=false)
        @test calls[] == result.evals == 10
        @test result.termination_reason == "max_evals"
    end

    @testset "Invalid input" begin
        @test_throws ArgumentError optimize_qules(quadratic, Float64[]; verbose=false)
        @test_throws ArgumentError optimize_qules(quadratic, [3.0, 1.0];
                                                  sample_capacity_factor=0, verbose=false)
    end
end
