function test_stress(bundle_dir)
%TEST_STRESS Run the MATLAB package through many problem types and every stop condition.
%   TEST_STRESS(BUNDLE_DIR) loads the bundle and runs each case below with
%   rotation on and off, three ways: qules.optimize, qules.optimize with
%   verbose output, and a qules.Session loop. The three must return the same
%   x_best. It then checks every stop condition and warning was reached and
%   runs MATLAB-side checks: many consecutive runs, interleaved sessions and
%   sessions released without delete. Raises an error if any check failed.
%   TEST_STRESS() without an argument uses the QULES_BUNDLE environment
%   variable. The MATLAB counterpart of bindings/python/tests/test_stress.py.
%
%   See also TEST_QULES.

if nargin < 1
    qules.load();
else
    qules.load(bundle_dir);
end
fprintf('QULES version %s\n', strjoin(string(qules.version()), '.'));

messages = { ...
    'max_evals',          'Evaluation budget reached'; ...
    'delta_min',          'Trust-region radius reached its minimum'; ...
    'flat_line',          'Active sample function values are flat'; ...
    'geometry_stall',     'Sample geometry could not be repaired'; ...
    'nonfinite_geometry', 'Geometry repair produced only nonfinite values'; ...
    'inner_failure',      'WARNING [iter='};
seen = zeros(size(messages, 1), 1);
failures = 0;
runs = 0;

% Name, objective, x0, options (name-value), f_best must be finite.
cases = {
    'quadratic n=1',               @quadratic,         3,                       {'max_evals', 150}, true
    'quadratic n=2',               @quadratic,         [3; 3],                  {'max_evals', 150}, true
    'quadratic n=5',               @quadratic,         3 * ones(5, 1),          {'max_evals', 150}, true
    'quadratic n=10',              @quadratic,         3 * ones(10, 1),         {'max_evals', 150}, true
    'rotated ill-conditioned n=2', @rotated_ill,       [2; -1],                 {'max_evals', 150}, true
    'rotated ill-conditioned n=5', @rotated_ill,       [2; -1; -1; -1; -1],     {'max_evals', 150}, true
    'rosenbrock n=3',              @rosenbrock,        [-1.2; 1; 0.5],          {'max_evals', 200}, true
    'nonsmooth n=4',               @nonsmooth,         [2; -1; 0; 1],           {'max_evals', 150}, true
    'three-hump camel',            @camel,             [-1; 2],                 {'max_evals', 100}, true
    'NaN region',                  @nan_region,        [3; 1],                  {'max_evals', 100}, true
    'Inf region',                  @inf_region,        [-0.5; -0.4],            {'max_evals', 100}, true
    'huge values',                 @huge_scale,        [3; 1],                  {'max_evals', 100}, true
    'tiny start radius',           @quadratic,         [3; 1],                  {'max_evals', 100, 'delta0', 1e-6}, true
    'large delta_min',             @quadratic,         [3; 1],                  {'max_evals', 300, 'delta_min', 1e-2}, true
    'budget 1',                    @quadratic,         [3; 1],                  {'max_evals', 1}, true
    'budget 2',                    @quadratic,         [3; 1],                  {'max_evals', 2}, true
    'flat values',                 @flat,              [0.5; 0.5],              {'max_evals', 50}, true
    'unrepresentable start',       @quadratic,         1e20,                    {'max_evals', 20}, true
    'nonfinite geometry',          @only_start_finite, [0; 0],                  {'max_evals', 20}, false
};

loud = []; ses = [];  % assigned inside evalc; a workspace with nested functions is static

for k = 1:size(cases, 1)
    [name, f, x0, opts, finite_expected] = cases{k, :};
    max_evals = opts{find(strcmp(opts, 'max_evals')) + 1};
    for rotation = [true false]
        label = sprintf('%s (rotation=%d)', name, rotation);
        o = [opts, {'rotation', rotation}];
        t = tic;
        try
            quiet = qules.optimize(f, x0, o{:});
            text = evalc('loud = qules.optimize(f, x0, o{:}, ''verbose'', true);');
            evalc('ses = run_session(f, x0, [o, {''verbose'', true}]);');
            runs = runs + 3;
            results = {quiet, loud, ses};
            problems = {};
            for r = results
                problems = [problems, result_problems(r{1}, numel(x0), max_evals, finite_expected)]; %#ok<AGROW>
            end
            if ~isequal(loud.x_best, quiet.x_best) || ~isequal(ses.x_best, quiet.x_best)
                problems{end + 1} = 'verbose or session run differs from the quiet run'; %#ok<AGROW>
            end
            if ~contains(text, 'Termination')
                problems{end + 1} = 'no Termination line'; %#ok<AGROW>
            end
            for m = 1:size(messages, 1)
                seen(m) = seen(m) + contains(text, messages{m, 2});
            end
            if isempty(problems)
                fprintf('PASS  %-45s f_best=%-12.4e evals=%-4d %5.1fs\n', ...
                    label, quiet.f_best, quiet.evals, toc(t));
            else
                fail(label, strjoin(problems, '; '));
            end
        catch err
            fail(label, err.message);
        end
    end
end

fprintf('\nStop conditions and warnings reached:\n');
for m = 1:size(messages, 1)
    fprintf('  %-20s %3d run(s)\n', messages{m, 1}, seen(m));
    if seen(m) == 0
        fail(['no case reached ' messages{m, 1}], '');
    end
end
fprintf('\n');

% -- Many consecutive runs give identical results -------------------------------
try
    t = tic;
    first = qules.optimize(@quadratic, [3; 1], 'max_evals', 30);
    same = true;
    for k = 2:200
        r = qules.optimize(@quadratic, [3; 1], 'max_evals', 30);
        same = same && isequal(r.x_best, first.x_best) && r.evals == first.evals;
    end
    runs = runs + 200;
    check(sprintf('200 consecutive runs identical (%.1fs)', toc(t)), same);
catch err
    fail('200 consecutive runs', err.message);
end

% -- Interleaved sessions do not affect each other ------------------------------
try
    starts = [3 1; -2 4; 0.5 -3; 5 5; -1 -1; 2 -2; 4 0; -3 2; 1 3; 0 0]';
    n_ses = size(starts, 2);
    sessions = cell(1, n_ses);
    for k = 1:n_ses
        sessions{k} = qules.Session(starts(:, k), 'max_evals', 60);
    end
    active = true(1, n_ses);
    while any(active)
        for k = find(active)
            x = sessions{k}.ask();
            if isempty(x)
                active(k) = false;
            else
                sessions{k}.tell(rosenbrock(x));
            end
        end
    end
    same = true;
    for k = 1:n_ses
        alone = qules.optimize(@rosenbrock, starts(:, k), 'max_evals', 60);
        b = sessions{k}.best();
        same = same && isequal(b.x_best, alone.x_best) && b.evals == alone.evals;
        delete(sessions{k});
    end
    runs = runs + 2 * n_ses;
    check(sprintf('%d interleaved sessions equal separate runs', n_ses), same);
catch err
    fail('interleaved sessions', err.message);
end

% -- Sessions dropped without delete or a finished loop -------------------------
try
    for k = 1:100
        s = qules.Session([3; 1], 'max_evals', 50);
        s.tell(quadratic(s.ask()));  % leave it half-way; the next assignment drops it
    end
    clear s
    r = qules.optimize(@quadratic, [3; 1], 'max_evals', 40);
    runs = runs + 101;
    check('100 dropped sessions: optimizer still works', isfinite(r.f_best) && r.evals == 40);
catch err
    fail('dropped sessions', err.message);
end

fprintf('\n%d native runs, %d failure(s)\n', runs, failures);
if failures > 0
    error('qules:test', '%d check(s) failed.', failures);
end
fprintf('All checks passed.\n');

    function check(name, ok)
        if ok
            fprintf('PASS  %s\n', name);
        else
            fail(name, '');
        end
    end

    function fail(name, why)
        failures = failures + 1;
        if isempty(why)
            fprintf('FAIL  %s\n', name);
        else
            fprintf('FAIL  %s: %s\n', name, why);
        end
    end
end

function r = run_session(f, x0, opts)
s = qules.Session(x0, opts{:});
cleanup = onCleanup(@() delete(s));
while true
    x = s.ask();
    if isempty(x)
        break
    end
    s.tell(f(x));
end
r = s.best();
end

function problems = result_problems(r, n, max_evals, finite_expected)
problems = {};
if r.evals > max_evals
    problems{end + 1} = sprintf('%d evals > %d', r.evals, max_evals);
end
if ~isequal(size(r.x_best), [n 1])
    problems{end + 1} = sprintf('x_best is %s', mat2str(size(r.x_best)));
end
if finite_expected && ~isfinite(r.f_best)
    problems{end + 1} = sprintf('f_best = %g', r.f_best);
end
end

function y = quadratic(x)
y = sum((1:numel(x))' .* (x - 1).^2);
end

function y = rotated_ill(x)
y = (sum(x) - 1)^2 + 1e4 * sum(diff(x).^2);
end

function y = rosenbrock(x)
y = sum(100 * (x(2:end) - x(1:end-1).^2).^2 + (1 - x(1:end-1)).^2);
end

function y = nonsmooth(x)
y = sum(abs(x - 0.3));
end

function y = camel(x)
y = 2 * x(1)^2 - 1.05 * x(1)^4 + x(1)^6 / 6 + x(1) * x(2) + x(2)^2;
end

function y = nan_region(x)
if x(1) > 2.5
    y = NaN;
else
    y = quadratic(x);
end
end

function y = inf_region(x)
if sum(x) < -1
    y = Inf;
else
    y = quadratic(x);
end
end

function y = huge_scale(x)
y = 1e12 * quadratic(x);
end

function y = flat(~)
y = 1;
end

function y = only_start_finite(x)
if all(x == 0)
    y = 0;
else
    y = NaN;
end
end
