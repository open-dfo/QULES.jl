function matlab_toolbox_test(archive, toolbox_dir)
%MATLAB_TOOLBOX_TEST Install ARCHIVE with qules.install_bundle and run the tests.
%   Uses the installed toolbox, or TOOLBOX_DIR when given.

fprintf('MATLAB %s | %s\n', version, computer('arch'));
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
if nargin > 1
    addpath(toolbox_dir);
end
setenv('QULES_BUNDLE', '');   % qules.load() must use the installed bundle
installed = fileparts(fileparts(which('qules.load')));
assert(~isempty(installed) && ~startsWith(installed, repo), ...
    'qules.load does not resolve to the packaged toolbox: "%s"', installed);
fprintf('Toolbox in %s\n', installed);
addpath(fullfile(repo, 'bindings', 'matlab', 'tests'));

% The toolbox contains the generated prototype and compiled thunk.
% Hide compilers found via PATH while the Unix loader runs.
original_path = getenv('PATH');
if ~ispc
    setenv('PATH', installed);
end
bundle = qules.install_bundle(archive);
assert(strcmp(qules.install_bundle(), bundle), 'second install_bundle call differs');
qules.load();
setenv('PATH', original_path);

test_qules();
end
