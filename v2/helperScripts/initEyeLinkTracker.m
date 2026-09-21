function [eyetracker, eyeInfo] = initEyeLinkTracker(window, windowRect, expParams)
%INITEYELINKTRACKER Connect EyeLink and return the Tobii-compatible adapter.
%
% Use this during real data collection after the PTB window has opened and
% subject output directories exist. The function performs only run-level
% setup:
%
%   1. Verify required EyeLink Toolbox functions are on the MATLAB path.
%   2. Open the Ethernet connection to the tracker.
%   3. Open one EDF file on the tracker host.
%   4. Configure file/link sample fields needed by the adapter.
%   5. Return `EyeLinkTobiiCompat`, which task code stores as
%      `expParams.eyeTracker`.
%
% Calibration and recording start are intentionally handled by the caller so
% failures are easier to report at the experiment level.

eyetracker = [];
eyeInfo = struct();

requireEyeLinkFunction('Eyelink');
requireEyeLinkFunction('EyelinkInit');
requireEyeLinkFunction('EyelinkInitDefaults');
requireEyeLinkFunction('EyelinkUpdateDefaults');
requireEyeLinkFunction('EyelinkDoTrackerSetup');
requireEyeLinkFunction('InitializePsychSound');

fprintf('Beginning EyeLink Initialization...\n');

dummyMode = 0;
didInit = false;

try
    if ~EyelinkInit(dummyMode)
        error('initEyeLinkTracker:ConnectionFailed', ...
            'Could not initialize EyeLink connection. Check Ethernet/IP and tracker host mode.');
    end
    didInit = true;

    % EyeLink defaults can query PsychPortAudio for calibration feedback beeps.
    InitializePsychSound();

    el = EyelinkInitDefaults(window);
    EyelinkUpdateDefaults(el);

    [screenWidth, screenHeight] = Screen('WindowSize', window);

    edfFileName = buildEdfFileName(expParams.subjID);
    localEdfPath = fullfile(expParams.subjPaths.eyeDir, edfFileName);

    status = Eyelink('OpenFile', edfFileName);
    if isempty(status)
        status = 0;
    end

    if status ~= 0
        error('initEyeLinkTracker:OpenFileFailed', ...
            'Could not open EyeLink EDF file %s on tracker host. Status: %d.', edfFileName, status);
    end

    sendCommand('add_file_preamble_text ''Human Tetris EyeLink recording''');
    sendCommand(sprintf('screen_pixel_coords = 0 0 %d %d', screenWidth - 1, screenHeight - 1));
    Eyelink('Message', sprintf('DISPLAY_COORDS 0 0 %d %d', screenWidth - 1, screenHeight - 1));

    sendCommand('sample_rate = 1000');
    sendCommand('pupil_size_diameter = YES');
    sendCommand('file_event_filter = LEFT,RIGHT,FIXATION,SACCADE,BLINK,MESSAGE,BUTTON,INPUT');
    sendCommand('file_sample_data = LEFT,RIGHT,GAZE,AREA,GAZERES,HREF,PUPIL,STATUS,INPUT');
    sendCommand('link_event_filter = LEFT,RIGHT,FIXATION,SACCADE,BLINK,BUTTON,INPUT');
    sendCommand('link_sample_data = LEFT,RIGHT,GAZE,AREA,GAZERES,HREF,PUPIL,STATUS,INPUT');

    eyetracker = EyeLinkTobiiCompat(window, windowRect, el, edfFileName, localEdfPath, [screenWidth, screenHeight]);

    eyeInfo = struct( ...
        'backend', 'eyelink', ...
        'model', eyetracker.Model, ...
        'address', eyetracker.Address, ...
        'edfFileName', edfFileName, ...
        'localEdfPath', localEdfPath, ...
        'screen_pixels', [screenWidth, screenHeight], ...
        'initializedAt', datetime('now') ...
        );

    fprintf('Connected to EyeLink tracker.\n');
    fprintf('  EDF: %s\n', localEdfPath);
    fprintf('  PTB: %s\n', eyetracker.RuntimeVersion);
catch me
    if didInit
        try
            Eyelink('CloseFile');
        catch
        end

        try
            Eyelink('Shutdown');
        catch
        end
    end

    rethrow(me);
end
end

function requireEyeLinkFunction(functionName)
% Fail early with a clear path/setup error.
if isempty(which(functionName))
    error('initEyeLinkTracker:MissingFunction', ...
        'Required EyeLink/PTB function is not on the MATLAB path: %s.', functionName);
end
end

function sendCommand(commandText)
% Send a tracker command, warning instead of aborting on optional commands.
try
    Eyelink('Command', commandText);
catch me
    warning('initEyeLinkTracker:CommandFailed', ...
        'EyeLink command failed: %s | %s', commandText, me.message);
end
end

function edfFileName = buildEdfFileName(subjID)
% Build an EyeLink-safe 8.3 EDF filename from the subject id and clock time.
subj = upper(regexprep(char(subjID), '[^A-Z0-9]', ''));
if isempty(subj)
    subj = 'S';
end

prefix = subj(1:min(2, numel(subj)));
stamp = datestr(now, 'HHMMSS');
baseName = [prefix stamp];
baseName = baseName(1:min(8, numel(baseName)));
edfFileName = [baseName '.edf'];
end
