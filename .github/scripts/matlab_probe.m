function matlab_probe(bundle_dir)
%MATLAB_PROBE Exercise the staged package through its public MATLAB loader.

fprintf('MATLAB %s | %s | JVM %d\n', version, computer('arch'), usejava('jvm'));
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
package_dir = fileparts(bundle_dir);
addpath(package_dir);
addpath(fullfile(repo, 'bindings', 'matlab', 'tests'));

% The staged package contains the generated prototype and compiled thunk.
% Hide compilers found via PATH while the Unix loader runs.
if ~ispc
    original_path = getenv('PATH');
    restore_path = onCleanup(@() setenv('PATH', original_path));
    setenv('PATH', package_dir);
    qules.load(bundle_dir);
    clear restore_path
else
    qules.load(bundle_dir);
end

test_qules(bundle_dir);
fprintf('\n');
test_stress(bundle_dir);
end
