function result = plot_two_group_motion_results(csv_path, varargin)
% PLOT_TWO_GROUP_MOTION_RESULTS Plot responses before and after pooling R.
%
% Simplest use (plots the newest CSV in data/):
%   plot_two_group_motion_results
%
% Or choose a session explicitly:
%   plot_two_group_motion_results('data/ANON-..._trials.csv')
%
% The first figure overlays one center-normalized response trace for every
% sampled global rotation R. The second pools trials across rotations and
% draws the pooled circular mean as a thick black line. The x-axis is the
% positive center-minus-inner direction separation. Aborted/invalid rows
% are excluded, but every completed valid row in a partial session is used.

script_dir = fileparts(mfilename('fullpath'));
if nargin < 1 || isempty(csv_path)
    csv_path = newest_trials_csv(fullfile(script_dir, 'data'));
end

p = inputParser;
addParameter(p, 'OutputDir', '');
addParameter(p, 'Visible', true);
addParameter(p, 'Formats', {'png', 'pdf'});
parse(p, varargin{:});
opts = p.Results;

csv_path = char(csv_path);
if ~isfile(csv_path), error('Results CSV not found: %s', csv_path); end
trials = readtable(csv_path, 'Delimiter', ',', 'VariableNamingRule', 'preserve');
required = {'varied_inner_direction_deg', 'participant_response_deg', ...
    'expected_response_deg', 'expected_retinal_deg', ...
    'expected_segmentation_deg', 'common_global_rotation_deg', ...
    'aborted', 'valid'};
missing = required(~ismember(required, trials.Properties.VariableNames));
if ~isempty(missing)
    error('plot_two_group_motion_results:MissingColumns', ...
        'Results CSV is missing: %s', strjoin(missing, ', '));
end

response_angles = center_normalized_responses(trials);
valid_rows = logical(trials.valid) & ~logical(trials.aborted) & ...
    isfinite(response_angles) & isfinite(trials.common_global_rotation_deg);
if ~any(valid_rows)
    error('plot_two_group_motion_results:NoValidTrials', ...
        'The CSV contains no completed valid responses to plot.');
end

if ismember('center_minus_inner_direction_deg', trials.Properties.VariableNames)
    center_minus_inner = trials.center_minus_inner_direction_deg;
else
    center_minus_inner = -trials.varied_inner_direction_deg;
end
rotations = sort(unique(mod(trials.common_global_rotation_deg(valid_rows), 360)), ...
    'ascend');
conditions = sort(unique(center_minus_inner(valid_rows)), 'ascend');
[progress, progress_text] = session_progress(trials, valid_rows);
[rotation_summary, collapsed_summary] = summarize_responses(trials, ...
    valid_rows, response_angles, center_minus_inner, rotations, conditions);

if opts.Visible, visibility = 'on'; else, visibility = 'off'; end
rotation_fig = plot_by_rotation(rotation_summary, rotations, conditions, ...
    progress_text, session_label(trials, csv_path), visibility);
collapsed_fig = plot_collapsed(valid_rows, response_angles, ...
    center_minus_inner, collapsed_summary, conditions, ...
    progress_text, session_label(trials, csv_path), visibility);
if ~opts.Visible
    cleanup = onCleanup(@() close_figures(rotation_fig, collapsed_fig));
end

output_dir = char(opts.OutputDir);
if isempty(output_dir), output_dir = fullfile(fileparts(csv_path), 'plots'); end
if ~exist(output_dir, 'dir'), mkdir(output_dir); end
[~, base_name] = fileparts(csv_path);
base_name = regexprep(base_name, '_trials$', '');
formats = cellstr(string(opts.Formats));
rotation_paths = export_figure(rotation_fig, output_dir, ...
    [base_name '_responses_by_rotation'], formats);
collapsed_paths = export_figure(collapsed_fig, output_dir, ...
    [base_name '_responses_collapsed'], formats);
output_paths = [rotation_paths, collapsed_paths];

result = struct('csv_path', csv_path, ...
    'output_paths', {output_paths}, ...
    'rotation_output_paths', {rotation_paths}, ...
    'collapsed_output_paths', {collapsed_paths}, ...
    'valid_trial_count', sum(valid_rows), ...
    'recorded_trial_row_count', height(trials), ...
    'planned_trial_count', progress.planned_trial_count, ...
    'full_design_trial_count', progress.full_design_trial_count, ...
    'is_partial_session', progress.is_partial_session, ...
    'is_subset_session', progress.is_subset_session, ...
    'rotation_summary', rotation_summary, ...
    'collapsed_summary', collapsed_summary, ...
    'summary', collapsed_summary, ...
    'rotation_figure_handle', rotation_fig, ...
    'collapsed_figure_handle', collapsed_fig);
end

function [rotation_summary, collapsed_summary] = summarize_responses( ...
        trials, valid_rows, responses, center_minus_inner, rotations, conditions)
n_rows = numel(rotations) * numel(conditions);
r_value = nan(n_rows, 1);
condition_value = nan(n_rows, 1);
n = zeros(n_rows, 1);
mean_response = nan(n_rows, 1);
circular_sem = nan(n_rows, 1);
row = 0;
for r_idx = 1:numel(rotations)
    for c_idx = 1:numel(conditions)
        row = row + 1;
        selected = valid_rows & ...
            abs(mod(trials.common_global_rotation_deg, 360) - rotations(r_idx)) < 1e-9 & ...
            abs(center_minus_inner - conditions(c_idx)) < 1e-9;
        angles = responses(selected);
        r_value(row) = rotations(r_idx);
        condition_value(row) = conditions(c_idx);
        n(row) = numel(angles);
        [mean_response(row), circular_sd] = circular_summary_deg(angles);
        if n(row) > 1, circular_sem(row) = circular_sd / sqrt(n(row)); end
    end
end
rotation_summary = table(r_value, condition_value, n, mean_response, circular_sem, ...
    'VariableNames', {'common_global_rotation_deg', ...
    'center_minus_inner_direction_deg', 'valid_trials', ...
    'circular_mean_response_deg', 'circular_sem_deg'});

n_conditions = numel(conditions);
pooled_n = zeros(n_conditions, 1);
pooled_mean = nan(n_conditions, 1);
pooled_sem = nan(n_conditions, 1);
integration_reference = nan(n_conditions, 1);
retinal_reference = nan(n_conditions, 1);
segmentation_reference = nan(n_conditions, 1);
for c_idx = 1:n_conditions
    selected = valid_rows & abs(center_minus_inner - conditions(c_idx)) < 1e-9;
    angles = responses(selected);
    pooled_n(c_idx) = numel(angles);
    [pooled_mean(c_idx), circular_sd] = circular_summary_deg(angles);
    if pooled_n(c_idx) > 1, pooled_sem(c_idx) = circular_sd / sqrt(pooled_n(c_idx)); end
    integration_reference(c_idx) = circular_mean_deg( ...
        trials.expected_response_deg(selected));
    retinal_reference(c_idx) = circular_mean_deg( ...
        trials.expected_retinal_deg(selected));
    segmentation_reference(c_idx) = circular_mean_deg( ...
        trials.expected_segmentation_deg(selected));
end
collapsed_summary = table(conditions(:), pooled_n, pooled_mean, pooled_sem, ...
    integration_reference, retinal_reference, segmentation_reference, ...
    'VariableNames', {'center_minus_inner_direction_deg', 'valid_trials', ...
    'circular_mean_response_deg', 'circular_sem_deg', ...
    'integration_reference_deg', 'retinal_reference_deg', ...
    'segmentation_reference_deg'});
end

function fig = plot_by_rotation(summary, rotations, conditions, ...
        progress_text, label, visibility)
fig = figure('Color', 'w', 'Visible', visibility, 'Position', [80 80 1050 680]);
ax = axes(fig); hold(ax, 'on');
palette = lines(numel(rotations));
for idx = 1:numel(rotations)
    rows = abs(summary.common_global_rotation_deg - rotations(idx)) < 1e-9;
    errorbar(ax, summary.center_minus_inner_direction_deg(rows), ...
        summary.circular_mean_response_deg(rows), summary.circular_sem_deg(rows), ...
        'o-', 'Color', palette(idx, :), 'MarkerFaceColor', palette(idx, :), ...
        'LineWidth', 1.5, 'CapSize', 7, ...
        'DisplayName', sprintf('R = %g deg', rotations(idx)));
end
yline(ax, 0, '-', 'Color', [0.78 0.78 0.78], 'HandleVisibility', 'off');
xlabel(ax, 'center minus inner-ring direction (deg)');
ylabel(ax, 'center-normalized reported green-center direction (deg)');
title(ax, 'Responses separated by global rotation R');
subtitle(ax, sprintf('%s | %s | one colored trace per R', ...
    progress_text, label), 'Interpreter', 'none');
xticks(ax, conditions); yticks(ax, -180:45:180); ylim(ax, [-180 180]);
if isscalar(conditions), xlim(ax, conditions + [-1 1]); end
grid(ax, 'on'); box(ax, 'off'); legend(ax, 'Location', 'eastoutside');
end

function fig = plot_collapsed(valid_rows, responses, ...
        center_minus_inner, summary, conditions, progress_text, label, visibility)
fig = figure('Color', 'w', 'Visible', visibility, 'Position', [100 100 1000 650]);
ax = axes(fig); hold(ax, 'on');
[raw_x, raw_y] = jittered_points(center_minus_inner(valid_rows), ...
    responses(valid_rows), conditions);
scatter(ax, raw_x, raw_y, 26, [0.45 0.45 0.45], 'filled', ...
    'MarkerFaceAlpha', 0.35, 'DisplayName', 'individual valid trials');
errorbar(ax, summary.center_minus_inner_direction_deg, ...
    summary.circular_mean_response_deg, summary.circular_sem_deg, 'o-', ...
    'Color', [0 0 0], 'MarkerFaceColor', [0 0 0], 'LineWidth', 3.2, ...
    'CapSize', 11, 'DisplayName', 'collapsed across all rotations');
plot(ax, conditions, summary.integration_reference_deg, '--', ...
    'Color', [0.45 0.15 0.75], 'LineWidth', 1.5, ...
    'DisplayName', 'integration hypothesis');
plot(ax, conditions, summary.retinal_reference_deg, ':', ...
    'Color', [0.2 0.2 0.2], 'LineWidth', 1.5, ...
    'DisplayName', 'retinal reference');
plot(ax, conditions, summary.segmentation_reference_deg, '-.', ...
    'Color', [0.9 0.3 0.1], 'LineWidth', 1.5, ...
    'DisplayName', 'segmentation hypothesis');
yline(ax, 0, '-', 'Color', [0.78 0.78 0.78], 'HandleVisibility', 'off');
xlabel(ax, 'center minus inner-ring direction (deg)');
ylabel(ax, 'center-normalized reported green-center direction (deg)');
title(ax, 'Responses collapsed across global rotations');
subtitle(ax, sprintf('%s | %s', progress_text, label), ...
    'Interpreter', 'none');
xticks(ax, conditions); yticks(ax, -180:45:180); ylim(ax, [-180 180]);
if isscalar(conditions), xlim(ax, conditions + [-1 1]); end
grid(ax, 'on'); box(ax, 'off'); legend(ax, 'Location', 'best');
end

function [raw_x, raw_y] = jittered_points(x, y, conditions)
raw_x = [];
raw_y = [];
if numel(conditions) > 1
    spacing = min(abs(diff(conditions)));
    jitter_width = max(0.08, 0.12 * spacing);
else
    jitter_width = 0.3;
end
for idx = 1:numel(conditions)
    rows = abs(x - conditions(idx)) < 1e-9;
    values = y(rows);
    offsets = linspace(-0.5, 0.5, numel(values))' * jitter_width;
    raw_x = [raw_x; conditions(idx) + offsets]; %#ok<AGROW>
    raw_y = [raw_y; values]; %#ok<AGROW>
end
end

function paths = export_figure(fig, output_dir, base_name, formats)
paths = cell(size(formats));
for idx = 1:numel(formats)
    format = lower(formats{idx});
    paths{idx} = fullfile(output_dir, sprintf('%s.%s', base_name, format));
    if strcmp(format, 'png')
        exportgraphics(fig, paths{idx}, 'Resolution', 180);
    elseif strcmp(format, 'pdf')
        exportgraphics(fig, paths{idx}, 'ContentType', 'vector');
    else
        error('plot_two_group_motion_results:InvalidFormat', ...
            'Format must be png or pdf, not %s.', format);
    end
end
end

function angles = center_normalized_responses(trials)
names = trials.Properties.VariableNames;
if ismember('participant_response_center_normalized_deg', names)
    angles = trials.participant_response_center_normalized_deg;
elseif all(ismember({'participant_response_absolute_deg', ...
        'common_global_rotation_deg'}, names))
    angles = wrap_degrees(trials.participant_response_absolute_deg - ...
        trials.common_global_rotation_deg);
else
    angles = trials.participant_response_deg;
end
end

function angles = wrap_degrees(angles)
angles = mod(angles + 180, 360) - 180;
end

function csv_path = newest_trials_csv(data_dir)
files = dir(fullfile(data_dir, '*_trials.csv'));
if isempty(files)
    error('plot_two_group_motion_results:NoDataFiles', ...
        'No trials CSV exists in %s. Run the demo or pass a CSV path.', data_dir);
end
[~, newest] = max([files.datenum]);
csv_path = fullfile(files(newest).folder, files(newest).name);
end

function [mean_angle, circular_sd] = circular_summary_deg(angles)
angles = angles(isfinite(angles));
if isempty(angles), mean_angle = NaN; circular_sd = NaN; return; end
mean_angle = circular_mean_deg(angles);
components = exp(1i * deg2rad(angles));
resultant_length = min(1, abs(mean(components)));
circular_sd = rad2deg(sqrt(max(0, -2 * log(max(resultant_length, eps)))));
end

function mean_angle = circular_mean_deg(angles)
angles = angles(isfinite(angles));
if isempty(angles), mean_angle = NaN; return; end
mean_angle = atan2d(mean(sind(angles)), mean(cosd(angles)));
mean_angle = mod(mean_angle + 180, 360) - 180;
end

function [progress, text] = session_progress(trials, valid_rows)
planned = first_finite_value(trials, 'scheduled_trial_count');
full_design = first_finite_value(trials, 'full_design_trial_count');
valid_count = sum(valid_rows);
recorded_count = height(trials);
has_aborted_row = any(logical(trials.aborted));
if ismember('use_trial_subset', trials.Properties.VariableNames)
    is_subset = logical(trials.use_trial_subset(1));
else
    is_subset = isfinite(planned) && isfinite(full_design) && planned < full_design;
end
if isfinite(planned)
    is_partial = valid_count < planned;
else
    is_partial = has_aborted_row;
end

if isfinite(planned) && is_partial
    text = sprintf('partial: %d/%d valid (%d rows)', ...
        valid_count, planned, recorded_count);
elseif isfinite(planned) && is_subset
    text = sprintf('complete subset: %d/%d valid', ...
        valid_count, planned);
elseif isfinite(planned)
    text = sprintf('complete: %d/%d valid', ...
        valid_count, planned);
elseif is_partial
    text = sprintf('partial: %d valid (%d rows)', ...
        valid_count, recorded_count);
else
    text = sprintf('%d valid (%d rows)', valid_count, recorded_count);
end
if isfinite(full_design) && isfinite(planned) && full_design ~= planned
    text = sprintf('%s; full %d', text, full_design);
end

progress = struct('planned_trial_count', planned, ...
    'full_design_trial_count', full_design, ...
    'valid_trial_count', valid_count, ...
    'recorded_trial_row_count', recorded_count, ...
    'is_partial_session', logical(is_partial), ...
    'is_subset_session', logical(is_subset));
end

function value = first_finite_value(trials, variable_name)
value = NaN;
if ~ismember(variable_name, trials.Properties.VariableNames), return; end
values = double(trials.(variable_name));
values = values(isfinite(values));
if ~isempty(values), value = values(1); end
end

function label = session_label(trials, csv_path)
if ismember('anonymous_session_id', trials.Properties.VariableNames)
    label = char(string(trials.anonymous_session_id(1)));
else
    [~, label] = fileparts(csv_path);
end
end

function close_figures(varargin)
for idx = 1:nargin
    if isgraphics(varargin{idx}), close(varargin{idx}); end
end
end
