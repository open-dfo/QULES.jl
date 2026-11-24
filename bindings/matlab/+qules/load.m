function load(bundle_dir)
%LOAD Load the QULES native bundle (once per MATLAB session).
%   QULES.LOAD(BUNDLE_DIR) loads BUNDLE_DIR/bin/qules.dll and starts Julia.
%   QULES.LOAD() reads BUNDLE_DIR from the QULES_BUNDLE environment variable.
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
        error('qules:load', ['qules.load requires the bundle directory as an ' ...
            'argument or in the QULES_BUNDLE environment variable.']);
    end
end
if ~(ischar(bundle_dir) || (isstring(bundle_dir) && isscalar(bundle_dir)))
    error('qules:load', 'The bundle directory must be a character vector or string.');
end
bundle_dir = char(bundle_dir);
bin_dir = fullfile(bundle_dir, 'bin');
dll = fullfile(bin_dir, 'qules.dll');
if ~isfile(dll)
    error('qules:load', 'qules.dll not found at "%s".', dll);
end

% Julia loads its dependent DLLs by name, so bin/ must be on PATH.
setenv('PATH', [bin_dir pathsep getenv('PATH')]);

% qules_proto lives in +qules/private; its ThunkLibName points at the thunk
% DLL in the same folder, so no compiler is involved.
loadlibrary(dll, @qules_proto, 'alias', 'qules');

if ~initialized
    % Julia otherwise starts half the cores' worth of idle OpenBLAS threads
    % (64 on a 128-core node). A count set by the user is respected.
    blas_vars = {'OPENBLAS_NUM_THREADS', 'GOTO_NUM_THREADS', 'OMP_NUM_THREADS'};
    if all(cellfun(@(name) isempty(getenv(name)), blas_vars))
        setenv('OPENBLAS_NUM_THREADS', '1');
        restore = onCleanup(@() remove_env('OPENBLAS_NUM_THREADS')); %#ok<NASGU>
    end
    % argc = 0, argv = NULL. Exactly once per process; never shut down.
    calllib('qules', 'init_julia', int32(0), libpointer);
    initialized = true;
end
end

function remove_env(name)
try
    unsetenv(name);       % R2022b and later
catch
    setenv(name, '');     % removes the variable on Windows
end
end
