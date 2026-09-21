%misc. eeg trigger codes, not experimental
function trigger = two_group_motion_misc_trigger(trigger_name)

switch lower(char(trigger_name))

    case 'fixation'
        trigger = 1;

    case {'response_circle', 'response circle'}
        trigger = 2;

    case {'left_arrow_response', 'left arrow response'}
        trigger = 3;

    case {'right_arrow_response', 'right arrow response'}
        trigger = 4;

    case {'space_bar_response', 'space bar response'}
        trigger = 5;

    otherwise
        error('Unknown miscellaneous EEG trigger: %s', trigger_name);
end

end