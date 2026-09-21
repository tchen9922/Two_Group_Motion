function result = two_group_motion_demo(varargin)
% TWO_GROUP_MOTION_DEMO Laptop demo of nested center/group/supergroup motion.
%
% Simplest use:
%   two_group_motion_demo
%
% Useful modes:
%   two_group_motion_demo('Repetitions', 5)
%   two_group_motion_demo('UseTrialSubset', true, 'SubsetTrialCount', 16)
%   two_group_motion_demo('SmokeTest', true, 'SkipEyeLink', true)
%   two_group_motion_demo('InteractiveSmokeTest', true)
%   r = two_group_motion_demo('ValidateOnly', true)
%   r = two_group_motion_demo('DataSelfTest', true)
%   two_group_motion_demo('GenerateFigures', true)
%   two_group_motion_demo('SoundTest', true)
%  two_group_motion_demo('SkipEyeLink', true)
% Scientific coordinates are x-right/y-up. Psychtoolbox drawing converts y
% to screen-down exactly once. See docs/scientific_source_mapping.md.

script_dir = fileparts(mfilename('fullpath'));
addpath(fullfile(script_dir, 'helperScripts'));
opts = parse_options(script_dir, varargin{:});
cfg = load_demo_config(opts.ConfigPath);
cfg = apply_overrides(cfg, opts);
validate_design_config(cfg);

% EyeLink control
expParams = struct();

% EyeLink is ON by default
expParams.skipEyeLink = false;

% Command-line override:
% true  = skip EyeLink completely
% false = use EyeLink normally
if ~isempty(opts.SkipEyeLink)
    expParams.skipEyeLink = logical(opts.SkipEyeLink);
end

rng(double(cfg.random_seed), 'twister');
[schedule, schedule_coherence_indices, schedule_rotation_indices, ...
    schedule_block_numbers, schedule_meta] = rotation_block_schedule( ...
    numel(cfg.condition_inner_direction_deg), numel(cfg.coherence_values_percent), ...
    numel(cfg.rotation_values_deg), cfg.repetitions, ...
    cfg.use_trial_subset, cfg.subset_trial_count);
cfg.full_design_trial_count = schedule_meta.full_design_trial_count;
cfg.scheduled_trial_count = schedule_meta.scheduled_trial_count;
cfg.scheduled_rotation_block_count = schedule_meta.scheduled_block_count;
if cfg.counterbalance_surround_colors
    schedule_surround_colors_swapped = rand(1, numel(schedule)) < 0.5;
else
    schedule_surround_colors_swapped = false(1, numel(schedule));
end
schedule_common_rotation_deg = cfg.rotation_values_deg(schedule_rotation_indices);
vectors = velocity_table(cfg);
%validation = validate_scientific_state(cfg, schedule, ...
%    schedule_rotation_indices, schedule_block_numbers, vectors);
rotation_validation = validate_common_rotations(cfg, schedule, ...
    schedule_common_rotation_deg);

result = struct();
result.config = cfg;
result.schedule_condition_indices = schedule;
result.schedule_coherence_indices = schedule_coherence_indices;
result.schedule_coherence_percent = cfg.coherence_values_percent(schedule_coherence_indices);
result.schedule_rotation_indices = schedule_rotation_indices;
result.schedule_block_numbers = schedule_block_numbers;
result.schedule_meta = schedule_meta;
result.schedule_surround_colors_swapped = schedule_surround_colors_swapped;
result.schedule_common_rotation_deg = schedule_common_rotation_deg;
result.vectors = vectors;
%result.validation = validation;
result.rotation_validation = rotation_validation;

if opts.GenerateFigures
    result.figure_paths = generate_parameter_figures(script_dir, cfg, vectors);
    return;
end
if opts.SoundTest
    play_confirmation_tone(cfg);
    result.sound_test = validate_confirmation_tone(cfg);
    return;
end
if opts.ValidateOnly
    result.keyboard_validation = validate_keyboard_mapping(cfg);
    result.display_validation = validate_display_selection();
    result.audio_validation = validate_confirmation_tone(cfg);
    result.color_validation = validate_color_mapping(cfg);
    return;
end
if opts.DataSelfTest
    result.data_self_test = run_data_self_test(script_dir, cfg, opts);
    return;
end
%if ~validation.passed
%    error('Scientific configuration validation failed: %s', ...
%        strjoin(validation.errors, '; '));
%end
if ~rotation_validation.passed
    error('Common-rotation validation failed; rotated velocities do not recover the center-aligned construction.');
end

if exist('Screen', 'file') == 0
    error('Psychtoolbox Screen is unavailable. See MATLAB_DEPENDENCIES.md.');
end

% ---------------------------------------------------------
% Psychtoolbox / EEG initialization
% ---------------------------------------------------------

AssertOpenGL;
PsychDefaultSetup(2);
KbName('UnifyKeyNames');

% Initialize EEG parallel port
ioObj = io64;
status = io64(ioObj);
if status~= 0 
        error('io64 failed to initialize. Try running MATLAB as Administrator.')
end 
port = hex2dec('EFF8');   

old_skip_sync = 1; %Screen('Preference', 'SkipSyncTests');

if ~cfg.fullscreen && cfg.skip_sync_tests_in_windowed_mode
    Screen('Preference', 'SkipSyncTests', 1);
end


% ---------------------------------------------------------
% Output/session setup
% ---------------------------------------------------------

output_dir = resolve_output_directory( ...
    script_dir, cfg.output_directory, opts.OutputDir);

if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

session_id = choose_session_id(opts, cfg);

csv_path = fullfile( ...
    output_dir, sprintf('%s_trials.csv', session_id));

status_path = fullfile( ...
    output_dir, sprintf('%s_session_status.json', session_id));

%adding another file to output for OBS

obs_dir = fullfile(output_dir, 'obsData');

if ~exist(obs_dir, 'dir')
    mkdir(obs_dir);
end

obs_started = false;

assert_output_paths_available(csv_path, status_path);

software = software_identity(script_dir, cfg);

% EyeLink output directory
eye_dir = fullfile(output_dir, 'eyelink');

if ~exist(eye_dir, 'dir')
    mkdir(eye_dir);
end

% ---------------------------------------------------------
% Cleanup guard
% ---------------------------------------------------------

eyetracker = [];
EyeLink_info = struct();
obs_started = false

cleanup_guard = onCleanup(@() restore_environment( ...
    old_skip_sync, ...
    eyetracker, ...
    obs_started));

% ---------------------------------------------------------
% Select display
% ---------------------------------------------------------

screens = Screen('Screens');

[screen_number, screen_selection_reason] = choose_screen_number( ...
    screens, opts.ScreenNumber, cfg.prefer_external_display);

display_rect = screen_global_rect(screen_number);

background = [0 0 0];

if cfg.fullscreen
    requested_rect = [];
else
    display_width = RectWidth(display_rect);
    display_height = RectHeight(display_rect);

    width = min(cfg.window_width_px, display_width - 80);
    height = min(cfg.window_height_px, display_height - 120);

    left = display_rect(1) + ...
        max(20, round((display_width - width) / 2));

    top = display_rect(2) + ...
        max(40, round((display_height - height) / 2));

    requested_rect = [ ...
        left ...
        top ...
        left + width ...
        top + height];
end

% ---------------------------------------------------------
% OPEN PSYCHTOOLBOX WINDOW
% ---------------------------------------------------------
screen_number(1,1)=1;
[window, rect] = PsychImaging( ...
    'OpenWindow', ...
    screen_number, ...
    background, ...
    requested_rect);

Screen('BlendFunction', ...
    window, ...
    GL_SRC_ALPHA, ...
    GL_ONE_MINUS_SRC_ALPHA);

Screen('TextFont', window, 'Arial');
Screen('TextSize', window, 24);

HideCursor;
ListenChar(2);

% ---------------------------------------------------------
% Screen timing information
% ---------------------------------------------------------

ifi = Screen('GetFlipInterval', window);

screen_info = measure_screen( ...
    screen_number, ...
    rect, ...
    cfg, ...
    ifi, ...
    screens, ...
    display_rect, ...
    screen_selection_reason);

keys = key_map();

if abs(screen_info.measured_refresh_hz - 60) > ...
        cfg.refresh_warning_tolerance_hz

    warning( ...
        'Measured refresh %.2f Hz differs from the source 60 Hz display.', ...
        screen_info.measured_refresh_hz);
end

if screen_info.used_fallback_ppd
    warning([ ...
        'Physical display dimensions were unavailable; ' ...
        'visual angles use fallback pixels/degree.']);
end

if ~cfg.fullscreen && cfg.skip_sync_tests_in_windowed_mode
    warning([ ...
        'Windowed demonstration bypasses strict Psychtoolbox sync tests; ' ...
        'timing is diagnostic, not research-grade.']);
end

% ---------------------------------------------------------
% EYE-LINK PARAMETERS
% ---------------------------------------------------------

% IMPORTANT:
% Replace this with the subject ID mechanism you want to use.
% For now, use the session ID if no separate subject ID exists.
expParams.subjID = session_id;

% EyeLink EDF output directory
expParams.subjPaths = struct();
expParams.subjPaths.eyeDir = eye_dir;

% ---------------------------------------------------------
% EYE-LINK
% ---------------------------------------------------------

if expParams.skipEyeLink

    fprintf('\n*** EyeLink SKIPPED ***\n');
    eyetracker = [];
    EyeLink_info = struct('backend', 'none', 'skipped', true);

else

    fprintf('\n*** EyeLink ENABLED ***\n');

    [eyetracker, EyeLink_info] = initEyeLinkTracker( ...
        window, ...
        rect, ...
        expParams);

    calResult = calibrateEyeLink( ...
        window, ...
        rect, ...
        eyetracker, ...
        expParams);

    if isstruct(calResult) && ...
            isfield(calResult, 'passed') && ...
            ~calResult.passed

        error('two_group_motion_demo:EyeLinkCalibrationFailed', ...
            'EyeLink calibration did not pass.');
    end

    eyetracker.start_recording();

    WaitSecs(0.05);
end

[window, rect] = PsychImaging('OpenWindow', screen_number, background, requested_rect);
Screen('BlendFunction', window, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
Screen('TextFont', window, 'Arial');
Screen('TextSize', window, 24);
HideCursor;
ListenChar(2);

ifi = Screen('GetFlipInterval', window);
screen_info = measure_screen(screen_number, rect, cfg, ifi, screens, ...
    display_rect, screen_selection_reason);
keys = key_map();

if abs(screen_info.measured_refresh_hz - 60) > cfg.refresh_warning_tolerance_hz
    warning('Measured refresh %.2f Hz differs from the source 60 Hz display.', screen_info.measured_refresh_hz);
end
if screen_info.used_fallback_ppd
    warning('Physical display dimensions were unavailable; visual angles use fallback pixels/degree.');
end
if ~cfg.fullscreen && cfg.skip_sync_tests_in_windowed_mode
    warning('Windowed demonstration bypasses strict Psychtoolbox sync tests; timing is diagnostic, not research-grade.');
end

output_dir = resolve_output_directory(script_dir, cfg.output_directory, opts.OutputDir);
if ~exist(output_dir, 'dir'), mkdir(output_dir); end
session_id = choose_session_id(opts, cfg);
csv_path = fullfile(output_dir, sprintf('%s_trials.csv', session_id));
status_path = fullfile(output_dir, sprintf('%s_session_status.json', session_id));
assert_output_paths_available(csv_path, status_path);
software = software_identity(script_dir, cfg);

rows = struct([]);
session_aborted = false;
abort_stage = '';

try
    instruction_text = sprintf([ ...
        'Keep your eyes focused on the center WHITE DOT.\n\n'...
        'Report the perceived direction of the GREEN CENTER dots.\n\n' ...
        'No dial or mouse is needed. Use the laptop keyboard:\n' ...
        'Tap Left / Right: adjust 1 degree; hold to accelerate\n' ...
        'Shift + Left / Right: 5-degree tap and faster hold\n' ...
        'Enter or Space: confirm\nP: pause\nEscape: save and quit\n\n' ...
        '%d direction x %d coherence trials per block x %d scheduled rotation blocks = %d trials\n' ...
        'Coherence values: %s %%\n' ...
        'Full design: %d rotations x %d block repetitions = %d trials\n\n' ...
        'Press Space to begin.'], ...
        numel(cfg.condition_inner_direction_deg), numel(cfg.coherence_values_percent), ...
        cfg.scheduled_rotation_block_count, numel(schedule), ...
        mat2str(cfg.coherence_values_percent), ...
        numel(cfg.rotation_values_deg), cfg.repetitions, ...
        cfg.full_design_trial_count);
   draw_centered_text(window, instruction_text, [255 255 255]);
Screen('Flip', window);

if cfg.auto_advance

    WaitSecs(0.15);

    % Start OBS automatically in auto/demo mode
    [obs_ok, ~] = sendOBSTrigger( ...
        'SetRecordDirectory', ...
        'recordDirectory', obs_dir);

    if obs_ok
        [obs_ok, ~] = sendOBSTrigger('StartRecording');
    end

    if obs_ok
        obs_started = true;
        fprintf('[OBS] Recording started.\n');
    else
        warning('[OBS] Recording did not start.');
    end

else

    action = wait_for_start_or_abort(keys);

    if action.abort

        session_aborted = true;
        abort_stage = 'instructions';

    else

        % Participant pressed SPACE.
        % Start OBS exactly once, immediately before Trial 1.

        fprintf('[OBS] Starting recording...\n');

        [obs_ok, ~] = sendOBSTrigger( ...
            'SetRecordDirectory', ...
            'recordDirectory', obs_dir);

        if obs_ok
            [obs_ok, ~] = sendOBSTrigger('StartRecording');
        end

        if obs_ok
            obs_started = true;
            fprintf('[OBS] Recording started.\n');
        else
            warning('[OBS] Could not start recording. Continuing experiment.');
        end

    end
end
    for trial_index = 1:numel(schedule)
        if session_aborted, break; end
        condition_index = schedule(trial_index);
        condition_direction = cfg.condition_inner_direction_deg(condition_index);
        coherence_index = schedule_coherence_indices(trial_index);
        coherence_percent = cfg.coherence_values_percent(coherence_index);
        common_rotation_deg = schedule_common_rotation_deg(trial_index);

% Continue constructing the trial below

        vector_state = vector_for_direction(cfg, condition_direction, ...
            common_rotation_deg);
        colors = stimulus_colors(cfg, schedule_surround_colors_swapped(trial_index));
        
       [trial_result, stimulus_state] = run_trial(window, rect, screen_info, cfg, ...
    keys, condition_direction, coherence_percent, common_rotation_deg, ...
    vector_state, colors, ioObj, port);

        row = make_output_row(cfg, software, screen_info, session_id, trial_index, ...
            condition_index, condition_direction, coherence_percent, ...
            vector_state, trial_result, stimulus_state);
        if isempty(rows), rows = row; else, rows(end + 1) = row; end %#ok<AGROW>
        write_rows(csv_path, rows);

        if trial_result.aborted
            session_aborted = true;
            abort_stage = trial_result.abort_stage;
            break;
        end

        write_status(status_path, cfg, software, session_id, csv_path, rows, false, 'running');
        if cfg.intertrial_duration_s > 0
            Screen('FillRect', window, background);
            Screen('Flip', window);
            WaitSecs(cfg.intertrial_duration_s);
        end
    end
% ---------------------------------------------------------
% STOP OBS RECORDING
% ---------------------------------------------------------

if obs_started
    fprintf('[OBS] Stopping recording...\n');

    [obs_ok, ~] = sendOBSTrigger('StopRecording');

    if obs_ok
        fprintf('[OBS] Recording stopped.\n');
    else
        warning('[OBS] Failed to stop recording cleanly.');
    end

    obs_started = false;
end

    if session_aborted
        final_state = sprintf('aborted_at_%s', abort_stage);
        write_status(status_path, cfg, software, session_id, csv_path, rows, true, final_state);
        if isfile(csv_path)
            message = sprintf(['Session stopped safely.\nTrial data are in:\n%s\n' ...
                'Session status is in:\n%s'], csv_path, status_path);
        else
            message = sprintf(['Session stopped before a trial row was created.\n' ...
                'No CSV was created. Session status is in:\n%s'], status_path);
        end
        draw_centered_text(window, message, [255 210 120]);
    else
        final_state = 'completed';
        write_status(status_path, cfg, software, session_id, csv_path, rows, false, final_state);
        draw_centered_text(window, sprintf('Demo complete.\nData are in:\n%s\n\nPress any key.', csv_path), [160 255 180]);
    end
    Screen('Flip', window);
    if session_aborted
        WaitSecs(0.75);
    elseif cfg.auto_advance
        WaitSecs(0.15);
    else
        KbStrokeWait(-1);
    end

    result.csv_path = csv_path;
    result.status_path = status_path;
    result.session_aborted = session_aborted;
    result.completed_trials = completed_count(rows);
    result.recorded_rows = numel(rows);
    result.screen_info = screen_info;
catch ME

    % Stop OBS if MATLAB encounters an error
    if obs_started
        try
            fprintf('[OBS] Stopping recording after MATLAB error...\n');
            sendOBSTrigger('StopRecording');
        catch
            warning('[OBS] Could not stop OBS after MATLAB error.');
        end
    end

    write_status(status_path, cfg, software, session_id, csv_path, rows, true, ...
        ['error:' ME.identifier]);

    rethrow(ME);
end
end

function opts = parse_options(script_dir, varargin)
p = inputParser;
addParameter(p, 'ConfigPath', fullfile(script_dir, 'config', 'demo_default.json'));
addParameter(p, 'Repetitions', []);
addParameter(p, 'UseTrialSubset', []);
addParameter(p, 'SubsetTrialCount', []);
addParameter(p, 'RandomSeed', []);
addParameter(p, 'Fullscreen', []);
addParameter(p, 'ScreenNumber', []);
addParameter(p, 'SessionId', '');
addParameter(p, 'OutputDir', '');
addParameter(p, 'SmokeTest', false);
addParameter(p, 'InteractiveSmokeTest', false);
addParameter(p, 'ValidateOnly', false);
addParameter(p, 'DataSelfTest', false);
addParameter(p, 'GenerateFigures', false);
addParameter(p, 'SoundTest', false);
addParameter(p, 'SkipEyeLink', []);
parse(p, varargin{:});
opts = p.Results;
end

function cfg = load_demo_config(path)
if ~isfile(path), error('Configuration not found: %s', path); end
cfg = jsondecode(fileread(path));
cfg.rotation_values_deg = reshape(double(cfg.rotation_values_deg), 1, []);
cfg.center_minus_inner_direction_deg = reshape( ...
    double(cfg.center_minus_inner_direction_deg), 1, []);
cfg.condition_inner_direction_deg = -cfg.center_minus_inner_direction_deg;
% Normalize coherence immediately after JSON decoding, before validation.
% jsondecode commonly returns JSON arrays as column vectors; downstream code
% expects a simple numeric vector and supports one or many coherence levels.
cfg.coherence_values_percent = reshape( ...
    double(cfg.coherence_values_percent), 1, []);
cfg.center_color_rgb = reshape(double(cfg.center_color_rgb), 1, []);
cfg.inner_color_rgb = reshape(double(cfg.inner_color_rgb), 1, []);
cfg.outer_color_rgb = reshape(double(cfg.outer_color_rgb), 1, []);
cfg.repetitions = double(cfg.rotation_block_repetitions);
cfg.use_trial_subset = logical(cfg.use_trial_subset);
cfg.subset_trial_count = double(cfg.subset_trial_count);
validate_design_config(cfg);
cfg.auto_advance = false;
cfg.simulated = false;
cfg.test_label = 'NONE';
end

function cfg = apply_overrides(cfg, opts)
if sum([logical(opts.SmokeTest), logical(opts.InteractiveSmokeTest), ...
        logical(opts.DataSelfTest), logical(opts.SoundTest)]) > 1
    error('Select only one smoke or data self-test mode.');
end
if ~isempty(opts.Repetitions), cfg.repetitions = double(opts.Repetitions); end
if ~isempty(opts.UseTrialSubset), cfg.use_trial_subset = logical(opts.UseTrialSubset); end
if ~isempty(opts.SubsetTrialCount), cfg.subset_trial_count = double(opts.SubsetTrialCount); end
if ~isempty(opts.RandomSeed), cfg.random_seed = double(opts.RandomSeed); end
if ~isempty(opts.Fullscreen), cfg.fullscreen = logical(opts.Fullscreen); end

if opts.SmokeTest
    cfg.rotation_values_deg = 0;
    cfg.center_minus_inner_direction_deg = [0 45];
    cfg.condition_inner_direction_deg = [0 -45];
    cfg.repetitions = 1;
    cfg.use_trial_subset = false;
    cfg.fixation_duration_s = 0.05;
    cfg.stimulus_duration_s = 0.15;
    cfg.intertrial_duration_s = 0.01;
    cfg.auto_advance = true;
    cfg.simulated = true;
    cfg.test_label = 'SIMULATED/SMOKE-TEST DATA — NOT PARTICIPANT DATA';
    cfg.fullscreen = false;
elseif opts.InteractiveSmokeTest
    cfg.rotation_values_deg = 0;
    cfg.center_minus_inner_direction_deg = 30;
    cfg.condition_inner_direction_deg = -30;
    cfg.repetitions = 1;
    cfg.use_trial_subset = false;
    cfg.fixation_duration_s = 0.10;
    cfg.stimulus_duration_s = 0.40;
    cfg.intertrial_duration_s = 0;
    cfg.auto_advance = false;
    cfg.simulated = true;
    cfg.test_label = 'SIMULATED/SMOKE-TEST DATA — NOT PARTICIPANT DATA';
    cfg.fullscreen = false;
elseif opts.DataSelfTest
    cfg.rotation_values_deg = 0;
    cfg.center_minus_inner_direction_deg = [0 45];
    cfg.condition_inner_direction_deg = [0 -45];
    cfg.repetitions = 1;
    cfg.use_trial_subset = false;
    cfg.simulated = true;
    cfg.test_label = 'SIMULATED/SMOKE-TEST DATA — NOT PARTICIPANT DATA';
    cfg.fullscreen = false;
end
end

function validate_design_config(cfg)
if isempty(cfg.coherence_values_percent) || ...
        any(~isfinite(cfg.coherence_values_percent)) || ...
        any(cfg.coherence_values_percent < 0 | cfg.coherence_values_percent > 100) || ...
        numel(unique(cfg.coherence_values_percent)) ~= numel(cfg.coherence_values_percent)
    error('coherence_values_percent must contain unique finite values in [0, 100].');
end
if isempty(cfg.rotation_values_deg) || any(~isfinite(cfg.rotation_values_deg)) || ...
        any(cfg.rotation_values_deg < 0 | cfg.rotation_values_deg >= 360) || ...
        numel(unique(cfg.rotation_values_deg)) ~= numel(cfg.rotation_values_deg)
    error('rotation_values_deg must contain unique finite values in [0, 360).');
end
if isempty(cfg.center_minus_inner_direction_deg) || ...
        any(~isfinite(cfg.center_minus_inner_direction_deg)) || ...
        any(cfg.center_minus_inner_direction_deg < 0 | ...
            cfg.center_minus_inner_direction_deg >= 90) || ...
        numel(unique(cfg.center_minus_inner_direction_deg)) ~= ...
            numel(cfg.center_minus_inner_direction_deg)
    error(['center_minus_inner_direction_deg must contain unique finite ' ...
        'values in [0, 90).']);
end
if ~isscalar(cfg.repetitions) || ~isfinite(cfg.repetitions) || ...
        cfg.repetitions < 1 || cfg.repetitions ~= round(cfg.repetitions)
    error('rotation_block_repetitions must be a positive integer.');
end
if ~isscalar(cfg.use_trial_subset)
    error('use_trial_subset must be true or false.');
end
if ~isscalar(cfg.subset_trial_count) || ~isfinite(cfg.subset_trial_count) || ...
        cfg.subset_trial_count < 1 || cfg.subset_trial_count ~= round(cfg.subset_trial_count)
    error('subset_trial_count must be a positive integer.');
end
if cfg.use_trial_subset
    n_directions = numel(cfg.condition_inner_direction_deg);
    n_coherences = numel(cfg.coherence_values_percent);
    trials_per_rotation_block = n_directions * n_coherences;
    full_count = trials_per_rotation_block * numel(cfg.rotation_values_deg) * cfg.repetitions;
    if mod(cfg.subset_trial_count, trials_per_rotation_block) ~= 0
        error('two_group_motion_demo:InvalidSubsetTrialCount', ...
            ['subset_trial_count must be a multiple of direction x coherence cells ' ...
            '(%d = %d directions x %d coherences). For example, use %d, %d, or %d rather than %d.'], ...
            trials_per_rotation_block, n_directions, n_coherences, ...
            trials_per_rotation_block, 2 * trials_per_rotation_block, ...
            3 * trials_per_rotation_block, cfg.subset_trial_count);
    end
    if cfg.subset_trial_count > full_count
        error('two_group_motion_demo:SubsetExceedsFullDesign', ...
            'subset_trial_count (%d) exceeds the full design (%d trials).', ...
            cfg.subset_trial_count, full_count);
    end
end
end

function self_test = run_data_self_test(script_dir, cfg, opts)
if isempty(opts.OutputDir)
    output_dir = fullfile(script_dir, 'sample_output', 'simulated_or_smoke_test_only');
else
    output_dir = resolve_output_directory(script_dir, cfg.output_directory, opts.OutputDir);
end
if ~exist(output_dir, 'dir'), mkdir(output_dir); end
session_id = choose_session_id(opts, cfg);
csv_path = fullfile(output_dir, sprintf('%s_trials.csv', session_id));
status_path = fullfile(output_dir, sprintf('%s_session_status.json', session_id));
assert_output_paths_available(csv_path, status_path);
software = software_identity(script_dir, cfg);
screen_info = struct('requested_frame_interval_s', 1/60, 'measured_refresh_hz', 60, ...
    'full_width_px', 1512, 'full_height_px', 982, 'window_width_px', 800, ...
    'window_height_px', 600, 'physical_width_mm', NaN, 'physical_height_mm', NaN, ...
    'pixels_per_degree', cfg.fallback_pixels_per_degree, 'used_fallback_ppd', true, ...
    'screen_number', 1, 'screen_selection_reason', 'simulated-external');
stimulus = struct('mean_frame_interval_s', 1/60, 'max_frame_interval_s', 1/60, ...
    'dropped_frames', 0);
colors = stimulus_colors(cfg, false);
stimulus.surround_colors_swapped = colors.surround_colors_swapped;
stimulus.center_color_rgb = colors.center;
stimulus.inner_color_rgb = colors.inner;
stimulus.outer_color_rgb = colors.outer;

state_1 = vector_for_direction(cfg, cfg.condition_inner_direction_deg(1), 37.25);
trial_1 = struct('response_deg', state_1.expected_integration_absolute_deg, ...
    'response_time_s', 0.25, ...
    'aborted', false, 'abort_stage', '', 'response_hold_event_count', 0, ...
    'response_max_hold_duration_s', 0, 'response_peak_hold_speed_deg_s', 0, ...
    'response_total_hold_rotation_deg', 0);
stimulus.coherence_percent = cfg.coherence_values_percent(1);
stimulus.center_signal_dot_count = round(cfg.center_dot_count * stimulus.coherence_percent / 100);
stimulus.inner_signal_dot_count = round(cfg.inner_dot_count * stimulus.coherence_percent / 100);
stimulus.outer_signal_dot_count = round(cfg.outer_dot_count * stimulus.coherence_percent / 100);
row_1 = make_output_row(cfg, software, screen_info, session_id, 1, 1, ...
    cfg.condition_inner_direction_deg(1), stimulus.coherence_percent, ...
    state_1, trial_1, stimulus);
write_rows(csv_path, row_1);

state_2 = vector_for_direction(cfg, cfg.condition_inner_direction_deg(2), 211.5);
trial_2 = struct('response_deg', NaN, 'response_time_s', 0.10, ...
    'aborted', true, 'abort_stage', 'response', 'response_hold_event_count', 0, ...
    'response_max_hold_duration_s', 0, 'response_peak_hold_speed_deg_s', 0, ...
    'response_total_hold_rotation_deg', 0);
row_2 = make_output_row(cfg, software, screen_info, session_id, 2, 2, ...
    cfg.condition_inner_direction_deg(2), stimulus.coherence_percent, ...
    state_2, trial_2, stimulus);
rows = [row_1 row_2];
write_rows(csv_path, rows);
write_status(status_path, cfg, software, session_id, csv_path, rows, true, ...
    'aborted_at_response');

round_trip = readtable(csv_path, 'Delimiter', ',', 'TextType', 'string', ...
    'VariableNamingRule', 'preserve');
status = jsondecode(fileread(status_path));
fixed_y = cfg.center_speed_deg_s * tand(cfg.fixed_outer_inner_delta_deg);
passed = height(round_trip) == 2 && all(round_trip.coherence_percent == cfg.coherence_values_percent(1)) && ...
    all(round_trip.fixed_center_velocity_x_deg_s == cfg.center_speed_deg_s) && ...
    all(abs(round_trip.fixed_outer_minus_inner_y_deg_s - fixed_y) < 1e-12) && ...
    abs(round_trip.common_global_rotation_deg(1) - 37.25) < 1e-12 && ...
    abs(round_trip.participant_response_center_normalized_deg(1) + 90) < 1e-12 && ...
    abs(circular_difference(round_trip.participant_response_absolute_deg(1), ...
        state_1.expected_integration_absolute_deg)) < 1e-12 && ...
    ~round_trip.aborted(1) && round_trip.aborted(2) && ...
    round_trip.valid(1) && ~round_trip.valid(2) && status.aborted && ...
    status.completed_trials == 1 && status.recorded_rows == 2;
self_test = struct('passed', logical(passed), 'csv_path', csv_path, ...
    'status_path', status_path, 'recorded_rows', height(round_trip), ...
    'completed_trials', status.completed_trials, 'aborted_row_preserved', ...
    logical(round_trip.aborted(2)), 'label', cfg.test_label);
if ~passed, error('MATLAB data round-trip self-test failed.'); end
end

function [condition_schedule, coherence_schedule, rotation_schedule, ...
        block_schedule, meta] = rotation_block_schedule( ...
        n_conditions, n_coherences, n_rotations, repetitions, ...
        use_subset, subset_trial_count)

rotation_blocks = zeros(1, n_rotations * repetitions);
previous_rotation = NaN;
for repeat_index = 1:repetitions
    rotation_order = nonrepeating_permutation(n_rotations, previous_rotation);
    indices = (repeat_index - 1) * n_rotations + (1:n_rotations);
    rotation_blocks(indices) = rotation_order;
    previous_rotation = rotation_order(end);
end

trials_per_block = n_conditions * n_coherences;
full_design_trial_count = trials_per_block * numel(rotation_blocks);
if use_subset
    scheduled_trial_count = subset_trial_count;
else
    scheduled_trial_count = full_design_trial_count;
end
scheduled_block_count = scheduled_trial_count / trials_per_block;
rotation_blocks = rotation_blocks(1:scheduled_block_count);

condition_schedule = zeros(1, scheduled_trial_count);
coherence_schedule = zeros(1, scheduled_trial_count);
rotation_schedule = zeros(1, scheduled_trial_count);
block_schedule = zeros(1, scheduled_trial_count);

% Each rotation block contains every direction x coherence combination once.
[cell_condition, cell_coherence] = ndgrid(1:n_conditions, 1:n_coherences);
cell_condition = cell_condition(:)';
cell_coherence = cell_coherence(:)';
n_cells = numel(cell_condition);
previous_cell = NaN;

for block_index = 1:scheduled_block_count
    cell_order = nonrepeating_permutation(n_cells, previous_cell);
    indices = (block_index - 1) * n_cells + (1:n_cells);
    condition_schedule(indices) = cell_condition(cell_order);
    coherence_schedule(indices) = cell_coherence(cell_order);
    rotation_schedule(indices) = rotation_blocks(block_index);
    block_schedule(indices) = block_index;
    previous_cell = cell_order(end);
end

meta = struct('full_design_trial_count', full_design_trial_count, ...
    'scheduled_trial_count', scheduled_trial_count, ...
    'full_rotation_block_count', n_rotations * repetitions, ...
    'scheduled_block_count', scheduled_block_count, ...
    'trials_per_block', trials_per_block, ...
    'direction_count', n_conditions, ...
    'coherence_count', n_coherences, ...
    'use_trial_subset', logical(use_subset), ...
    'rotation_block_order_indices', rotation_blocks);
end

function order = nonrepeating_permutation(n_values, previous_value)
order = randperm(n_values);
if n_values <= 1 || ~isfinite(previous_value) || order(1) ~= previous_value
    return;
end
swap_index = find(order ~= previous_value, 1, 'first');
order([1 swap_index]) = order([swap_index 1]);
end

function n = maximum_run_length(values)
if isempty(values), n = 0; return; end
n = 1;
current = 1;
for i = 2:numel(values)
    if values(i) == values(i - 1), current = current + 1; else, current = 1; end
    n = max(n, current);
end
end

function vectors = velocity_table(cfg)
directions = cfg.condition_inner_direction_deg(:);
n = numel(directions);
center = zeros(n, 2);
inner = zeros(n, 2);
outer = zeros(n, 2);
for i = 1:n
    state = vector_for_direction(cfg, directions(i));
    center(i, :) = state.center;
    inner(i, :) = state.inner;
    outer(i, :) = state.outer;
end
vectors = struct('condition_inner_direction_deg', directions, ...
    'center', center, 'inner', inner, 'outer', outer, ...
    'outer_minus_inner', outer - inner, 'center_minus_inner', center - inner, ...
    'screen_center', [center(:, 1), -center(:, 2)], ...
    'screen_inner', [inner(:, 1), -inner(:, 2)], ...
    'screen_outer', [outer(:, 1), -outer(:, 2)]);
end

function state = vector_for_direction(cfg, inner_direction_deg, common_rotation_deg)
if nargin < 3, common_rotation_deg = 0; end
s = cfg.center_speed_deg_s;
delta = abs(inner_direction_deg);
outer_theta = atand(tand(cfg.fixed_outer_inner_delta_deg) - tand(delta));
center_aligned_center = [s, 0];
center_aligned_inner = [s, -s * tand(delta)];
center_aligned_outer = [s, s * (tand(cfg.fixed_outer_inner_delta_deg) - tand(delta))];
common_rotation_deg = mod(common_rotation_deg, 360);
state.center = rotate_velocity(center_aligned_center, common_rotation_deg);
state.inner = rotate_velocity(center_aligned_inner, common_rotation_deg);
state.outer = rotate_velocity(center_aligned_outer, common_rotation_deg);
state.center_aligned_center = center_aligned_center;
state.center_aligned_inner = center_aligned_inner;
state.center_aligned_outer = center_aligned_outer;
state.common_global_rotation_deg = common_rotation_deg;
state.center_direction_absolute_deg = wrap_to_180(common_rotation_deg);
state.inner_direction_absolute_deg = atan2d(state.inner(2), state.inner(1));
state.outer_direction_absolute_deg = atan2d(state.outer(2), state.outer(1));
state.inner_direction_deg = inner_direction_deg;
state.inner_speed_deg_s = s / cosd(delta);
state.outer_direction_deg = outer_theta;
state.outer_speed_deg_s = s / cosd(outer_theta);
state.fixed_outer_minus_inner = center_aligned_outer - center_aligned_inner;
state.displayed_outer_minus_inner = state.outer - state.inner;
state.expected_retinal_deg = 0;
state.expected_integration_deg = -90;
state.expected_retinal_absolute_deg = state.center_direction_absolute_deg;
state.expected_integration_absolute_deg = wrap_to_180(common_rotation_deg - 90);
if delta == 0
    state.expected_segmentation_deg = NaN;
    state.expected_segmentation_absolute_deg = NaN;
else
    state.expected_segmentation_deg = 90;
    state.expected_segmentation_absolute_deg = wrap_to_180(common_rotation_deg + 90);
end
end

function rotated = rotate_velocity(vector, rotation_deg)
c = cosd(rotation_deg);
s = sind(rotation_deg);
rotated = [vector(1) * c - vector(2) * s, ...
    vector(1) * s + vector(2) * c];
end

function validation = validate_common_rotations(cfg, schedule, rotations)
max_recovery_error = 0;
max_relative_recovery_error = 0;
for idx = 1:numel(schedule)
    direction = cfg.condition_inner_direction_deg(schedule(idx));
    base = vector_for_direction(cfg, direction, 0);
    rotated = vector_for_direction(cfg, direction, rotations(idx));
    recovered = [rotate_velocity(rotated.center, -rotations(idx)); ...
        rotate_velocity(rotated.inner, -rotations(idx)); ...
        rotate_velocity(rotated.outer, -rotations(idx))];
    expected = [base.center; base.inner; base.outer];
    max_recovery_error = max(max_recovery_error, max(abs(recovered - expected), [], 'all'));
    recovered_relative = rotate_velocity(rotated.displayed_outer_minus_inner, ...
        -rotations(idx));
    max_relative_recovery_error = max(max_relative_recovery_error, ...
        max(abs(recovered_relative - base.fixed_outer_minus_inner)));
end
in_range = all(rotations >= 0 & rotations < 360);
validation = struct('passed', in_range && max_recovery_error < 1e-12 && ...
    max_relative_recovery_error < 1e-12, ...
    'minimum_rotation_deg', min(rotations), ...
    'maximum_rotation_deg', max(rotations), ...
    'max_center_aligned_recovery_error', max_recovery_error, ...
    'max_relative_recovery_error', max_relative_recovery_error);
end

function validation = validate_scientific_state(cfg, schedule, ...
        rotation_schedule, block_schedule, vectors)
errors = {};
if isempty(cfg.coherence_values_percent) || ...
        any(~isfinite(cfg.coherence_values_percent)) || ...
        any(cfg.coherence_values_percent < 0 | ...
            cfg.coherence_values_percent > 100)
    errors{end + 1} = ...
        'coherence values must be between 0 and 100';
end
if ~isequal(cfg.center_color_rgb, [0 255 0]) || ...
        ~isequal(cfg.inner_color_rgb, [255 0 0]) || ...
        ~isequal(cfg.outer_color_rgb, [0 153 255])
    errors{end + 1} = 'region colors must match Experiment 2 source RGB values';
end
if numel(unique(schedule)) ~= numel(cfg.condition_inner_direction_deg)
    errors{end + 1} = 'schedule omits a condition';
end
if numel(schedule) ~= cfg.scheduled_trial_count
    errors{end + 1} = 'schedule length does not match scheduled_trial_count';
end
n_conditions = numel(cfg.condition_inner_direction_deg);
n_rotations = numel(cfg.rotation_values_deg);
n_blocks = max(block_schedule);
for block_index = 1:n_blocks
    rows = block_schedule == block_index;
    if sum(rows) ~= n_conditions || numel(unique(schedule(rows))) ~= n_conditions
        errors{end + 1} = sprintf( ...
            'rotation block %d does not contain every direction exactly once', ...
            block_index); %#ok<AGROW>
    end
    if numel(unique(rotation_schedule(rows))) ~= 1
        errors{end + 1} = sprintf( ...
            'rotation block %d contains multiple rotations', block_index); %#ok<AGROW>
    end
end
for i = 1:n_conditions
    if sum(schedule == i) ~= n_blocks
        errors{end + 1} = sprintf('condition %d is unbalanced', i); %#ok<AGROW>
    end
    for j = 1:n_rotations
        blocks_for_rotation = sum(arrayfun(@(b) any( ...
            block_schedule == b & rotation_schedule == j), 1:n_blocks));
        if sum(schedule == i & rotation_schedule == j) ~= blocks_for_rotation
            errors{end + 1} = sprintf( ...
                'condition %d, rotation %d cell is unbalanced', i, j); %#ok<AGROW>
        end
    end
end
block_rotations = zeros(1, n_blocks);
for block_index = 1:n_blocks
    block_rotations(block_index) = rotation_schedule(find( ...
        block_schedule == block_index, 1, 'first'));
end
for first_block = 1:n_rotations:n_blocks
    last_block = min(n_blocks, first_block + n_rotations - 1);
    if numel(unique(block_rotations(first_block:last_block))) ~= ...
            last_block - first_block + 1
        errors{end + 1} = ...
            'a rotation repeats before every configured rotation is sampled'; %#ok<AGROW>
    end
end
if n_conditions > 1 && maximum_run_length(schedule) > 1
    errors{end + 1} = 'identical direction trials are adjacent';
end
if n_rotations > 1 && maximum_run_length(block_rotations) > 1
    errors{end + 1} = 'identical rotation blocks are adjacent';
end
if ~cfg.use_trial_subset
    for i = 1:n_conditions
        for j = 1:n_rotations
            if sum(schedule == i & rotation_schedule == j) ~= cfg.repetitions
                errors{end + 1} = sprintf( ...
                    'full-design condition %d, rotation %d cell is unbalanced', ...
                    i, j); %#ok<AGROW>
            end
        end
    end
end
if any(abs(vectors.center - repmat([cfg.center_speed_deg_s 0], size(vectors.center, 1), 1)) > 1e-12, 'all')
    errors{end + 1} = 'center velocity is not fixed';
end
expected_super = [0, cfg.center_speed_deg_s * tand(cfg.fixed_outer_inner_delta_deg)];
if any(abs(vectors.outer_minus_inner - repmat(expected_super, size(vectors.outer, 1), 1)) > 1e-12, 'all')
    errors{end + 1} = 'outer-minus-inner supergroup component is not fixed';
end
if any(abs(vectors.inner(:, 1) - cfg.center_speed_deg_s) > 1e-12) || ...
        any(abs(vectors.outer(:, 1) - cfg.center_speed_deg_s) > 1e-12)
    errors{end + 1} = 'common horizontal component changed';
end
validation = struct('passed', isempty(errors), 'errors', {errors}, ...
    'maximum_run_length', maximum_run_length(schedule), ...
    'trial_count', numel(schedule), ...
    'full_design_trial_count', cfg.full_design_trial_count, ...
    'condition_count', n_conditions, ...
    'configured_rotation_count', n_rotations, ...
    'observed_rotation_count', numel(unique(rotation_schedule)), ...
    'rotation_block_count', n_blocks, ...
    'trials_per_rotation_block', n_conditions, ...
    'rotation_block_repetitions', cfg.repetitions, ...
    'trials_per_condition', n_blocks, ...
    'use_trial_subset', cfg.use_trial_subset, ...
    'block_rotation_order_indices', block_rotations, ...
    'expected_fixed_outer_minus_inner', expected_super);
end

function info = measure_screen(screen_number, window_rect, cfg, ifi, ...
        available_screens, display_rect, selection_reason)
resolution = Screen('Resolution', screen_number);
[width_mm, height_mm] = Screen('DisplaySize', screen_number);
valid_physical = isfinite(width_mm) && width_mm >= 100 && isfinite(height_mm) && height_mm >= 50;
if valid_physical
    visual_width_deg = 2 * atand((width_mm / 20) / cfg.viewing_distance_cm);
    ppd = resolution.width / visual_width_deg;
else
    visual_width_deg = NaN;
    ppd = cfg.fallback_pixels_per_degree;
end
info = struct('screen_number', screen_number, 'full_width_px', resolution.width, ...
    'full_height_px', resolution.height, 'window_width_px', RectWidth(window_rect), ...
    'window_height_px', RectHeight(window_rect), 'physical_width_mm', width_mm, ...
    'physical_height_mm', height_mm, 'visual_width_deg', visual_width_deg, ...
    'pixels_per_degree', ppd, 'used_fallback_ppd', ~valid_physical, ...
    'requested_frame_interval_s', ifi, 'measured_refresh_hz', 1 / ifi, ...
    'available_screen_numbers', available_screens, ...
    'display_global_rect_px', display_rect, ...
    'screen_selection_reason', selection_reason);
end

function [screen_number, reason] = choose_screen_number(screens, requested, prefer_external)
screens = reshape(double(screens), 1, []);
if isempty(screens), error('two_group_motion_demo:NoScreens', 'Psychtoolbox found no screens.'); end
if ~isempty(requested)
    if ~isscalar(requested) || ~isnumeric(requested) || ~isfinite(requested) || ...
            requested ~= round(requested) || ~ismember(requested, screens)
        error('two_group_motion_demo:InvalidScreenNumber', ...
            'ScreenNumber must be one of: %s', mat2str(screens));
    end
    screen_number = double(requested);
    reason = 'explicit-ScreenNumber';
    return;
end
external = screens(screens ~= 0);
if prefer_external && ~isempty(external)
    screen_number = max(external);
    reason = 'preferred-external-screen';
else
    screen_number = screens(1);
    reason = 'primary-or-only-screen';
end
end

function rect = screen_global_rect(screen_number)
try
    rect = Screen('GlobalRect', screen_number);
catch
    rect = Screen('Rect', screen_number);
end
if isempty(rect) || numel(rect) ~= 4 || RectWidth(rect) <= 0 || RectHeight(rect) <= 0
    error('two_group_motion_demo:InvalidScreenRect', ...
        'Psychtoolbox returned an invalid rectangle for screen %d.', screen_number);
end
end

function keys = key_map()
keys.escape = key_code({'ESCAPE'});
keys.left = key_code({'LeftArrow'});
keys.right = key_code({'RightArrow'});
keys.space = key_code({'space'});
keys.enter = key_code({'Return', 'ENTER'});
keys.pause = key_code({'p', 'P'});
keys.shift = unique([key_code({'LeftShift'}), key_code({'RightShift'})]);
keys.shift = keys.shift(keys.shift > 0);
end

function code = key_code(names)
code = 0;
for i = 1:numel(names)
    try
        value = KbName(names{i});
        if isnumeric(value) && ~isempty(value)
            value = value(1);
            if value > 0, code = value; return; end
        end
    catch
    end
end
end

function action = wait_for_start_or_abort(keys)
action = struct('abort', false);
KbReleaseWait(-1);
while true
    [down, ~, code] = KbCheck(-1);
    if down
        if key_down(code, keys.escape)
            action.abort = true;
        elseif ~(key_down(code, keys.space) || key_down(code, keys.enter))
            KbReleaseWait(-1);
            continue;
        end
        KbReleaseWait(-1);
        return;
    end
    WaitSecs(0.01);
end
end

function [trial_result, stimulus_state] = run_trial(window, rect, screen_info, cfg, ...
        keys, inner_direction, coherence_percent, common_rotation_deg, ...
        vector_state, colors, ioObj, port)
ppd = screen_info.pixels_per_degree;
[cx, cy] = RectCenter(rect);
stimulus_center = [cx + cfg.stimulus_eccentricity_deg * ppd, cy];

positions.center = sample_disk(cfg.center_dot_count, cfg.center_radius_deg);
positions.inner = sample_annulus(cfg.inner_dot_count, cfg.inner_radius_min_deg, cfg.inner_radius_max_deg);
positions.outer = sample_annulus(cfg.outer_dot_count, cfg.outer_radius_min_deg, cfg.outer_radius_max_deg);
initial_positions = positions;

fix_diameter = max(2, 2 * cfg.fixation_radius_deg * ppd);
fix_rect = CenterRectOnPointd([0 0 fix_diameter fix_diameter], cx, cy);
Screen('FillRect', window, [0 0 0]);
Screen('FillOval', window, [255 255 255], fix_rect);
Screen('Flip', window);

condition_trigger_sent = false;

% EEG trigger: fixation appeared
send_eeg_trigger(ioObj, port, 1);

WaitSecs(cfg.fixation_duration_s);

frame_intervals = [];
dropped_frames = 0;
aborted = false;
abort_stage = '';
vbl = Screen('Flip', window);
previous_vbl = NaN;
stimulus_start = GetSecs;
deadline = stimulus_start + cfg.stimulus_duration_s;
last_update = stimulus_start;

while GetSecs < deadline
    now = GetSecs;
    dt = max(0, now - last_update);
    last_update = now;
    positions.center = update_coherent_dots(positions.center, vector_state.center, ...
        coherence_percent, dt, 'disk', cfg.center_radius_deg, 0);
    positions.inner = update_coherent_dots(positions.inner, vector_state.inner, ...
        coherence_percent, dt, 'annulus', cfg.inner_radius_min_deg, cfg.inner_radius_max_deg);
    positions.outer = update_coherent_dots(positions.outer, vector_state.outer, ...
        coherence_percent, dt, 'annulus', cfg.outer_radius_min_deg, cfg.outer_radius_max_deg);

    Screen('FillRect', window, [0 0 0]);
    draw_dot_region(window, positions.outer, stimulus_center, ppd, ...
        cfg.dot_diameter_deg, colors.outer);
    draw_dot_region(window, positions.inner, stimulus_center, ppd, ...
        cfg.dot_diameter_deg, colors.inner);
    draw_dot_region(window, positions.center, stimulus_center, ppd, ...
        cfg.dot_diameter_deg, colors.center);
    Screen('FillOval', window, [255 255 255], fix_rect);
% EEG trigger for this trial
    eeg_trigger = two_group_motion_trigger_map( ...
        common_rotation_deg, ...
        inner_direction, ...
        coherence_percent);
%stimulus trigger once
if ~condition_trigger_sent
    send_eeg_trigger(ioObj, port, eeg_trigger.trigger);
    condition_trigger_sent = true;
end

%stimulus onset
    new_vbl = Screen('Flip', window, vbl + 0.5 * screen_info.requested_frame_interval_s);

    if isfinite(previous_vbl)
        interval = new_vbl - previous_vbl;
        frame_intervals(end + 1) = interval; %#ok<AGROW>
        dropped_frames = dropped_frames + double(interval > 1.5 * screen_info.requested_frame_interval_s);
    end
    previous_vbl = new_vbl;
    vbl = new_vbl;

    [down, ~, code] = KbCheck(-1);
    if down && key_down(code, keys.escape)
        aborted = true;
        abort_stage = 'stimulus';
        KbReleaseWait(-1);
        break;
    elseif down && key_down(code, keys.pause)
        pause_started = GetSecs;
        pause_abort = show_pause(window, keys);
        if pause_abort
            aborted = true;
            abort_stage = 'stimulus';
            break;
        end
        deadline = deadline + (GetSecs - pause_started);
        last_update = GetSecs;
        previous_vbl = NaN;
        
    end
end

stimulus_state = struct('initial_positions', initial_positions, 'final_positions', positions, ...
    'frame_intervals_s', frame_intervals, 'dropped_frames', dropped_frames, ...
    'mean_frame_interval_s', safe_mean(frame_intervals), 'max_frame_interval_s', safe_max(frame_intervals), ...
    'surround_colors_swapped', colors.surround_colors_swapped, ...
    'center_color_rgb', colors.center, 'inner_color_rgb', colors.inner, ...
    'outer_color_rgb', colors.outer, ...
    'coherence_percent', coherence_percent, ...
    'center_signal_dot_count', round(cfg.center_dot_count * coherence_percent / 100), ...
    'inner_signal_dot_count', round(cfg.inner_dot_count * coherence_percent / 100), ...
    'outer_signal_dot_count', round(cfg.outer_dot_count * coherence_percent / 100));

if aborted
    trial_result = struct('response_deg', NaN, 'response_time_s', NaN, 'aborted', true, ...
        'abort_stage', abort_stage, 'response_hold_event_count', 0, ...
        'response_max_hold_duration_s', 0, 'response_peak_hold_speed_deg_s', 0, ...
        'response_total_hold_rotation_deg', 0);
    return;
end

if cfg.auto_advance
    Screen('FillRect', window, [0 0 0]);
    draw_response_arrow(window, stimulus_center, response_circle_radius_px(cfg, ppd), ...
        vector_state.expected_integration_absolute_deg, colors.center);
    Screen('Flip', window);
    WaitSecs(0.05);
    trial_result = struct('response_deg', ...
        vector_state.expected_integration_absolute_deg, ...
        'response_time_s', 0.05, 'aborted', false, 'abort_stage', '', ...
        'response_hold_event_count', 0, 'response_max_hold_duration_s', 0, ...
        'response_peak_hold_speed_deg_s', 0, 'response_total_hold_rotation_deg', 0);
else
   trial_result = collect_keyboard_response(window, stimulus_center, ...
        response_circle_radius_px(cfg, ppd), cfg, keys, ioObj, port);
end

if any(frame_intervals > 1.5 * screen_info.requested_frame_interval_s)
    warning('Trial at inner direction %.1f deg had %d delayed frame intervals.', inner_direction, dropped_frames);
end
end

function result = collect_keyboard_response(window, stimulus_center, radius_px, cfg, keys, ioObj, port)
response = wrap_to_180(360 * rand - 180);
started = GetSecs;
response_circle_trigger_sent = false;

held_direction = '';
held_started = NaN;
last_adjustment = started;
hold_active = false;
hold_event_count = 0;
max_hold_duration = 0;
peak_hold_speed = 0;
total_hold_rotation = 0;
KbReleaseWait(-1);
while true
    Screen('FillRect', window, [0 0 0]);
    draw_response_arrow(window, stimulus_center, radius_px, response, cfg.center_color_rgb);
    Screen('Flip', window);

%EEG trigger: response circle/arrow appeared
    if ~response_circle_trigger_sent
    send_eeg_trigger(ioObj, port, 2);
    response_circle_trigger_sent = true;
    end

    [down, ~, code] = KbCheck(-1);
    now = GetSecs;
    if down
        if key_down(code, keys.escape)
            KbReleaseWait(-1);
            result = struct('response_deg', NaN, 'response_time_s', GetSecs - started, ...
                'aborted', true, 'abort_stage', 'response', ...
                'response_hold_event_count', hold_event_count, ...
                'response_max_hold_duration_s', max_hold_duration, ...
                'response_peak_hold_speed_deg_s', peak_hold_speed, ...
                'response_total_hold_rotation_deg', total_hold_rotation);
            return;
        elseif key_down(code, keys.pause)
            pause_started = GetSecs;
            if show_pause(window, keys)
                result = struct('response_deg', NaN, 'response_time_s', GetSecs - started, ...
                    'aborted', true, 'abort_stage', 'response', ...
                    'response_hold_event_count', hold_event_count, ...
                    'response_max_hold_duration_s', max_hold_duration, ...
                    'response_peak_hold_speed_deg_s', peak_hold_speed, ...
                    'response_total_hold_rotation_deg', total_hold_rotation);
                return;
            end
            started = started + (GetSecs - pause_started);
            held_direction = '';
            held_started = NaN;
            last_adjustment = GetSecs;
            hold_active = false;
        elseif key_down(code, keys.enter) || key_down(code, keys.space)
            
   %EEG trigger: space bar response 
            if key_down(code, keys.space)
                send_eeg_trigger(ioObj, port,5);
            end

            response_time = GetSecs - started;
            play_confirmation_tone(cfg);
            KbReleaseWait(-1);
            result = struct('response_deg', response, 'response_time_s', response_time, ...
                'aborted', false, 'abort_stage', '', ...
                'response_hold_event_count', hold_event_count, ...
                'response_max_hold_duration_s', max_hold_duration, ...
                'response_peak_hold_speed_deg_s', peak_hold_speed, ...
                'response_total_hold_rotation_deg', total_hold_rotation);
            return;
        elseif xor(key_down(code, keys.left), key_down(code, keys.right))
            large = key_down(code, keys.shift);
            if key_down(code, keys.left)
                direction = 'left';
            else
                direction = 'right';
            end
            if ~strcmp(held_direction, direction)

                %EEG trigger: initial arrow Press
                    if strcmp(direction, 'left')
                        send_eeg_trigger(ioObj, port, 3);
                    else
                        send_eeg_trigger(ioObj, port, 4);
                    end

                response = adjust_response_angle(response, direction, large, cfg);
                held_direction = direction;
                held_started = now;
                last_adjustment = now;
                hold_active = false;
            else
                held_duration = now - held_started;
                speed = response_hold_speed(held_duration, large, cfg);
                if speed > 0
                    if ~hold_active
                        hold_event_count = hold_event_count + 1;
                        hold_active = true;
                    end
                    elapsed = max(0, now - last_adjustment);
                    signed_delta = speed * elapsed;
                    if strcmp(direction, 'right'), signed_delta = -signed_delta; end
                    response = wrap_to_180(response + signed_delta);
                    max_hold_duration = max(max_hold_duration, held_duration);
                    peak_hold_speed = max(peak_hold_speed, speed);
                    total_hold_rotation = total_hold_rotation + abs(signed_delta);
                end
                last_adjustment = now;
            end
        else
            held_direction = '';
            held_started = NaN;
            last_adjustment = now;
            hold_active = false;
        end
    else
        held_direction = '';
        held_started = NaN;
        last_adjustment = now;
        hold_active = false;
    end
    WaitSecs(0.01);
end
end

function speed = response_hold_speed(held_duration, large, cfg)
if held_duration < cfg.response_hold_delay_s
    speed = 0;
    return;
end
active_duration = held_duration - cfg.response_hold_delay_s;
speed = cfg.response_hold_initial_speed_deg_s + ...
    cfg.response_hold_acceleration_deg_s2 * active_duration;
speed = min(speed, cfg.response_hold_max_speed_deg_s);
if large
    speed = speed * cfg.response_shift_hold_multiplier;
end
end

function pixels = response_circle_radius_px(cfg, ppd)
pixels = cfg.center_radius_deg * ppd;
end

function colors = stimulus_colors(cfg, surround_colors_swapped)
colors = struct('center', cfg.center_color_rgb, ...
    'inner', cfg.inner_color_rgb, 'outer', cfg.outer_color_rgb, ...
    'surround_colors_swapped', logical(surround_colors_swapped));
if colors.surround_colors_swapped
    temporary = colors.inner;
    colors.inner = colors.outer;
    colors.outer = temporary;
end
end

function play_confirmation_tone(cfg)
if ~cfg.confirmation_tone_enabled, return; end
[waveform, sample_rate] = confirmation_tone_waveform(cfg);
try
    sound(waveform, sample_rate);
catch ME
    warning('two_group_motion_demo:ConfirmationToneFailed', ...
        'Could not play the confirmation tone: %s', ME.message);
end
end

function [waveform, sample_rate] = confirmation_tone_waveform(cfg)
sample_rate = double(cfg.confirmation_tone_sample_rate_hz);
sample_count = max(2, round(cfg.confirmation_tone_duration_s * sample_rate));
time_s = (0:(sample_count - 1)) / sample_rate;
envelope = sin(pi * (0:(sample_count - 1)) / (sample_count - 1)).^2;
waveform = cfg.confirmation_tone_volume * envelope .* ...
    sin(2 * pi * cfg.confirmation_tone_frequency_hz * time_s);
end

function validation = validate_confirmation_tone(cfg)
[waveform, sample_rate] = confirmation_tone_waveform(cfg);
validation = struct('enabled', logical(cfg.confirmation_tone_enabled), ...
    'frequency_hz', cfg.confirmation_tone_frequency_hz, ...
    'duration_s', cfg.confirmation_tone_duration_s, ...
    'sample_rate_hz', sample_rate, 'sample_count', numel(waveform), ...
    'peak_absolute_amplitude', max(abs(waveform)));
validation.passed = validation.enabled && sample_rate >= 8000 && ...
    validation.frequency_hz > 0 && validation.duration_s > 0 && ...
    validation.sample_count == max(2, round(validation.duration_s * sample_rate)) && ...
    validation.peak_absolute_amplitude > 0 && ...
    validation.peak_absolute_amplitude <= cfg.confirmation_tone_volume + eps;
end

function validation = validate_color_mapping(cfg)
base = stimulus_colors(cfg, false);
swapped = stimulus_colors(cfg, true);
validation = struct('center_rgb', base.center, 'inner_rgb', base.inner, ...
    'outer_rgb', base.outer, 'swapped_inner_rgb', swapped.inner, ...
    'swapped_outer_rgb', swapped.outer);
validation.passed = isequal(base.center, [0 255 0]) && ...
    isequal(base.inner, [255 0 0]) && isequal(base.outer, [0 153 255]) && ...
    isequal(swapped.center, base.center) && ...
    isequal(swapped.inner, base.outer) && isequal(swapped.outer, base.inner);
end

function response = adjust_response_angle(response, direction, large, cfg)
step = cfg.response_step_deg;
if large, step = cfg.response_large_step_deg; end
if strcmp(direction, 'left')
    response = wrap_to_180(response + step);
elseif strcmp(direction, 'right')
    response = wrap_to_180(response - step);
else
    error('Response direction must be left or right.');
end
end

function validation = validate_keyboard_mapping(cfg)
validation = struct();
validation.left_from_zero_deg = adjust_response_angle(0, 'left', false, cfg);
validation.right_from_zero_deg = adjust_response_angle(0, 'right', false, cfg);
validation.shift_left_from_zero_deg = adjust_response_angle(0, 'left', true, cfg);
validation.wrap_left_from_179_deg = adjust_response_angle(179, 'left', false, cfg);
validation.hold_before_delay_deg_s = response_hold_speed( ...
    cfg.response_hold_delay_s / 2, false, cfg);
validation.hold_at_delay_deg_s = response_hold_speed( ...
    cfg.response_hold_delay_s, false, cfg);
validation.hold_after_one_second_deg_s = response_hold_speed(1, false, cfg);
validation.shift_hold_after_one_second_deg_s = response_hold_speed(1, true, cfg);
validation.hold_max_deg_s = response_hold_speed(60, false, cfg);
validation.response_circle_radius_deg = response_circle_radius_px(cfg, 1);
validation.passed = validation.left_from_zero_deg == 1 && ...
    validation.right_from_zero_deg == -1 && ...
    validation.shift_left_from_zero_deg == 5 && ...
    validation.wrap_left_from_179_deg == -180 && ...
    validation.hold_before_delay_deg_s == 0 && ...
    validation.hold_at_delay_deg_s == cfg.response_hold_initial_speed_deg_s && ...
    validation.hold_after_one_second_deg_s > validation.hold_at_delay_deg_s && ...
    validation.shift_hold_after_one_second_deg_s > validation.hold_after_one_second_deg_s && ...
    validation.hold_max_deg_s == cfg.response_hold_max_speed_deg_s && ...
    validation.response_circle_radius_deg == cfg.center_radius_deg;
end

function validation = validate_display_selection()
[external, external_reason] = choose_screen_number([0 1], [], true);
[explicit, explicit_reason] = choose_screen_number([0 1], 0, true);
[only, only_reason] = choose_screen_number(0, [], true);
validation = struct('external_default', external, ...
    'external_reason', external_reason, 'explicit_override', explicit, ...
    'explicit_reason', explicit_reason, 'only_screen', only, ...
    'only_reason', only_reason, 'passed', external == 1 && explicit == 0 && only == 0);
end

function abort_requested = show_pause(window, keys)
abort_requested = false;
draw_centered_text(window, 'PAUSED\n\nPress P to continue or Escape to save and abort.', [255 220 120]);
Screen('Flip', window);
KbReleaseWait(-1);
while true
    [down, ~, code] = KbCheck(-1);
    if down && key_down(code, keys.pause)
        KbReleaseWait(-1);
        return;
    elseif down && key_down(code, keys.escape)
        abort_requested = true;
        KbReleaseWait(-1);
        return;
    end
    WaitSecs(0.02);
end
end

function tf = key_down(code, key)
if isempty(key) || all(key == 0), tf = false; return; end
key = key(key > 0 & key <= numel(code));
tf = ~isempty(key) && any(code(key));
end

function positions = sample_disk(n, radius)
r = radius * sqrt(rand(n, 1));
t = 2 * pi * rand(n, 1);
positions = [r .* cos(t), r .* sin(t)];
end

function positions = sample_annulus(n, inner_radius, outer_radius)
r = sqrt(inner_radius ^ 2 + rand(n, 1) * (outer_radius ^ 2 - inner_radius ^ 2));
t = 2 * pi * rand(n, 1);
positions = [r .* cos(t), r .* sin(t)];
end

function positions = replenish_positions(positions, kind, radius_a, radius_b)
r = hypot(positions(:, 1), positions(:, 2));
if strcmp(kind, 'disk')
    invalid = r > radius_a;
    if any(invalid), positions(invalid, :) = sample_disk(sum(invalid), radius_a); end
else
    invalid = r < radius_a | r > radius_b;
    if any(invalid), positions(invalid, :) = sample_annulus(sum(invalid), radius_a, radius_b); end
end
end

function draw_dot_region(window, positions_deg, stimulus_center, ppd, dot_diameter_deg, color)
xy = [stimulus_center(1) + positions_deg(:, 1)' * ppd; ...
      stimulus_center(2) - positions_deg(:, 2)' * ppd];
dot_size = max(1, dot_diameter_deg * ppd);
Screen('DrawDots', window, xy, dot_size, color, [], 1);
end

function draw_response_arrow(window, center, radius_px, angle_deg, color)
circle_rect = CenterRectOnPointd([0 0 2 * radius_px 2 * radius_px], center(1), center(2));
Screen('FrameOval', window, [100 100 100], circle_rect, 2);
tip = center + 0.75 * radius_px * [cosd(angle_deg), -sind(angle_deg)];
tail = center - 0.35 * radius_px * [cosd(angle_deg), -sind(angle_deg)];
Screen('DrawLine', window, color, tail(1), tail(2), tip(1), tip(2), 5);
head_len = max(12, 0.12 * radius_px);
left = tip - head_len * [cosd(angle_deg - 25), -sind(angle_deg - 25)];
right = tip - head_len * [cosd(angle_deg + 25), -sind(angle_deg + 25)];
Screen('FillPoly', window, color, [tip; left; right]);
end

function draw_centered_text(window, text, color)
Screen('FillRect', window, [0 0 0]);
DrawFormattedText(window, text, 'center', 'center', color, 80, [], [], 1.4);
end

function row = make_output_row(cfg, software, screen_info, session_id, trial_index, ...
        condition_index, direction, coherence_percent, state, trial, stimulus)
row = struct();
row.mission_id = string(cfg.mission_id);
row.software_version = string(cfg.software_version);
row.git_commit = string(software.git_commit);
row.timestamp_utc = string(utc_now());
row.anonymous_session_id = string(session_id);
row.trial_number = trial_index;
trials_per_rotation_block = numel(cfg.condition_inner_direction_deg) * ...
    numel(cfg.coherence_values_percent);
row.rotation_block_number = ceil(trial_index / trials_per_rotation_block);
row.rotation_block_position = mod(trial_index - 1, trials_per_rotation_block) + 1;
row.scheduled_trial_count = cfg.scheduled_trial_count;
row.full_design_trial_count = cfg.full_design_trial_count;
row.scheduled_rotation_block_count = cfg.scheduled_rotation_block_count;
row.rotation_block_repetitions = cfg.repetitions;
row.use_trial_subset = cfg.use_trial_subset;
row.condition_id = string(sprintf('G%02d', abs(round(direction))));
row.condition_order_index = condition_index;
row.varied_inner_direction_deg = direction;
row.center_minus_inner_direction_deg = -direction;
row.common_global_rotation_deg = state.common_global_rotation_deg;
row.displayed_center_direction_deg = state.center_direction_absolute_deg;
row.displayed_inner_direction_deg = state.inner_direction_absolute_deg;
row.displayed_outer_direction_deg = state.outer_direction_absolute_deg;
row.fixed_center_velocity_x_deg_s = state.center_aligned_center(1);
row.fixed_center_velocity_y_deg_s = state.center_aligned_center(2);
row.displayed_center_velocity_x_deg_s = state.center(1);
row.displayed_center_velocity_y_deg_s = state.center(2);
row.inner_velocity_x_deg_s = state.inner(1);
row.inner_velocity_y_deg_s = state.inner(2);
row.outer_velocity_x_deg_s = state.outer(1);
row.outer_velocity_y_deg_s = state.outer(2);
row.fixed_outer_minus_inner_x_deg_s = state.fixed_outer_minus_inner(1);
row.fixed_outer_minus_inner_y_deg_s = state.fixed_outer_minus_inner(2);
row.displayed_outer_minus_inner_x_deg_s = state.displayed_outer_minus_inner(1);
row.displayed_outer_minus_inner_y_deg_s = state.displayed_outer_minus_inner(2);
row.coherence_percent = coherence_percent;
row.configured_coherence_values_percent = string(mat2str(cfg.coherence_values_percent));
row.center_signal_dot_count = stimulus.center_signal_dot_count;
row.inner_signal_dot_count = stimulus.inner_signal_dot_count;
row.outer_signal_dot_count = stimulus.outer_signal_dot_count;
row.surround_colors_swapped = stimulus.surround_colors_swapped;
row.center_color_rgb = string(mat2str(stimulus.center_color_rgb));
row.inner_color_rgb = string(mat2str(stimulus.inner_color_rgb));
row.outer_color_rgb = string(mat2str(stimulus.outer_color_rgb));
row.random_seed = cfg.random_seed;
row.participant_response_absolute_deg = trial.response_deg;
row.participant_response_center_normalized_deg = circular_difference( ...
    trial.response_deg, state.center_direction_absolute_deg);
row.participant_response_deg = row.participant_response_center_normalized_deg;
row.expected_response_deg = state.expected_integration_deg;
row.expected_response_definition = "integration hypothesis: center+inner group relative to outer; not an objectively correct answer";
row.expected_retinal_deg = state.expected_retinal_deg;
row.expected_segmentation_deg = state.expected_segmentation_deg;
row.expected_response_absolute_deg = state.expected_integration_absolute_deg;
row.expected_retinal_absolute_deg = state.expected_retinal_absolute_deg;
row.expected_segmentation_absolute_deg = state.expected_segmentation_absolute_deg;
row.response_error_deg = circular_difference( ...
    row.participant_response_center_normalized_deg, state.expected_integration_deg);
row.adjustment_time_s = trial.response_time_s;
row.response_hold_event_count = trial.response_hold_event_count;
row.response_max_hold_duration_s = trial.response_max_hold_duration_s;
row.response_peak_hold_speed_deg_s = trial.response_peak_hold_speed_deg_s;
row.response_total_hold_rotation_deg = trial.response_total_hold_rotation_deg;
row.aborted = trial.aborted;
row.valid = ~trial.aborted;
row.abort_stage = string(trial.abort_stage);
row.simulated = cfg.simulated;
row.data_label = string(cfg.test_label);
row.requested_frame_interval_s = screen_info.requested_frame_interval_s;
row.observed_mean_frame_interval_s = stimulus.mean_frame_interval_s;
row.observed_max_frame_interval_s = stimulus.max_frame_interval_s;
row.dropped_frame_count = stimulus.dropped_frames;
row.measured_refresh_hz = screen_info.measured_refresh_hz;
row.screen_number = screen_info.screen_number;
row.screen_selection_reason = string(screen_info.screen_selection_reason);
row.screen_width_px = screen_info.full_width_px;
row.screen_height_px = screen_info.full_height_px;
row.window_width_px = screen_info.window_width_px;
row.window_height_px = screen_info.window_height_px;
row.physical_width_mm = screen_info.physical_width_mm;
row.physical_height_mm = screen_info.physical_height_mm;
row.viewing_distance_cm = cfg.viewing_distance_cm;
row.pixels_per_degree = screen_info.pixels_per_degree;
row.used_fallback_pixels_per_degree = screen_info.used_fallback_ppd;
row.fullscreen = cfg.fullscreen;
row.eye_tracking = false;
row.fixation_verified = false;
row.matlab_version = string(software.matlab_version);
row.psychtoolbox_version = string(software.psychtoolbox_version);
row.machine_architecture = string(computer('arch'));
end

function write_rows(path, rows)
if isempty(rows), return; end
table_value = struct2table(rows, 'AsArray', true);
temporary_path = [path '.tmp'];
writetable(table_value, temporary_path, 'FileType', 'text', 'Delimiter', ',');
[moved, message] = movefile(temporary_path, path, 'f');
if ~moved, error('Unable to finalize trial data: %s', message); end
end

function write_status(path, cfg, software, session_id, csv_path, rows, aborted, state)
status = struct('label', cfg.test_label, 'mission_id', cfg.mission_id, ...
    'software_version', cfg.software_version, 'git_commit', software.git_commit, ...
    'timestamp_utc', utc_now(), 'anonymous_session_id', session_id, ...
    'csv_path', csv_path, 'recorded_rows', numel(rows), ...
    'completed_trials', completed_count(rows), 'aborted', logical(aborted), ...
    'state', state, 'simulated', logical(cfg.simulated));
temporary_path = [path '.tmp'];
fid = fopen(temporary_path, 'w');
if fid < 0, error('Unable to write temporary session status: %s', temporary_path); end
try
    fwrite(fid, jsonencode(status, 'PrettyPrint', true), 'char');
    fclose(fid);
catch ME
    fclose(fid);
    rethrow(ME);
end
[moved, message] = movefile(temporary_path, path, 'f');
if ~moved, error('Unable to finalize session status: %s', message); end
end

function count = completed_count(rows)
if isempty(rows), count = 0; else, count = sum(~[rows.aborted]); end
end

function software = software_identity(script_dir, cfg)
mission_dir = fileparts(script_dir);
[ok, commit] = system(sprintf('git -C "%s" rev-parse HEAD', mission_dir));
if ok ~= 0, commit = 'uncommitted'; else, commit = strtrim(commit); end
[dirty_ok, dirty] = system(sprintf('git -C "%s" status --porcelain -- "%s"', mission_dir, script_dir));
if dirty_ok == 0 && ~isempty(strtrim(dirty)), commit = [commit '-dirty']; end
try
    ptb = PsychtoolboxVersion;
catch
    ptb = 'unknown';
end
software = struct('git_commit', commit, 'matlab_version', version, ...
    'psychtoolbox_version', ptb, 'software_version', cfg.software_version);
end

function path = resolve_output_directory(script_dir, configured, override)
if ~isempty(override)
    path = char(override);
elseif isfolder(configured) || startsWith(configured, filesep)
    path = char(configured);
else
    path = fullfile(script_dir, char(configured));
end
end

function id = choose_session_id(opts, cfg)
if ~isempty(opts.SessionId)
    raw = char(opts.SessionId);
elseif cfg.simulated
    raw = ['SMOKE-' char(datetime('now', 'Format', 'yyyyMMdd-HHmmss-SSS'))];
else
    raw = ['ANON-' char(datetime('now', 'Format', 'yyyyMMdd-HHmmss-SSS'))];
end
id = regexprep(raw, '[^A-Za-z0-9_-]', '-');
end

function assert_output_paths_available(csv_path, status_path)
if isfile(csv_path) || isfile(status_path)
    error('two_group_motion_demo:OutputExists', ...
        ['Output already exists for this session identifier. Nothing was overwritten. ' ...
        'Choose a new SessionId. Existing paths: %s ; %s'], csv_path, status_path);
end
end

function value = safe_mean(values)
if isempty(values), value = NaN; else, value = mean(values); end
end

function value = safe_max(values)
if isempty(values), value = NaN; else, value = max(values); end
end

function value = circular_difference(a, b)
if ~isfinite(a) || ~isfinite(b), value = NaN; else, value = wrap_to_180(a - b); end
end

function value = wrap_to_180(value)
value = mod(value + 180, 360) - 180;
end

function text = utc_now()
text = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''));
end

function paths = generate_parameter_figures(script_dir, cfg, vectors)
fig_dir = fullfile(script_dir, 'figures');
if ~exist(fig_dir, 'dir'), mkdir(fig_dir); end
rng(double(cfg.random_seed), 'twister');

example_direction = -30;
state = vector_for_direction(cfg, example_direction);
center_pts = sample_disk(cfg.center_dot_count, cfg.center_radius_deg);
inner_pts = sample_annulus(cfg.inner_dot_count, cfg.inner_radius_min_deg, cfg.inner_radius_max_deg);
outer_pts = sample_annulus(cfg.outer_dot_count, cfg.outer_radius_min_deg, cfg.outer_radius_max_deg);

f1 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1000 650]);
ax = axes(f1); hold(ax, 'on'); axis(ax, 'equal');
center_color = cfg.center_color_rgb / 255;
inner_color = cfg.inner_color_rgb / 255;
outer_color = cfg.outer_color_rgb / 255;
scatter(ax, outer_pts(:,1), outer_pts(:,2), 8, outer_color, 'filled');
scatter(ax, inner_pts(:,1), inner_pts(:,2), 18, inner_color, 'filled');
scatter(ax, center_pts(:,1), center_pts(:,2), 28, center_color, 'filled');
draw_circle(ax, cfg.center_radius_deg, center_color);
draw_circle(ax, cfg.inner_radius_min_deg, inner_color);
draw_circle(ax, cfg.inner_radius_max_deg, inner_color);
draw_circle(ax, cfg.outer_radius_min_deg, outer_color);
draw_circle(ax, cfg.outer_radius_max_deg, outer_color);
scale = 2.0;
quiver(ax, -0.7, 0, scale*state.center(1), scale*state.center(2), 0, 'Color', [0.1 0.55 0.2], 'LineWidth', 2, 'MaxHeadSize', 0.8);
quiver(ax, 1.7, 0, scale*state.inner(1), scale*state.inner(2), 0, 'Color', [0.8 0.1 0.1], 'LineWidth', 2, 'MaxHeadSize', 0.8);
quiver(ax, 3.2, 0, scale*state.outer(1), scale*state.outer(2), 0, 'Color', [0 0.4 0.8], 'LineWidth', 2, 'MaxHeadSize', 0.8);
text(ax, -1.4, 1.25, 'fixed center v', 'Color', [0.1 0.45 0.2], 'FontWeight', 'bold');
text(ax, 1.1, -1.9, 'varied inner-group v', 'Color', [0.75 0.05 0.05], 'FontWeight', 'bold');
text(ax, 2.2, 1.6, 'outer v adjusted to keep outer-inner fixed', 'Color', [0 0.35 0.7], 'FontWeight', 'bold');
xlabel(ax, 'horizontal position (deg)'); ylabel(ax, 'vertical position (deg; up positive)');
title(ax, sprintf('Implemented stimulus schematic: inner direction %g deg, 100%% coherence', example_direction));
xlim(ax, [-4.5 7.5]); ylim(ax, [-4.5 4.5]); grid(ax, 'on');
subtitle(ax, sprintf('fixed outer-inner vector = [0, %.4f] deg/s', state.fixed_outer_minus_inner(2)));
stimulus_path = fullfile(fig_dir, 'stimulus_schematic.png');
exportgraphics(f1, stimulus_path, 'Resolution', 180); close(f1);

f2 = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 950 600]);
ax = axes(f2); hold(ax, 'on');
x = vectors.condition_inner_direction_deg;
plot(ax, x, -90 * ones(size(x)), '-o', 'LineWidth', 2.5, 'Color', [0.45 0.15 0.75], 'DisplayName', 'integration hypothesis: group relative to outer');
plot(ax, x, zeros(size(x)), '-s', 'LineWidth', 2.5, 'Color', [0.2 0.2 0.2], 'DisplayName', 'retinal center direction');
seg = 90 * ones(size(x)); seg(x == 0) = NaN;
plot(ax, x, seg, '-^', 'LineWidth', 2.5, 'Color', [0.9 0.3 0.1], 'DisplayName', 'segmentation hypothesis: center relative to inner');
yline(ax, 0, ':', 'Color', [0.5 0.5 0.5], 'HandleVisibility', 'off');
xlabel(ax, 'inner ring direction relative to fixed center (deg)');
ylabel(ax, 'reference response direction (deg)');
title(ax, 'Expected-response illustration from implemented vectors');
subtitle(ax, 'Reference hypotheses, not objectively correct answers');
xticks(ax, sort(x)); set(ax, 'XDir', 'reverse');
yticks(ax, [-90 0 90]); ylim(ax, [-110 110]); grid(ax, 'on');
legend(ax, 'Location', 'best');
expected_path = fullfile(fig_dir, 'expected_response_illustration.png');
exportgraphics(f2, expected_path, 'Resolution', 180); close(f2);

paths = {stimulus_path, expected_path};
end

function draw_circle(ax, radius, color)
t = linspace(0, 2*pi, 300);
plot(ax, radius*cos(t), radius*sin(t), '-', 'Color', color, 'LineWidth', 0.7);
end

function restore_environment(old_skip_sync, eyetracker, obs_started)

% ---------- EyeLink cleanup ----------
try
    if ~isempty(eyetracker)
        try
            eyetracker.stop_recording();
        catch
            try
                Eyelink('StopRecording');
            catch
            end
        end

        % Close EDF and RECEIVE it from the EyeLink host
        try
            eyetracker.close();
        catch me
            warning('two_group_motion_demo:EyeLinkCloseFailed', ...
                'EyeLink close/ReceiveFile failed: %s', me.message);
            
            % Fallback cleanup
            try
                Eyelink('CloseFile');
            catch
            end

            try
                Eyelink('Shutdown');
            catch
            end
        end
    end
catch
end

% ---------------------------------------------------------
% Restore MATLAB / Psychtoolbox environment
% ---------------------------------------------------------

try
    ListenChar(0);
catch
end

try
    Priority(0);
catch
end

try
    ShowCursor;
catch
end

try
    Screen('CloseAll');
catch
end

try
    Screen('Preference', 'SkipSyncTests', old_skip_sync);
catch
end

end

function positions = update_coherent_dots( ...
        positions, signal_velocity, coherence_percent, ...
        dt, kind, radius_a, radius_b)
% UPDATE_COHERENT_DOTS Apply motion coherence independently within a region.
% On every display update, exactly round(N*coherence/100) dots are assigned
% the region's signal velocity. Remaining dots move at the same speed but
% in independently randomized directions. Signal/noise membership is
% resampled each update (dynamic-noise RDK).

n = size(positions, 1);
n_signal = min(n, max(0, round(n * coherence_percent / 100)));

order = randperm(n);
signal_idx = order(1:n_signal);
noise_idx = order(n_signal + 1:end);

if ~isempty(signal_idx)
    positions(signal_idx, :) = positions(signal_idx, :) + dt * signal_velocity;
end

if ~isempty(noise_idx)
    signal_speed = norm(signal_velocity);
    noise_angle = 360 * rand(numel(noise_idx), 1);
    noise_velocity = signal_speed .* [cosd(noise_angle), sind(noise_angle)];
    positions(noise_idx, :) = positions(noise_idx, :) + dt * noise_velocity;
end

positions = replenish_positions(positions, kind, radius_a, radius_b);
end
