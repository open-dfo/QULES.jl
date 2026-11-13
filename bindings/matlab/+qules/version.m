function v = version()
%VERSION Version of the loaded QULES library.
%   V = QULES.VERSION() returns [MAJOR MINOR PATCH] as a 1x3 double vector.
%   Call QULES.LOAD first.
%
%   See also QULES.LOAD.

if ~libisloaded('qules')
    error('qules:notloaded', 'QULES is not loaded; call qules.load(bundle_dir) first.');
end
v = double([ ...
    calllib('qules', 'qules_version_major'), ...
    calllib('qules', 'qules_version_minor'), ...
    calllib('qules', 'qules_version_patch')]);
end
