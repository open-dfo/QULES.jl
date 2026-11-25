function matlab_package_prototype(bundle_dir, out_dir)
%MATLAB_PACKAGE_PROTOTYPE Generate this platform's Unix prototype and thunk.
%   Writes qules_proto_<arch>.m and its compiled thunk to OUT_DIR.

here = fileparts(mfilename('fullpath'));
if ismac
    filename = 'libqules.dylib';
else
    filename = 'libqules.so';
end
lib = fullfile(bundle_dir, 'lib', filename);
proto_name = ['qules_proto_' computer('arch')];
old_dir = pwd;
restore_dir = onCleanup(@() cd(old_dir)); %#ok<NASGU>
cd(out_dir);
[missing, warnings] = loadlibrary(lib, fullfile(here, 'matlab_probe.h'), ...
    'alias', 'qules_prototype_build', 'mfilename', proto_name);
disp(warnings);
assert(isempty(missing), 'Missing library functions: %s', strjoin(missing, ', '));

% Keep the generated prototype relocatable when the package is installed.
proto = [proto_name '.m'];
contents = fileread(proto);
thunk = [dir('*_thunk_*.so'); dir('*_thunk_*.dylib')];
if contains(contents, '''Thunk''')
    assert(isscalar(thunk), 'Expected one compiled MATLAB thunk.');
    assignment = sprintf('ThunkLibName = fullfile(fileparts(mfilename(''fullpath'')), ''%s'');', thunk.name);
    pattern = '(?m)^\s*ThunkLibName\s*=.*?;[^\r\n]*';
    assert(isscalar(regexp(contents, pattern, 'start')), 'Unexpected prototype format.');
    writelines(regexprep(contents, pattern, assignment), proto);
end
delete('*_thunk_*.c');
delete('*.exp');
delete('*.lib');
end
