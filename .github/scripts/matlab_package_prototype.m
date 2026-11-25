function matlab_package_prototype(bundle_dir)
%MATLAB_PACKAGE_PROTOTYPE Generate the Unix prototype and thunk for release.

here = fileparts(mfilename('fullpath'));
private_dir = fullfile(fileparts(bundle_dir), '+qules', 'private');
if ismac
    filename = 'libqules.dylib';
else
    filename = 'libqules.so';
end
lib = fullfile(bundle_dir, 'lib', filename);
old_dir = pwd;
restore_dir = onCleanup(@() cd(old_dir)); %#ok<NASGU>
cd(private_dir);
[missing, warnings] = loadlibrary(lib, fullfile(here, 'matlab_probe.h'), ...
    'alias', 'qules_prototype_build', 'mfilename', 'qules_unix_proto');
disp(warnings);
assert(isempty(missing), 'Missing library functions: %s', strjoin(missing, ', '));

% Keep the generated prototype relocatable when the package is extracted.
proto = 'qules_unix_proto.m';
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
end
