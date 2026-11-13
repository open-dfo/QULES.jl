function o = parse_options(args)
%PARSE_OPTIONS Merge user options with the QULES defaults.
%   O = PARSE_OPTIONS(ARGS) takes the cell array of trailing arguments of
%   QULES.OPTIMIZE / QULES.SESSION and returns a struct with the fields
%   max_evals, delta0, delta_min, delta_max, verbose and rotation. ARGS is
%   either empty, a single options struct (or []), or name-value pairs.
%   An empty value means "use the default". Unknown names are rejected.

o = struct( ...
    'max_evals', 300, ...
    'delta0',    1.0, ...
    'delta_min', 1e-8, ...
    'delta_max', 100.0, ...
    'verbose',   false, ...
    'rotation',  true);

if isempty(args)
    return
end

if numel(args) == 1
    opts = args{1};
    if isempty(opts)
        return
    end
    if ~isstruct(opts) || ~isscalar(opts)
        error('qules:args', 'Options must be a scalar struct or name-value pairs.');
    end
    names  = fieldnames(opts);
    values = struct2cell(opts);
else
    if mod(numel(args), 2) ~= 0
        error('qules:args', 'Options must be a struct or name-value pairs.');
    end
    names  = args(1:2:end);
    values = args(2:2:end);
end

for k = 1:numel(names)
    name = names{k};
    if ~(ischar(name) || (isstring(name) && isscalar(name)))
        error('qules:args', 'Option names must be character vectors or strings.');
    end
    name = char(name);
    if ~isfield(o, name)
        error('qules:args', 'Unknown option "%s".', name);
    end
    if isempty(values{k})
        continue
    end
    o.(name) = values{k};
end

check_scalar(o, 'max_evals');
check_scalar(o, 'delta0');
check_scalar(o, 'delta_min');
check_scalar(o, 'delta_max');
check_flag(o, 'verbose');
check_flag(o, 'rotation');
if o.max_evals < 1 || o.max_evals ~= floor(o.max_evals)
    error('qules:args', 'max_evals must be a positive integer.');
end
end

function check_scalar(o, name)
v = o.(name);
if ~isnumeric(v) || ~isscalar(v) || ~isreal(v) || ~isfinite(v)
    error('qules:args', '%s must be a real finite scalar.', name);
end
end

function check_flag(o, name)
v = o.(name);
if ~(islogical(v) || isnumeric(v)) || ~isscalar(v)
    error('qules:args', '%s must be a logical scalar.', name);
end
end
