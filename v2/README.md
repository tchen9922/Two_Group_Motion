# JP Two-Group Motion Demo — minimal handoff

Version: **0.6.0**

This is the minimal MATLAB/Psychtoolbox package for Jean Paul (JP). The ZIP contains exactly five files:

1. `two_group_motion_demo.m` — experiment and all runtime helpers;
2. `plot_two_group_motion_results.m` — results plotter;
3. `config/demo_default.json` — experiment parameters;
4. `run_demo.command` — macOS double-click launcher;
5. `README.md` — this file.

It deliberately excludes tests, figures, sample data, mission/SabyaOS records, source snapshots, paper files, and the live `data/` directory. The program creates `data/` beside the scripts when first run.

## Requirements

- MATLAB R2021a or newer;
- Psychtoolbox 3 with a working `Screen` installation and any required runtime activation;
- an ordinary keyboard. No dial, mouse, eye tracker, or external monitor is required.

The package was tested with MATLAB R2025a Update 1 and Psychtoolbox 3.0.22 on Apple silicon. A connected external monitor is preferred automatically; the built-in display is used when it is the only screen.

## Five design settings to edit

The first five settings after `software_version` in `config/demo_default.json`
define the complete design:

```json
"rotation_values_deg": [0, 45, 90, 135, 180, 225, 270, 315],
"center_minus_inner_direction_deg": [0, 3, 5, 10, 15, 20, 30, 45],
"rotation_block_repetitions": 2,
"use_trial_subset": false,
"subset_trial_count": 16
```

These are the only five fields normally changed when modifying the design.
The program derives the source-signed inner-minus-center values internally.
`rotation_block_repetitions` says how many times every rotation block appears.
The packaged value `2` preserves the locally selected two repetitions; change
it to `5` for the earlier 320-trial full design.

## Run the experiment

On macOS, double-click `run_demo.command`. Alternatively, open MATLAB in this folder and run:

```matlab
two_group_motion_demo
```

Every rotation block contains all eight center-minus-inner directions exactly
once in randomized order. Blocks sample all eight rotations in randomized
order before any rotation repeats. Direction order is also chosen so identical
directions are never adjacent across a block boundary.

With the packaged two block repetitions, the full design has
`8 directions × 8 rotations × 2 repetitions = 128 trials`. Setting block
repetitions to `5` gives 320 trials. The CSV preserves the block location,
planned trial count, positive center-minus-inner value, and corresponding
source-signed inner-minus-center value.

For a short demonstration, set:

```json
"use_trial_subset": true,
"subset_trial_count": 16
```

Because there are eight directions, 16 trials select two complete blocks with
two different randomly chosen rotations; 24 selects three blocks. The subset
count must be a multiple of the number of directions, so 60 is rejected for
an eight-direction design—use 56 or 64 instead. It cannot exceed the full
design. The equivalent one-run MATLAB override is:

```matlab
two_group_motion_demo('UseTrialSubset', true, 'SubsetTrialCount', 16)
```

On every trial, version 0.6.0 uses the rotation assigned to the current block
and rotates the center, inner, and outer velocity vectors together. Every
rotation occurs equally often at every separation. This varies absolute motion
direction to diagnose reporting/decision bias while preserving all
center-aligned relative velocities. The CSV saves the selected rotation,
displayed vectors, absolute response, and center-normalized response.

After the 2-second stimulus, the response screen contains only the patch-sized circle and green arrow:

- tap Left/Right for 1° steps;
- hold Left/Right for accelerating rotation;
- hold Shift as well for faster rotation;
- press Enter or Space to confirm and hear a tone;
- press P to pause or Escape to save and quit.

Outputs are written under `data/` after every trial. Escape safely preserves
the current CSV and session status, including an aborted row when termination
occurs during a trial. Windowed mode is intended for development; research use
requires a fullscreen synchronization check, display/viewing-distance
calibration, and the relevant human-subject approvals.

## Make the plot

To plot the newest session:

```matlab
plot_two_group_motion_results
```

Or select a trials CSV:

```matlab
plot_two_group_motion_results(fullfile('data', 'ANON-..._trials.csv'))
```

PNG and PDF output is saved under `data/plots/` as two figures:

1. `*_responses_by_rotation` overlays one colored circular-mean/SEM trace for
   each sampled rotation R.
2. `*_responses_collapsed` pools all rotations. With the default design, each
   point summarizes 16 trials after a complete two-repeat full run. Only this
   figure uses the thick black line
   labeled `collapsed across all rotations`.

If the experiment is terminated early, the plotter excludes only aborted or
invalid rows and uses every completed valid trial collected so far. Both
figures are produced from the available rotations/directions and are labelled
as a partial session with valid, recorded, scheduled, and full-design counts.

Absolute response directions are circularly normalized by subtracting the
displayed center direction. The x-axis is **center minus inner ring** and
increases left-to-right as `0, 3, 5, 10, 15, 20, 30, 45°`.

## Scientific source

This reduced implementation follows the vector construction and stimulus
parameters of Experiment 2 in Shivkumar, DeAngelis, and Haefner (2025),
“Hierarchical motion perception as causal inference,” *Nature Communications*
16:3868, <https://doi.org/10.1038/s41467-025-58797-0>. The original Experiment 2
separations were `0, 3, 10, 30, 45°`; version 0.6.0 retains the
user-requested exploratory `5, 15, 20°` levels. These additions are not claimed
to be original paper conditions. No recovered source snapshot is included in
this ZIP.

The extracted working folder retains its historical `v0.5.0` directory name
to avoid moving existing local data. The `software_version` in the JSON and
the version printed here are authoritative; the distributable ZIP is named
`JP_Two_Group_Motion_Demo_v0.6.0_MINIMAL.zip`.

The package has been prepared locally but has not been transmitted automatically. Sabya retains final authority over collaborator transfer and participant use.
