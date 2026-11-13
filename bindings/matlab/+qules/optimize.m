function result = optimize(f, x0, varargin)
%OPTIMIZE Minimize a black-box function with QULES.
%   R = QULES.OPTIMIZE(F, X0) minimizes the scalar function F starting from
%   the real vector X0. F is a function handle taking an n-by-1 column vector
%   and returning a real scalar. Call QULES.LOAD first.
%
%   R = QULES.OPTIMIZE(F, X0, OPTS) takes an options struct and
%   R = QULES.OPTIMIZE(F, X0, NAME, VALUE, ...) takes name-value pairs, with
%   any of
%       max_evals  maximum number of function evaluations   (default 300)
%       delta0     initial trust-region radius               (default 1.0)
%       delta_min  minimum trust-region radius               (default 1e-8)
%       delta_max  maximum trust-region radius               (default 100.0)
%       verbose    print the iteration table                 (default false)
%       rotation   learn the envelope orientation            (default true)
%
%   R is a struct with fields x_best (n-by-1 column), f_best, evals and delta.
%
%   An error raised by F is rethrown after the native session is released.
%
%   Error identifiers: qules:notloaded, qules:args, qules:log, qules:create,
%   qules:ask, qules:tell, qules:getbest, qules:objective.
%
%   See also QULES.LOAD, QULES.SESSION.

if ~isa(f, 'function_handle')
    error('qules:args', 'f must be a function handle.');
end

s = qules.Session(x0, varargin{:});
try
    while true
        x = s.ask();
        if isempty(x)
            break
        end
        s.tell(f(x));
    end
    result = s.best();
catch err
    delete(s);
    rethrow(err);
end
delete(s);
end
