function load(bundle_dir)
%LOAD Load the QULES native bundle (once per MATLAB session).
%   QULES.LOAD(BUNDLE_DIR) loads the platform library from BUNDLE_DIR and
%   starts Julia. On Linux and macOS the MATLAB package must include the
%   prototype and thunk generated for the current platform.
%   QULES.LOAD() reads BUNDLE_DIR from the QULES_BUNDLE environment variable
%   and otherwise uses the libqules folder installed with the toolbox.
%   Further calls return immediately. Never call unloadlibrary('qules'):
%   Julia cannot be restarted in the same process.
%
%   See also QULES.OPTIMIZE, QULES.SESSION, QULES.VERSION.

persistent initialized
if isempty(initialized)
    initialized = false;
end

if libisloaded('qules')
    return
end

if nargin < 1 || isempty(bundle_dir)
    bundle_dir = getenv('QULES_BUNDLE');
    if isempty(bundle_dir)
        bundle_dir = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'libqules');
        if ~isfolder(bundle_dir)
            error('qules:load', ['qules.load requires the bundle directory as an ' ...
                'argument or in the QULES_BUNDLE environment variable.']);
        end
    end
end
if ~(ischar(bundle_dir) || (isstring(bundle_dir) && isscalar(bundle_dir)))
    error('qules:load', 'The bundle directory must be a character vector or string.');
end
bundle_dir = char(bundle_dir);
switch computer('arch')
    case 'win64'
        lib = fullfile(bundle_dir, 'bin', 'qules.dll');
        proto = @qules_proto;
        init_argc = int32(0);
        init_argv = libpointer;
    case {'glnxa64', 'maci64', 'maca64'}
        if ismac
            filename = 'libqules.dylib';
        else
            filename = 'libqules.so';
        end
        lib = fullfile(bundle_dir, 'lib', filename);
        if ~isfile(fullfile(fileparts(mfilename('fullpath')), ...
                'private', 'qules_unix_proto.m'))
            error('qules:load', 'Use the QULES MATLAB package built for %s.', computer('arch'));
        end
        restore_symlinks(bundle_dir);
        proto = @qules_unix_proto;
        init_argc = int32(1);
        init_argv = libpointer('stringPtrPtr', {'qules'});
    otherwise
        error('qules:load', 'Unsupported MATLAB architecture: %s.', computer('arch'));
end
if ~isfile(lib)
    error('qules:load', 'QULES library not found at "%s".', lib);
end
if ispc
    % Julia loads its dependent DLLs by name, so bin/ must be on PATH.
    setenv('PATH', [fileparts(lib) pathsep getenv('PATH')]);
end
loadlibrary(lib, proto, 'alias', 'qules');

if ~initialized
    % Julia otherwise starts half the cores' worth of idle OpenBLAS threads
    % (64 on a 128-core node). A count set by the user is respected.
    blas_vars = {'OPENBLAS_NUM_THREADS', 'GOTO_NUM_THREADS', 'OMP_NUM_THREADS'};
    if all(cellfun(@(name) isempty(getenv(name)), blas_vars))
        setenv('OPENBLAS_NUM_THREADS', '1');
        restore = onCleanup(@() remove_env('OPENBLAS_NUM_THREADS')); %#ok<NASGU>
    end
    % Initialize Julia exactly once per process.
    calllib('qules', 'init_julia', init_argc, init_argv);
    initialized = true;
end
end

function restore_symlinks(bundle_dir)
% Toolbox archives cannot hold symlinks, so each library is shipped once under
% its real name and the links listed in symlinks.txt are recreated here.
manifest = fullfile(bundle_dir, 'symlinks.txt');
if ~isfile(manifest)
    return
end
for line = readlines(manifest, 'EmptyLineRule', 'skip')'
    parts = split(line, sprintf('\t'));
    link = fullfile(bundle_dir, char(parts(1)));
    if isfile(link) || isfolder(link) || is_link(link)
        continue
    end
    [status, output] = system(sprintf('/bin/ln -s %s %s', ...
        shell_quote(parts(2)), shell_quote(link)));
    if status ~= 0 && ~is_link(link)  % a concurrent first load may have made it
        error('qules:load', ['Cannot create "%s": %s\nInstall the QULES ' ...
            'toolbox in a writable folder.'], link, strtrim(output));
    end
end
end

function tf = is_link(path)
tf = system(sprintf('/bin/test -L %s', shell_quote(path))) == 0;
end

function quoted = shell_quote(text)
quoted = ['''' strrep(char(text), '''', '''\''''') ''''];
end

function remove_env(name)
try
    unsetenv(name);       % R2022b and later
catch
    setenv(name, '');     % removes the variable on Windows
end
end
