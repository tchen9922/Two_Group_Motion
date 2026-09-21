function result = two_group_motion_trigger_map( ...
    common_rotation_deg, ...
    condition_direction, ...
    coherence_percent)
% two_group_motion_trigger_map 
%
% Converts the actual experimental values used by
% two_group_motion_demo into an EEG trigger.
%
% INPUTS
%   common_rotation_deg
%       Common rotation used for the current trial:
%       0, 45, 90, 135, 180, 225, 270, or 315
%
%   condition_direction
%       Condition direction used by two_group_motion_demo:
%       0, 10, or 45 degrees
%
%   coherence_percent
%       Coherence for the current trial:
%       33, 55, or 100
%
% OUTPUT
%   result
%       Structure containing the trigger and experimental labels.


%% ================================================================
% EXPERIMENTAL LEVEL VALUES
% ================================================================

rotation_values_deg = ...
    [ 0, 60, 120, 180, 240, 300 ];

condition_direction_values_deg = ...
    [ 0, -3.75, -7.5, -16, -30, -45, -60];

coherence_values_percent = ...
    [33 55 100];


%% ================================================================
% FIND COMMON ROTATION LEVEL
% ================================================================

degree_level = find( ...
    rotation_values_deg == common_rotation_deg, ...
    1);

if isempty(degree_level)
    error( ...
        'Invalid common rotation value: %g degrees.', ...
        common_rotation_deg);
end


%% ================================================================
% FIND CONDITION DIRECTION LEVEL
% ================================================================

condition_direction_index = find( ...
    condition_direction_values_deg == condition_direction, ...
    1);

if isempty(condition_direction_index)
    error( ...
        'Invalid condition direction value: %g degrees.', ...
        condition_direction);
end

% Convert MATLAB index 1,2,3 to experimental level 0,1,2
condition_direction_level = condition_direction_index - 1;


%% ================================================================
% FIND COHERENCE LEVEL
% ================================================================

coherence_level = find( ...
    coherence_values_percent == coherence_percent, ...
    1);

if isempty(coherence_level)
    error( ...
        'Invalid coherence value: %g%%.', ...
        coherence_percent);
end


%% ================================================================
% CALCULATE EEG TRIGGER
% ================================================================

trigger = 11 ...
    + (condition_direction_level * 18) ...
    + ((coherence_level - 1) * 6) ...
    + (degree_level - 1);


%% ================================================================
% CREATE RESULT
% ================================================================

result.trigger = trigger;

result.condition_direction_level = condition_direction_level;
result.condition_direction = condition_direction;

result.coherence_level = coherence_level;
result.coherence_percent = coherence_percent;

result.degree_level = degree_level;
result.common_rotation_deg = common_rotation_deg;

result.label = sprintf( ...
    'Condition direction %d (%g deg) | Coherence %d (%g%%) | Rotation %d (%g deg)', ...
    condition_direction_level, ...
    condition_direction, ...
    coherence_level, ...
    coherence_percent, ...
    degree_level, ...
    common_rotation_deg);

end
