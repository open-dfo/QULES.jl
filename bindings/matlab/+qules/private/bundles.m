function manifest = bundles()
%BUNDLES Release version and SHA-256 of each platform's bundle archive.
%   The release workflow overwrites this file with the archives' digests.

manifest.version = '0.1.7';
manifest.sha256 = struct('windows_x86_64', '', 'linux_x86_64', '', ...
    'macos_x86_64', '', 'macos_arm64', '');
end
