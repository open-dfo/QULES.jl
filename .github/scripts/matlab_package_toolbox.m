function matlab_package_toolbox(package_dir, output_file, version)
%MATLAB_PACKAGE_TOOLBOX Package the staged MATLAB folder as a .mltbx toolbox.

% Toolbox archives cannot hold symlinks; qules.load recreates them from
% symlinks.txt on first use.
manifest = fullfile(package_dir, 'libqules', 'symlinks.txt');
if isfile(manifest)
    for line = readlines(manifest, 'EmptyLineRule', 'skip')'
        parts = split(line, sprintf('\t'));
        delete(fullfile(package_dir, 'libqules', char(parts(1))));
    end
end

opts = matlab.addons.toolbox.ToolboxOptions(package_dir, ...
    'c7503c9d-f416-4507-84a1-9c88b1a6c338');
opts.ToolboxName = 'QULES';
opts.ToolboxVersion = version;
opts.Summary = 'Derivative-free optimization with the QULES solver.';
opts.ToolboxMatlabPath = {package_dir};
opts.MinimumMatlabRelease = 'R2025a';
opts.OutputFile = output_file;
platforms = opts.SupportedPlatforms;
for name = fieldnames(platforms)'
    platforms.(name{1}) = false;
end
switch computer('arch')
    case 'win64', platforms.Win64 = true;
    case 'glnxa64', platforms.Glnxa64 = true;
    otherwise, platforms.Maci64 = true;
end
opts.SupportedPlatforms = platforms;
matlab.addons.toolbox.packageToolbox(opts);
info = dir(output_file);
fprintf('Packaged %s (%.0f MB)\n', output_file, info.bytes / 2^20);
end
