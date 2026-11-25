function matlab_exit_session()
%MATLAB_EXIT_SESSION Use QULES and leave a live Session behind; MATLAB must
%   then exit with status 0 (Julia used to crash now and then on exit).

addpath(getenv('QULES_TOOLBOX'));
setenv('QULES_BUNDLE', '');
qules.load();
s = qules.Session([3; 1], 'max_evals', 20);
s.tell(sum(s.ask().^2));
assignin('base', 's', s);
r = qules.optimize(@(x) sum(x.^2), [3; 1], 'max_evals', 30);
assert(r.f_best < 1e-12, 'f_best = %g', r.f_best);
disp('Session done; exiting MATLAB')
end
