function drain_log()
%DRAIN_LOG Print everything the native log buffer holds (log mode 2).
%   Used with verbose = true, where QULES.SESSION routes the optimizer's
%   iteration table into the library's internal buffer. Printing with fprintf
%   makes the output capturable with evalc and diary.

cap = 4096;
buf = libpointer('uint8Ptr', zeros(1, cap, 'uint8'));
while true
    n = double(calllib('qules', 'qules_log_read', buf, uint64(cap)));
    if n == 0
        break
    end
    fprintf('%s', char(buf.Value(1:n)));
end
end
