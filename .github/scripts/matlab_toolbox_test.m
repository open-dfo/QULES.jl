function matlab_toolbox_test()
%MATLAB_TOOLBOX_TEST Run the tests through the installed toolbox's qules.load().

fprintf('MATLAB %s | %s\n', version, computer('arch'));
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
setenv('QULES_BUNDLE', '');   % qules.load() must find the installed bundle
installed = fileparts(fileparts(which('qules.load')));
assert(~isempty(installed) && ~startsWith(installed, repo), ...
    'qules.load does not resolve to the installed toolbox: "%s"', installed);
fprintf('Installed in %s\n', installed);
addpath(fullfile(repo, 'bindings', 'matlab', 'tests'));

% The toolbox contains the generated prototype and compiled thunk.
% Hide compilers found via PATH while the Unix loader runs.
original_path = getenv('PATH');
if ~ispc
    setenv('PATH', installed);
end
qules.load();
setenv('PATH', original_path);

test_qules();
end
