function calibrationData = calibrateEyeLink(window, windowRect, eyetracker, expParams)
%CALIBRATEEYELINK Run EyeLink tracker setup from the experiment PTB window.
%
% This is the EyeLink replacement for `calibrateTobii`. It does not implement
% a custom calibration kernel. Instead it delegates to Psychtoolbox's
% `EyelinkDoTrackerSetup`, which opens the standard SR Research setup UI for
% camera setup, calibration, and validation.
%
% Call this after `initEyeLinkTracker` and before `eyetracker.start_recording`.
% The returned struct is small metadata for experiment logs; the definitive
% calibration information remains in the EyeLink EDF/session state.

calibrationData = struct( ...
    'backend', 'eyelink', ...
    'status', 'not_started', ...
    'timestamp', datetime('now') ...
    );

HideCursor(window);
Screen('TextFont', window, 'Arial');
Screen('TextSize', window, 24);

try
    Screen('FillRect', window, BlackIndex(0));
    DrawFormattedText(window, ...
        sprintf('EyeLink calibration\n\nPress SPACE to open tracker setup.\nPress ESC to abort calibration.'), ...
        'center', 'center', window, WhiteIndex(0));
    Screen('Flip', window);

    KbName('UnifyKeyNames');
    spaceKey = KbName('space');
    escapeKey = KbName('ESCAPE');

    while true
        [~, ~, keyCode] = KbCheck;
        if keyCode(escapeKey)
            % Allow the experimenter to continue or abort from the caller.
            calibrationData.status = 'aborted';
            ShowCursor(window);
            return;
        end

        if keyCode(spaceKey)
            break;
        end
    end

    EyelinkDoTrackerSetup(eyetracker.El);
    % If the setup window returns normally, keep a simple audit record.
    calibrationData.status = 'completed';
    calibrationData.windowRect = windowRect;
    calibrationData.eyeUsed = eyetracker.EyeUsed;

    outDir = expParams.subjPaths.eyeDir;
    if ~exist(outDir, 'dir')
        mkdir(outDir);
    end

    calibrationFile = fullfile(outDir, sprintf('eyelink_calibration_%s.mat', datestr(now, 'yyyymmdd_HHMMSS')));
    save(calibrationFile, 'calibrationData');
    calibrationData.file = calibrationFile;
catch me
    ShowCursor(window);
    rethrow(me);
end

ShowCursor(window);
end
