classdef EyeLinkTobiiCompat < handle
    %EYELINKTOBIICOMPAT EyeLink adapter with the old Tobii-shaped interface.
    %
    % This class is the drop-in boundary between the experiment code and the
    % SR Research EyeLink tracker. The existing task files were written around
    % a Tobii object and repeatedly call:
    %
    %   raw = eyetracker.get_gaze_data();
    %
    % Rather than rewriting every task loop, this adapter keeps that method
    % name and returns samples with the fields those loops already expect:
    %
    %   sample.SystemTimeStamp
    %   sample.DeviceTimeStamp
    %   sample.LeftEye.GazePoint.OnDisplayArea
    %   sample.LeftEye.Pupil.Diameter
    %   sample.RightEye.Pupil.Diameter
    %
    % Internally it drains EyeLink's PTB link queue, converts pixel gaze
    % coordinates into normalized display coordinates, and maps missing pupil
    % samples to zero so the existing loss calculations keep working.
    %
    % Create this through `initEyeLinkTracker`, not directly from task code.

    properties
        % Public metadata fields kept for old sanity checks and logs.
        Address = 'EyeLink Ethernet link'
        Name = 'EyeLink'
        SerialNumber = 'unknown'
        Model = 'EyeLink 1000 Plus'
        FirmwareVersion = 'unknown'
        RuntimeVersion = 'Psychtoolbox EyeLink Toolbox'
        Backend = 'eyelink'

        Window
        WindowRect
        El
        EdfFileName
        LocalEdfPath
        ScreenWidth
        ScreenHeight
        EyeUsed = NaN
        IsRecording = false
        IsClosed = false
    end

    properties (Constant, Access = private)
        % EyeLink uses this sentinel for missing numeric sample values.
        MissingData = -32768
    end

    methods
        function obj = EyeLinkTobiiCompat(window, windowRect, el, edfFileName, localEdfPath, screenSize)
            % Store PTB/EyeLink handles and output paths for one experiment run.
            obj.Window = window;
            obj.WindowRect = windowRect;
            obj.El = el;
            obj.EdfFileName = edfFileName;
            obj.LocalEdfPath = localEdfPath;
            obj.ScreenWidth = screenSize(1);
            obj.ScreenHeight = screenSize(2);

            obj.RuntimeVersion = getPsychtoolboxVersion();
            obj.SerialNumber = getTrackerVersion();
        end

        function start_recording(obj)
            % Start continuous EDF recording without enabling the link stream.
            % Active tasks do not require online gaze samples or events.
            if obj.IsRecording
                return;
            end

            status = Eyelink('StartRecording', 1, 1, 0, 0);

            if isempty(status)
                status = 0;
            end

            if status ~= 0
                error('EyeLinkTobiiCompat:StartRecordingFailed', ...
                    'EyeLink StartRecording failed with status %d.', status);
            end

            WaitSecs(0.1);

            try
                obj.EyeUsed = Eyelink('EyeAvailable');
            catch
                obj.EyeUsed = NaN;
            end

            obj.send_message('SYNCTIME');
            obj.send_message('RECORDING_STARTED');
            obj.IsRecording = true;
        end

        function stop_recording(obj)
            % Stop EyeLink recording if it is active.
            if ~obj.IsRecording
                return;
            end

            try
                obj.send_message('RECORDING_STOPPED');
            catch
            end

            try
                WaitSecs(0.05);
                Eyelink('StopRecording');
            catch
            end

            obj.IsRecording = false;
        end

        function raw = get_gaze_data(obj)
            % Return all queued samples since the previous read.
            %
            % On success this returns a struct array. On read failure this
            % returns a `StreamError` object because existing task loops already
            % know how to handle that shape.
            try
                raw = obj.readQueuedSamples();
            catch me
                raw = StreamError(me.message);
            end
        end

        function timestamp = get_system_time_stamp(~)
            % Return a host-side microsecond timestamp for legacy save fields.
            timestamp = GetSecs * 1e6;
        end

        function send_message(~, message, varargin)
            % Send a timestamped message into the EDF event stream.
            if nargin < 2 || isempty(message)
                return;
            end

            if isempty(varargin)
                Eyelink('Message', char(message));
            else
                Eyelink('Message', sprintf(char(message), varargin{:}));
            end
        end

        function close(obj)
            % Finish the EyeLink session and copy the EDF into the subject folder.
            %
            % This method is idempotent so wrapper cleanup can call it from both
            % normal and error paths.
            if obj.IsClosed
                return;
            end

            try
                obj.stop_recording();
            catch
            end

            try
                Eyelink('SetOfflineMode');
                WaitSecs(0.05);
            catch
            end

            try
                Eyelink('CloseFile');
            catch
            end

            try
                obj.receiveFile();
            catch me
                warning('EyeLinkTobiiCompat:ReceiveFileFailed', ...
                    'Could not receive EyeLink EDF file: %s', me.message);
            end

            try
                Eyelink('Shutdown');
            catch
            end

            obj.IsClosed = true;
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Access = private)
        function raw = readQueuedSamples(obj)
            % Prefer GetQueuedData because it drains complete batches cheaply.
            samples = [];

            try
                drained = 0;
                while ~drained
                    [chunk, ~, drained] = Eyelink('GetQueuedData');
                    if ~isempty(chunk)
                        samples = [samples, chunk]; %#ok<AGROW>
                    end
                end

                raw = obj.samplesMatrixToTobii(samples);
            catch
                raw = obj.readFloatSamplesFallback();
            end
        end

        function raw = readFloatSamplesFallback(obj)
            % Fallback for older PTB/EyeLink installations without GetQueuedData.
            raw = repmat(obj.emptySample(), 1, 0);

            while true
                dataType = Eyelink('GetNextDataType');
                if dataType == 0
                    break;
                end

                item = Eyelink('GetFloatData', dataType);
                if dataType ~= obj.El.SAMPLE_TYPE
                    continue;
                end

                raw(end+1) = obj.floatSampleToTobii(item); %#ok<AGROW>
            end
        end

        function raw = samplesMatrixToTobii(obj, samples)
            % Convert the GetQueuedData sample matrix into legacy sample structs.
            %
            % EyeLink rows 14-17 are display gaze in pixels. The old Tobii code
            % consumed normalized [0, 1] display coordinates, so conversion
            % happens before samples leave the adapter.
            if isempty(samples)
                raw = repmat(obj.emptySample(), 1, 0);
                return;
            end

            n = size(samples, 2);
            raw = repmat(obj.emptySample(), 1, n);

            for i = 1:n
                timeMs = obj.cleanMissing(samples(1, i));
                leftPupil = obj.cleanPupil(samples(12, i));
                rightPupil = obj.cleanPupil(samples(13, i));
                leftX = obj.cleanMissing(samples(14, i));
                rightX = obj.cleanMissing(samples(15, i));
                leftY = obj.cleanMissing(samples(16, i));
                rightY = obj.cleanMissing(samples(17, i));

                raw(i) = obj.makeSample(timeMs, leftX, leftY, rightX, rightY, leftPupil, rightPupil);
            end
        end

        function sample = floatSampleToTobii(obj, item)
            % Convert one buffered EyeLink sample struct into legacy shape.
            timeMs = obj.cleanMissing(item.time);

            leftX = NaN;
            rightX = NaN;
            leftY = NaN;
            rightY = NaN;
            leftPupil = 0;
            rightPupil = 0;

            if isfield(item, 'gx') && numel(item.gx) >= 2
                leftX = obj.cleanMissing(item.gx(1));
                rightX = obj.cleanMissing(item.gx(2));
            end

            if isfield(item, 'gy') && numel(item.gy) >= 2
                leftY = obj.cleanMissing(item.gy(1));
                rightY = obj.cleanMissing(item.gy(2));
            end

            if isfield(item, 'pa') && numel(item.pa) >= 2
                leftPupil = obj.cleanPupil(item.pa(1));
                rightPupil = obj.cleanPupil(item.pa(2));
            end

            sample = obj.makeSample(timeMs, leftX, leftY, rightX, rightY, leftPupil, rightPupil);
        end

        function sample = makeSample(obj, timeMs, leftX, leftY, rightX, rightY, leftPupil, rightPupil)
            % Build one Tobii-shaped sample struct from EyeLink sample values.
            [gazeX, gazeY, canonicalPupil] = obj.selectCanonicalGazePoint( ...
                leftX, leftY, rightX, rightY, leftPupil, rightPupil);
            canonicalPoint = obj.normalizePoint(gazeX, gazeY);
            rightPoint = obj.normalizePoint(rightX, rightY);

            leftValid = all(isfinite(canonicalPoint)) && canonicalPupil > 0;
            rightValid = all(isfinite(rightPoint)) && rightPupil > 0;

            sample = struct( ...
                'SystemTimeStamp', GetSecs * 1e6, ...
                'DeviceTimeStamp', timeMs * 1000, ...
                'LeftEye', struct( ...
                    'GazePoint', struct('OnDisplayArea', canonicalPoint), ...
                    'Pupil', struct('Diameter', canonicalPupil), ...
                    'Validity', double(leftValid)), ...
                'RightEye', struct( ...
                    'GazePoint', struct('OnDisplayArea', rightPoint), ...
                    'Pupil', struct('Diameter', rightPupil), ...
                    'Validity', double(rightValid)) ...
                );
        end

        function [x, y, pupil] = selectCanonicalGazePoint(obj, leftX, leftY, rightX, rightY, leftPupil, rightPupil)
            leftValid = obj.isOnScreenPoint(leftX, leftY);
            rightValid = obj.isOnScreenPoint(rightX, rightY);

            if leftValid && rightValid
                x = (leftX + rightX) / 2;
                y = (leftY + rightY) / 2;
                if leftPupil > 0 && rightPupil > 0
                    pupil = (leftPupil + rightPupil) / 2;
                elseif leftPupil > 0
                    pupil = leftPupil;
                elseif rightPupil > 0
                    pupil = rightPupil;
                else
                    pupil = 0;
                end
                return;
            end

            if leftValid
                x = leftX;
                y = leftY;
                pupil = leftPupil;
                return;
            end

            if rightValid
                x = rightX;
                y = rightY;
                pupil = rightPupil;
                return;
            end

            x = NaN;
            y = NaN;
            pupil = 0;
        end

        function point = normalizePoint(obj, x, y)
            % Convert EyeLink display pixels to normalized display coordinates.
            if ~obj.isOnScreenPoint(x, y)
                point = [NaN, NaN];
                return;
            end

            point = [x / max(obj.ScreenWidth - 1, 1), y / max(obj.ScreenHeight - 1, 1)];
        end

        function tf = isOnScreenPoint(obj, x, y)
            tf = isfinite(x) && isfinite(y) && ...
                x >= 0 && x < obj.ScreenWidth && ...
                y >= 0 && y < obj.ScreenHeight;
        end

        function value = cleanMissing(obj, value)
            % Convert EyeLink missing-data sentinel values to NaN.
            if isempty(value) || isnan(value) || value <= obj.MissingData
                value = NaN;
            end
        end

        function value = cleanPupil(obj, value)
            % Keep missing pupil as zero for compatibility with loss metrics.
            value = obj.cleanMissing(value);
            if isnan(value)
                value = 0;
            end
        end

        function sample = emptySample(obj)
            % Return an empty sample with the same field layout as real samples.
            sample = obj.makeSample(NaN, NaN, NaN, NaN, NaN, 0, 0);
        end

        function receiveFile(obj)
            % Copy the EDF from the tracker host into the subject eyeData folder.
            if isempty(obj.EdfFileName) || isempty(obj.LocalEdfPath)
                return;
            end

            edfFileName = char(obj.EdfFileName);
            destDir = char(fileparts(obj.LocalEdfPath));
            if ~exist(destDir, 'dir')
                mkdir(destDir);
            end

            status = Eyelink('ReceiveFile', edfFileName, destDir, 1);
            if isempty(status)
                status = 0;
            end

            if isnumeric(status) && status < 0
                error('EyeLinkTobiiCompat:ReceiveFileFailed', ...
                    'EyeLink ReceiveFile failed for %s into %s. Status: %d.', ...
                    edfFileName, destDir, status);
            end

            if ~exist(obj.LocalEdfPath, 'file')
                warning('EyeLinkTobiiCompat:ReceiveFileMissing', ...
                    'EyeLink ReceiveFile returned status %s, but expected EDF was not found at %s.', ...
                    mat2str(status), obj.LocalEdfPath);
            end
        end
    end
end

function versionText = getPsychtoolboxVersion()
% Return a short PTB version string for experiment logs.
try
    versionText = PsychtoolboxVersion;
catch
    versionText = 'Psychtoolbox EyeLink Toolbox';
end
end

function versionText = getTrackerVersion()
% Return tracker/runtime version text when the EyeLink API provides it.
try
    versionText = Eyelink('GetTrackerVersionString');
catch
    versionText = 'unknown';
end
end
