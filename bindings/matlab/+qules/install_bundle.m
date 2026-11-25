function bundle_dir = install_bundle(archive)
%INSTALL_BUNDLE Install the QULES native bundle for this platform.
%   DIR = QULES.INSTALL_BUNDLE() downloads the bundle archive of the GitHub
%   release matching this toolbox, checks its SHA-256 and extracts it into a
%   per-user folder, then returns that folder. QULES.LOAD calls it on first
%   use; later calls return the installed folder without downloading.
%   DIR = QULES.INSTALL_BUNDLE(ARCHIVE) installs from an archive downloaded
%   beforehand, for machines without internet access.
%
%   The folder is %LOCALAPPDATA%\qules\matlab\<version>\<platform> on Windows
%   and ~/.qules/matlab/<version>/<platform> on Linux and macOS.
%
%   See also QULES.LOAD.

manifest = bundles();
platforms = struct('win64', 'windows-x86_64', 'glnxa64', 'linux-x86_64', ...
    'maci64', 'macos-x86_64', 'maca64', 'macos-arm64');
arch = computer('arch');
if ~isfield(platforms, arch)
    error('qules:install', 'Unsupported MATLAB architecture: %s.', arch);
end
platform = platforms.(arch);
expected = manifest.sha256.(strrep(platform, '-', '_'));

if ispc
    root = fullfile(getenv('LOCALAPPDATA'), 'qules', 'matlab');
else
    root = fullfile(getenv('HOME'), '.qules', 'matlab');
end
bundle_dir = fullfile(root, manifest.version, platform);
marker = fullfile(bundle_dir, '.installed');
if isfile(marker)
    return
end

if nargin < 1 || isempty(archive)
    if isempty(expected)
        error('qules:install', ['This copy of the QULES MATLAB package has no ' ...
            'release bundle. Pass a bundle directory to qules.load.']);
    end
    url = sprintf(['https://github.com/open-dfo/QULES.jl/releases/download/' ...
        '%s/qules-bundle-%s.zip'], manifest.version, platform);
    archive = [tempname '.zip'];
    remove_archive = onCleanup(@() delete_file(archive)); %#ok<NASGU>
    fprintf('Downloading the QULES library for %s (first use only)...\n', platform);
    websave(archive, url, weboptions('Timeout', 120));
end
archive = char(archive);
if ~isfile(archive)
    error('qules:install', 'Bundle archive not found: "%s".', archive);
end
if ~isempty(expected) && ~strcmpi(sha256(archive), expected)
    error('qules:install', ['"%s" is not the QULES %s bundle for %s ' ...
        '(SHA-256 mismatch).'], archive, manifest.version, platform);
end

% Extract next to the final folder and rename it into place, so an
% interrupted install never leaves a half-extracted bundle behind.
[~, token] = fileparts(tempname);
staging = [bundle_dir '.' token];
remove_staging = onCleanup(@() remove_folder(staging)); %#ok<NASGU>
mkdir(staging);
unzip(archive, staging);
fclose(fopen(fullfile(staging, '.installed'), 'w'));
if isfolder(bundle_dir) && ~isfile(marker)
    rmdir(bundle_dir, 's');    % left over from an older, unfinished install
end
if ~isfolder(bundle_dir)
    [ok, message] = movefile(staging, bundle_dir);
    if ~ok && ~isfile(marker)  % another MATLAB may have finished first
        error('qules:install', 'Cannot install the bundle in "%s": %s', bundle_dir, message);
    end
end
fprintf('QULES library installed in %s\n', bundle_dir);
end

function digest = sha256(file)
md = java.security.MessageDigest.getInstance('SHA-256');
fid = fopen(file, 'r');
close_file = onCleanup(@() fclose(fid)); %#ok<NASGU>
while true
    chunk = fread(fid, 2^24, '*uint8');
    if isempty(chunk)
        break
    end
    md.update(typecast(chunk, 'int8'));
end
digest = lower(reshape(dec2hex(typecast(md.digest(), 'uint8'), 2)', 1, []));
end

function delete_file(file)
if isfile(file)
    delete(file);
end
end

function remove_folder(folder)
if isfolder(folder)
    rmdir(folder, 's');
end
end
