function [ok, response] = sendOBSTrigger(action, varargin)
%SENDOBSTRIGGER Send a start/stop recording request to OBS WebSocket v5.
%
% action accepts 'StartRecording', 'StopRecording', or 'SetRecordDirectory'.
% OBS must have the built-in WebSocket server enabled. Password authentication
% uses the OBS_WEBSOCKET_PASSWORD environment variable when OBS requests it.

ok = false;
response = [];
opts = parseOptions(varargin{:});

try
    requestType = normalizeOBSRequest(action);
    validateRemoteOBSConfig(opts);
    if strcmp(requestType, 'SetRecordDirectory')
        opts.RecordDirectory = resolveRecordDirectory(opts);
    end
    client = tcpclient(opts.Host, opts.Port, 'Timeout', opts.TimeoutSec);
    cleanupClient = onCleanup(@() closeClient(client)); %#ok<NASGU>

    openWebSocket(client, opts);
    identifyWithOBS(client, opts);
    response = sendOBSRequest(client, requestType, opts.TimeoutSec, opts.RecordDirectory);
    ok = true;

    fprintf('[OBS] %s succeeded.\n', requestType);
catch ME
    warning('sendOBSTrigger:CommunicationFailed', ...
        'Could not communicate with OBS: %s', ME.message);
end
end


function opts = parseOptions(varargin)
opts = struct();

% One-time OBS WebSocket configuration. Keep SaveDir empty for local OBS;
% the caller will provide the subject-specific data/<subjID>/obsData path.
% For a remote OBS host, set SaveDir to an absolute, existing, writable path
% as seen by the remote OBS process. Remote hosts also require the
% OBS_WEBSOCKET_PASSWORD environment variable to be non-empty.
opts.Host = '10.131.115.199';
opts.Port = 4455;
opts.SaveDir = 'C:\Users\neuro\Desktop\obsData'; % when opts.Host is not localhost, this is required
opts.Password = '1357924680'; % when opts.Host is not localhost, this is required
opts.TimeoutSec = 2;
opts.RecordDirectory = '';

if mod(numel(varargin), 2) ~= 0
    error('sendOBSTrigger:InvalidOptions', 'Options must be name-value pairs.');
end

for idx = 1:2:numel(varargin)
    name = lower(strtrim(char(varargin{idx})));
    value = varargin{idx + 1};

    switch name
        case {'host', 'ip', 'obsip'}
            opts.Host = char(value);
        case {'port', 'obsport'}
            opts.Port = double(value);
        case {'timeout', 'timeoutsec'}
            opts.TimeoutSec = double(value);
        case {'recorddirectory', 'directory', 'dir'}
            opts.RecordDirectory = char(value);
        otherwise
            error('sendOBSTrigger:UnknownOption', 'Unknown option: %s', name);
    end
end
end


function validateRemoteOBSConfig(opts)
if ~isLocalOBSHost(opts.Host) && isempty(opts.Password)
    error('sendOBSTrigger:MissingRemotePassword', ...
        'Set the OBS_WEBSOCKET_PASSWORD environment variable for a remote OBS host.');
end
end


function recordDirectory = resolveRecordDirectory(opts)
% Local OBS can use the subject-specific directory created by MATLAB.
if isLocalOBSHost(opts.Host)
    recordDirectory = opts.RecordDirectory;
    return;
end

% A remote OBS process cannot use a path created on the MATLAB host.
if isempty(strtrim(opts.SaveDir))
    error('sendOBSTrigger:MissingRemoteSaveDir', ...
        ['Set opts.SaveDir to an absolute, existing, writable directory ' ...
         'on the remote OBS host.']);
end

recordDirectory = opts.SaveDir;
end


function tf = isLocalOBSHost(host)
host = lower(strtrim(char(host)));
tf = any(strcmp(host, {'127.0.0.1', 'localhost', '::1'}));
end


function requestType = normalizeOBSRequest(action)
if isstring(action)
    action = char(action);
end

if ~ischar(action) || isempty(strtrim(action))
    error('sendOBSTrigger:InvalidAction', 'OBS action must be a non-empty string.');
end

switch lower(strtrim(action))
    case {'startrecording', 'startrecord', 'start', 'start_recording'}
        requestType = 'StartRecord';
    case {'stoprecording', 'stoprecord', 'stop', 'stop_recording'}
        requestType = 'StopRecord';
    case {'setrecorddirectory', 'recorddirectory', 'set_record_directory'}
        requestType = 'SetRecordDirectory';
    otherwise
        error('sendOBSTrigger:InvalidAction', ...
            'Unsupported OBS action: %s. Use StartRecording, StopRecording, or SetRecordDirectory.', action);
end
end


function openWebSocket(client, opts)
webSocketKey = base64Encode(uint8(randi([0 255], 1, 16)));
request = sprintf(['GET / HTTP/1.1\r\n' ...
    'Host: %s:%d\r\n' ...
    'Upgrade: websocket\r\n' ...
    'Connection: Upgrade\r\n' ...
    'Sec-WebSocket-Key: %s\r\n' ...
    'Sec-WebSocket-Version: 13\r\n\r\n'], ...
    opts.Host, opts.Port, webSocketKey);

write(client, unicode2native(request, 'UTF-8'), 'uint8');

responseBytes = uint8([]);
timerStart = tic;
while ~contains(char(responseBytes), sprintf('\r\n\r\n'))
    if client.NumBytesAvailable > 0
        responseBytes = [responseBytes read(client, 1, 'uint8')]; %#ok<AGROW>
    elseif toc(timerStart) > opts.TimeoutSec
        error('sendOBSTrigger:HandshakeTimeout', 'Timed out waiting for OBS WebSocket handshake.');
    else
        pause(0.01);
    end
end

responseText = native2unicode(responseBytes, 'UTF-8');
if isempty(regexp(responseText, '^HTTP/1\.[01] 101', 'once'))
    firstLine = regexp(responseText, '^.*', 'match', 'once');
    error('sendOBSTrigger:HandshakeRejected', ...
        'OBS rejected the WebSocket handshake: %s', firstLine);
end
end


function identifyWithOBS(client, opts)
hello = readWebSocketJson(client, opts.TimeoutSec);
if ~isfield(hello, 'op') || double(hello.op) ~= 0
    error('sendOBSTrigger:UnexpectedHello', 'OBS did not send the expected Hello message.');
end

helloData = getStructField(hello, 'd', struct());
rpcVersion = getStructField(helloData, 'rpcVersion', 1);
identifyData = struct('rpcVersion', double(rpcVersion), 'eventSubscriptions', 0);

authentication = getStructField(helloData, 'authentication', []);
if isstruct(authentication) && ~isempty(fieldnames(authentication))
    if isempty(opts.Password)
        error('sendOBSTrigger:MissingPassword', ...
            'OBS requires authentication. Set the OBS_WEBSOCKET_PASSWORD environment variable.');
    end

    salt = getStructField(authentication, 'salt', '');
    challenge = getStructField(authentication, 'challenge', '');
    if isempty(salt) || isempty(challenge)
        error('sendOBSTrigger:InvalidAuthenticationChallenge', ...
            'OBS authentication data must include both salt and challenge.');
    end

    identifyData.authentication = buildOBSAuthentication(opts.Password, salt, challenge);
end

sendWebSocketJson(client, struct('op', 1, 'd', identifyData));

identified = false;
timerStart = tic;
while ~identified
    if toc(timerStart) > opts.TimeoutSec
        error('sendOBSTrigger:IdentifyTimeout', 'Timed out waiting for OBS Identified message.');
    end

    message = readWebSocketJson(client, opts.TimeoutSec);
    if isfield(message, 'op') && double(message.op) == 2
        identified = true;
    end
end
end


function response = sendOBSRequest(client, requestType, timeoutSec, recordDirectory)
requestId = sprintf('%s_%s_%06d', requestType, datestr(now, 'yyyymmddTHHMMSSFFF'), randi(999999));
requestData = struct('requestType', requestType, 'requestId', requestId);
if strcmp(requestType, 'SetRecordDirectory')
    if isempty(recordDirectory)
        error('sendOBSTrigger:MissingRecordDirectory', 'SetRecordDirectory requires a recordDirectory value.');
    end
    requestData.requestData = struct('recordDirectory', recordDirectory);
end
sendWebSocketJson(client, struct('op', 6, 'd', requestData));

timerStart = tic;
while true
    if toc(timerStart) > timeoutSec
        error('sendOBSTrigger:RequestTimeout', 'Timed out waiting for OBS %s response.', requestType);
    end

    response = readWebSocketJson(client, timeoutSec);
    if ~isfield(response, 'op') || double(response.op) ~= 7
        continue;
    end

    responseData = getStructField(response, 'd', struct());
    if ~strcmp(getStructField(responseData, 'requestId', ''), requestId)
        continue;
    end

    status = getStructField(responseData, 'requestStatus', struct());
    if ~getStructField(status, 'result', false)
        code = getStructField(status, 'code', NaN);
        comment = getStructField(status, 'comment', 'No OBS status comment.');
        error('sendOBSTrigger:RequestFailed', ...
            'OBS %s failed with code %.0f: %s', requestType, code, comment);
    end
    return;
end
end


function sendWebSocketJson(client, payloadStruct)
jsonText = jsonencode(payloadStruct);
sendWebSocketFrame(client, unicode2native(jsonText, 'UTF-8'), 1);
end


function message = readWebSocketJson(client, timeoutSec)
while true
    [opcode, payload] = readWebSocketFrame(client, timeoutSec);
    switch opcode
        case 1
            message = jsondecode(native2unicode(payload, 'UTF-8'));
            return;
        case 8
            error('sendOBSTrigger:WebSocketClosed', 'OBS closed the WebSocket connection.');
        case 9
            sendWebSocketFrame(client, payload, 10);
        otherwise
            % Ignore binary, pong, and continuation frames; OBS messages are JSON text.
    end
end
end


function sendWebSocketFrame(client, payload, opcode)
payload = uint8(payload);
payloadLength = numel(payload);

if payloadLength < 126
    header = uint8([128 + opcode, 128 + payloadLength]);
elseif payloadLength <= 65535
    header = uint8([128 + opcode, 128 + 126, floor(payloadLength / 256), mod(payloadLength, 256)]);
else
    error('sendOBSTrigger:PayloadTooLarge', 'WebSocket payload is too large.');
end

maskKey = uint8(randi([0 255], 1, 4));
maskedPayload = payload;
for idx = 1:payloadLength
    maskedPayload(idx) = bitxor(payload(idx), maskKey(mod(idx - 1, 4) + 1));
end

write(client, [header maskKey maskedPayload], 'uint8');
end


function [opcode, payload] = readWebSocketFrame(client, timeoutSec)
header = readExact(client, 2, timeoutSec);
firstByte = double(header(1));
secondByte = double(header(2));

opcode = bitand(firstByte, 15);
payloadLength = bitand(secondByte, 127);

if payloadLength == 126
    extended = readExact(client, 2, timeoutSec);
    payloadLength = double(extended(1)) * 256 + double(extended(2));
elseif payloadLength == 127
    extended = readExact(client, 8, timeoutSec);
    payloadLength = 0;
    for idx = 1:8
        payloadLength = payloadLength * 256 + double(extended(idx));
    end
end

isMasked = bitand(secondByte, 128) ~= 0;
maskKey = uint8([]);
if isMasked
    maskKey = readExact(client, 4, timeoutSec);
end

payload = readExact(client, payloadLength, timeoutSec);
if isMasked
    for idx = 1:payloadLength
        payload(idx) = bitxor(payload(idx), maskKey(mod(idx - 1, 4) + 1));
    end
end
end


function bytes = readExact(client, byteCount, timeoutSec)
bytes = uint8([]);
timerStart = tic;

while numel(bytes) < byteCount
    available = client.NumBytesAvailable;
    if available > 0
        bytesNeeded = byteCount - numel(bytes);
        bytes = [bytes read(client, min(bytesNeeded, available), 'uint8')]; %#ok<AGROW>
    elseif toc(timerStart) > timeoutSec
        error('sendOBSTrigger:ReadTimeout', 'Timed out reading from OBS WebSocket.');
    else
        pause(0.005);
    end
end

bytes = uint8(bytes(:).');
end


function encoded = base64Encode(bytes)
encoder = javaMethod('getEncoder', 'java.util.Base64');
encoded = char(encoder.encodeToString(typecast(uint8(bytes(:)), 'int8')));
end


function authentication = buildOBSAuthentication(password, salt, challenge)
secret = base64Encode(sha256Bytes([char(password) char(salt)]));
authentication = base64Encode(sha256Bytes([secret char(challenge)]));
end


function hashBytes = sha256Bytes(text)
digest = javaMethod('getInstance', 'java.security.MessageDigest', 'SHA-256');
textBytes = unicode2native(char(text), 'UTF-8');
signedHash = digest.digest(typecast(uint8(textBytes(:)), 'int8'));
hashBytes = typecast(int8(signedHash(:)), 'uint8');
end


function value = getStructField(inputStruct, fieldName, defaultValue)
if isstruct(inputStruct) && isfield(inputStruct, fieldName)
    value = inputStruct.(fieldName);
else
    value = defaultValue;
end
end


function closeClient(client)
try
    sendWebSocketFrame(client, uint8([]), 8);
catch
end
end
