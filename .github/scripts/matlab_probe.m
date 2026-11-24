function matlab_probe(bundle_dir)
%MATLAB_PROBE Load a QULES bundle into MATLAB and run the bindings/matlab
%   tests test_qules and test_stress. +qules/load.m only knows the Windows
%   bundle, so on Linux and macOS this loads the library under the alias
%   'qules' itself and qules.load returns at once; on Windows the tests load
%   it through qules.load.

fprintf('MATLAB %s | %s | JVM %d\n', version, computer('arch'), usejava('jvm'));
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));

if ~ispc
    if ismac
        lib = fullfile(bundle_dir, 'lib', 'libqules.dylib');
    else
        lib = fullfile(bundle_dir, 'lib', 'libqules.so');
    end
    cc = mex.getCompilerConfigurations('C', 'Selected');
    if isempty(cc)
        fprintf('C compiler: none selected\n');
    else
        fprintf('C compiler: %s %s\n', cc.Name, cc.Version);
    end
    fprintf('loadlibrary %s\n', lib);
    notfound = loadlibrary(lib, fullfile(here, 'matlab_probe.h'), 'alias', 'qules');
    if ~isempty(notfound)
        fprintf('not found: %s\n', strjoin(notfound, ', '));
    end
    calllib('qules', 'init_julia', int32(1), libpointer('stringPtrPtr', {'qules'}));
end

addpath(fullfile(repo, 'bindings', 'matlab'));
addpath(fullfile(repo, 'bindings', 'matlab', 'tests'));
test_qules(bundle_dir);
fprintf('\n');
test_stress(bundle_dir);
end
