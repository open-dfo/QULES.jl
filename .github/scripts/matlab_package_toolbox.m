function matlab_package_toolbox(toolbox_dir, output_file, version)
%MATLAB_PACKAGE_TOOLBOX Package the assembled MATLAB folder as one .mltbx.

opts = matlab.addons.toolbox.ToolboxOptions(toolbox_dir, ...
    'c7503c9d-f416-4507-84a1-9c88b1a6c338');
opts.ToolboxName = 'QULES';
opts.ToolboxVersion = version;
opts.Summary = 'Derivative-free optimization with the QULES solver.';
opts.Description = ['Downloads the QULES native library for this platform ' ...
    '(about 85 MB) on the first call to qules.load.'];
opts.ToolboxMatlabPath = {toolbox_dir};
opts.MinimumMatlabRelease = 'R2025a';
opts.OutputFile = output_file;
platforms = opts.SupportedPlatforms;
platforms.Win64 = true;
platforms.Glnxa64 = true;
platforms.Maci64 = true;
platforms.MatlabOnline = false;
opts.SupportedPlatforms = platforms;
matlab.addons.toolbox.packageToolbox(opts);
info = dir(output_file);
fprintf('Packaged %s (%.1f MB)\n', output_file, info.bytes / 2^20);
end
