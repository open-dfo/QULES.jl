function test_qules(bundle_dir)
%TEST_QULES Contract tests for the MATLAB QULES package.
%   TEST_QULES(BUNDLE_DIR) loads the bundle, runs the checks below, prints
%   PASS/FAIL per check and raises an error if any check failed, so
%       matlab -batch "addpath('bindings/matlab'); test_qules('C:\path\to\QULESBundle')"
%   exits with a non-zero status on failure. TEST_QULES() without an argument
%   uses the QULES_BUNDLE environment variable.
%
%   Checks: version, quadratic with rotation on/off (struct and name-value
%   options), 3-D Rosenbrock, verbose output containing "Termination", an
%   objective error propagating to the caller, and a Session run equal to
%   the optimize result.
%
%   See also QULES.LOAD, QULES.OPTIMIZE, QULES.SESSION.

if nargin < 1
    qules.load();
else
    qules.load(bundle_dir);
end
failures = 0;

% -- Version -------------------------------------------------------------------
try
    v = qules.version();
    check('version: 1x3 non-negative integers', ...
        isequal(size(v), [1 3]) && all(v >= 0) && all(v == floor(v)));
catch err
    fprintf('      version: %s\n', err.message);
    check('version: no error', false);
end

% -- Quadratic: f(x) = (x1-1)^2 + 10 (x2+2)^2 from [3, 1], both rotations ------
quad = @(x) (x(1) - 1)^2 + 10 * (x(2) + 2)^2;
for rotation = [true false]
    tag = sprintf('quadratic rotation=%d', rotation);
    try
        if rotation
            r = qules.optimize(quad, [3; 1], struct('max_evals', 40, 'rotation', rotation));
        else
            r = qules.optimize(quad, [3; 1], 'max_evals', 40, 'rotation', rotation);
        end
        check([tag ': evals == 40'], r.evals == 40);
        check([tag ': f_best < 1e-12'], r.f_best < 1e-12);
        check([tag ': |x1 - 1| < 1e-5'], abs(r.x_best(1) - 1) < 1e-5);
        check([tag ': |x2 + 2| < 1e-5'], abs(r.x_best(2) + 2) < 1e-5);
        check([tag ': x_best is a 2x1 column'], isequal(size(r.x_best), [2 1]));
    catch err
        fprintf('      %s: %s\n', tag, err.message);
        check([tag ': no error'], false);
    end
end

% -- 3-D Rosenbrock from [-1.2, 1, 0.5], 80 evaluations ------------------------
rosen = @(x) sum(100 * (x(2:end) - x(1:end-1).^2).^2 + (1 - x(1:end-1)).^2);
try
    r = qules.optimize(rosen, [-1.2; 1; 0.5], 'max_evals', 80);
    check('rosenbrock: evals == 80', r.evals == 80);
    check('rosenbrock: f_best finite', isfinite(r.f_best));
    check('rosenbrock: x_best is a 3x1 column', isequal(size(r.x_best), [3 1]));
catch err
    fprintf('      rosenbrock: %s\n', err.message);
    check('rosenbrock: no error', false);
end

% -- Verbose output goes through the binding's log route -----------------------
try
    out = evalc('qules.optimize(quad, [3; 1], ''max_evals'', 40, ''verbose'', true);');
    check('verbose: output contains "Termination"', contains(out, 'Termination'));
catch err
    fprintf('      verbose: %s\n', err.message);
    check('verbose: no error', false);
end

% -- An error inside the objective reaches the caller unchanged ----------------
boom = @boom_objective;  % an anonymous `error(...)` would fail on nargout first
raised = false; msg = ''; ident = '';
try
    qules.optimize(boom, [3; 1], 'max_evals', 40);
catch err
    raised = true; msg = err.message; ident = err.identifier;
end
check('objective error: raised', raised);
check('objective error: message preserved', strcmp(msg, 'objective exploded'));
check('objective error: identifier preserved', strcmp(ident, 'qules_test:boom'));

% The failed session must not poison later runs.
try
    r = qules.optimize(quad, [3; 1], 'max_evals', 40);
    check('after objective error: optimizer still works', r.f_best < 1e-12);
catch err
    fprintf('      after objective error: %s\n', err.message);
    check('after objective error: no error', false);
end

% -- Unknown options are rejected ----------------------------------------------
raised = false; ident = '';
try
    qules.optimize(quad, [3; 1], 'max_eval', 40);
catch err
    raised = true; ident = err.identifier;
end
check('unknown option: rejected with qules:args', raised && strcmp(ident, 'qules:args'));

% -- Session run equals the optimize result ------------------------------------
try
    r_opt = qules.optimize(rosen, [-1.2; 1; 0.5], 'max_evals', 80);
    s = qules.Session([-1.2; 1; 0.5], 'max_evals', 80);
    n_asked = 0;
    shapes_ok = true;
    while true
        x = s.ask();
        if isempty(x)
            break
        end
        n_asked = n_asked + 1;
        shapes_ok = shapes_ok && isequal(size(x), [3 1]);
        s.tell(rosen(x));
    end
    r_ses = s.best();
    finished = s.is_finished();
    delete(s);
    check('session: asked 80 points', n_asked == 80);
    check('session: ask returns 3x1 columns', shapes_ok);
    check('session: is_finished after the loop', finished);
    check('session: x_best equals optimize', isequal(r_ses.x_best, r_opt.x_best));
    check('session: f_best equals optimize', isequal(r_ses.f_best, r_opt.f_best));
    check('session: evals equals optimize', r_ses.evals == r_opt.evals);
    check('session: delta equals optimize', isequal(r_ses.delta, r_opt.delta));
catch err
    fprintf('      session: %s\n', err.message);
    check('session: no error', false);
end

% -- A deleted session refuses further calls -----------------------------------
% delete(s) invalidates the handle, so MATLAB itself raises on the property
% access inside ask; the exact identifier is MATLAB's, not the package's.
raised = false;
try
    s = qules.Session([3; 1], 'max_evals', 10);
    delete(s);
    s.ask();
catch
    raised = true;
end
check('session: ask after delete raises', raised);

if failures > 0
    error('qules:test', '%d check(s) failed.', failures);
end
fprintf('All checks passed.\n');

    function check(name, ok)
        if ok
            fprintf('PASS  %s\n', name);
        else
            fprintf('FAIL  %s\n', name);
            failures = failures + 1;
        end
    end
end

function y = boom_objective(~)
y = NaN; %#ok<NASGU>
error('qules_test:boom', 'objective exploded');
end
