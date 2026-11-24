function matlab_probe(bundle_dir, handle_signals)
%MATLAB_PROBE Load a QULES bundle into MATLAB and run the bindings/matlab
%   contract tests (bindings/matlab/tests/test_qules.m). Meant for Linux and
%   macOS: +qules/load.m only knows the Windows bundle, so this loads the
%   library under the alias 'qules' itself; qules.load then returns at once.
%   HANDLE_SIGNALS = false starts Julia with --handle-signals=no.

fprintf('MATLAB %s | %s | JVM %d\n', version, computer('arch'), usejava('jvm'));

if ispc
    lib = fullfile(bundle_dir, 'bin', 'qules.dll');
    setenv('PATH', [fileparts(lib) pathsep getenv('PATH')]);
elseif ismac
    lib = fullfile(bundle_dir, 'lib', 'libqules.dylib');
else
    lib = fullfile(bundle_dir, 'lib', 'libqules.so');
end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));

cc = mex.getCompilerConfigurations('C', 'Selected');
if isempty(cc)
    fprintf('C compiler: none selected\n');
else
    fprintf('C compiler: %s %s\n', cc.Name, cc.Version);
end

fprintf('loadlibrary %s\n', lib);
[notfound, warnings] = loadlibrary(lib, fullfile(here, 'matlab_probe.h'), 'alias', 'qules');
if ~isempty(notfound)
    fprintf('not found: %s\n', strjoin(notfound, ', '));
end
if ~isempty(warnings)
    fprintf('loadlibrary warnings:\n%s\n', warnings);
end

argv = {'qules'};
if ~handle_signals
    argv{end + 1} = '--handle-signals=no';
end
fprintf('init_julia(%s)\n', strjoin(argv, ' '));
calllib('qules', 'init_julia', int32(numel(argv)), libpointer('stringPtrPtr', argv));
fprintf('init_julia returned\n');

addpath(fullfile(repo, 'bindings', 'matlab'));
addpath(fullfile(repo, 'bindings', 'matlab', 'tests'));
fprintf('qules.version: %s\n', mat2str(qules.version()));

r = qules.optimize(@(x) 100 * (x(2) - x(1)^2)^2 + (1 - x(1))^2, [-1.2; 1], 'max_evals', 200);
fprintf('rosenbrock 2-D: f_best = %.3e, evals = %d, x_best = %s\n', ...
    r.f_best, r.evals, mat2str(r.x_best', 8));

test_qules(bundle_dir);
end
