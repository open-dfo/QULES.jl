classdef Session < handle
%SESSION Ask/tell interface to the QULES optimizer.
%   S = QULES.SESSION(X0) creates a native optimization session starting from
%   the real vector X0 with the default options. The host drives the loop:
%
%       s = qules.Session([3; 1], 'max_evals', 40);
%       while true
%           x = s.ask();            % [] once the run is finished
%           if isempty(x), break, end
%           s.tell(f(x));
%       end
%       r = s.best();               % x_best, f_best, evals, delta
%       delete(s);                  % releases the native session
%
%   S = QULES.SESSION(X0, OPTS) and S = QULES.SESSION(X0, NAME, VALUE, ...)
%   accept the same options as QULES.OPTIMIZE:
%       max_evals  maximum number of function evaluations   (default 300)
%       delta0     initial trust-region radius               (default 1.0)
%       delta_min  minimum trust-region radius               (default 1e-8)
%       delta_max  maximum trust-region radius               (default 100.0)
%       verbose    print the iteration table                 (default false)
%       rotation   learn the envelope orientation            (default true)
%
%   DELETE (or clearing the last reference) frees the native session. A
%   native failure inside ask or tell also frees it.
%
%   Error identifiers: qules:notloaded, qules:args, qules:log, qules:create,
%   qules:closed, qules:ask, qules:tell, qules:objective, qules:getbest.
%
%   See also QULES.OPTIMIZE, QULES.LOAD.

    properties (SetAccess = private)
        n          % number of variables
        options    % resolved options struct
    end

    properties (Access = private)
        id = int64(0)   % native session id; 0 once released
        x_ptr           % doublePtr buffer reused for every ask
    end

    methods
        function obj = Session(x0, varargin)
            if ~libisloaded('qules')
                error('qules:notloaded', 'QULES is not loaded; call qules.load(bundle_dir) first.');
            end
            if ~isnumeric(x0) || ~isreal(x0) || isempty(x0) || ~isvector(x0) || ~all(isfinite(x0))
                error('qules:args', 'x0 must be a non-empty real finite vector.');
            end
            o = parse_options(varargin);

            x0 = double(x0(:));
            obj.n = numel(x0);
            obj.options = o;

            if o.verbose
                % Route the optimizer log into the native buffer; drained by drain().
                rc = calllib('qules', 'qules_set_log_mode', int32(2), libpointer, libpointer);
                if rc ~= 0
                    error('qules:log', 'qules_set_log_mode failed with code %d.', rc);
                end
            end

            id = calllib('qules', 'qules_session_create', uint64(obj.n), x0, ...
                uint64(o.max_evals), double(o.delta0), double(o.delta_min), double(o.delta_max), ...
                int32(logical(o.verbose)), int32(logical(o.rotation)));
            if id < 0
                error('qules:create', 'qules_session_create failed with code %d.', id);
            end
            obj.id = int64(id);
            obj.x_ptr = libpointer('doublePtr', zeros(obj.n, 1));
        end

        function x = ask(obj)
        %ASK Next point to evaluate as an n-by-1 column, or [] when finished.
            obj.require_open();
            rc = calllib('qules', 'qules_session_ask', obj.id, obj.x_ptr);
            obj.drain();
            if rc == 1
                x = reshape(obj.x_ptr.Value, obj.n, 1);
            elseif rc == 0
                x = [];
            else
                obj.release();
                error('qules:ask', 'qules_session_ask failed with code %d.', rc);
            end
        end

        function tell(obj, fx)
        %TELL Hand the objective value of the last asked point back to QULES.
            obj.require_open();
            if ~isnumeric(fx) || ~isscalar(fx) || ~isreal(fx)
                error('qules:objective', 'The objective must return a real scalar.');
            end
            rc = calllib('qules', 'qules_session_tell', obj.id, double(fx));
            obj.drain();
            if rc == 1
                error('qules:tell', 'No point is awaiting a value; call ask first.');
            elseif rc ~= 0
                obj.release();
                error('qules:tell', 'qules_session_tell failed with code %d.', rc);
            end
        end

        function r = best(obj)
        %BEST Best point so far: struct with x_best, f_best, evals and delta.
        %   delta is NaN until the session has finished. Raises qules:getbest
        %   before the first tell.
            obj.require_open();
            xb_ptr    = libpointer('doublePtr', zeros(obj.n, 1));
            fb_ptr    = libpointer('doublePtr', 0);
            evals_ptr = libpointer('uint64Ptr', uint64(0));
            delta_ptr = libpointer('doublePtr', 0);
            rc = calllib('qules', 'qules_session_get_best', obj.id, xb_ptr, fb_ptr, evals_ptr, delta_ptr);
            obj.drain();
            if rc ~= 0
                error('qules:getbest', 'qules_session_get_best failed with code %d.', rc);
            end
            r = struct( ...
                'x_best', reshape(xb_ptr.Value, obj.n, 1), ...
                'f_best', fb_ptr.Value, ...
                'evals',  double(evals_ptr.Value), ...
                'delta',  delta_ptr.Value);
        end

        function tf = is_finished(obj)
        %IS_FINISHED True once the optimizer has stopped.
            obj.require_open();
            tf = calllib('qules', 'qules_session_is_finished', obj.id) ~= 0;
        end

        function delete(obj)
        %DELETE Free the native session (idempotent).
            obj.release();
        end
    end

    methods (Access = private)
        function require_open(obj)
            if obj.id <= 0
                error('qules:closed', 'The session has been released.');
            end
        end

        function release(obj)
            if obj.id > 0 && libisloaded('qules')
                calllib('qules', 'qules_session_free', obj.id);
            end
            obj.id = int64(0);
        end

        function drain(obj)
            if obj.options.verbose
                drain_log();
            end
        end
    end
end
