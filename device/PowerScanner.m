classdef PowerScanner < handle
    %POWERSCANNER  B210 한 대를 열어 두고 20 MHz 채널의 수신 전력을 잰다 (수신 전용).
    %   scanner = PowerScanner                    연결된 USRP 를 자동으로 찾음
    %   scanner = PowerScanner(SerialNum="321D838", Gain=30)
    %   scanner = PowerScanner(SerialNum="321D838", Platform="B210")   이미 찾은 기기는 탐색 생략
    %   power = scanner.measure(36)               ch36 의 전력 (channelPower 참고)
    %   PowerScanner.list()                       연결된 USRP 목록
    %   PowerScanner.usbLinks()                   USRP 별 USB 링크 속도 (bit/s)
    %
    %   수신기는 처음 잴 때 한 번만 열고(4~5초), 이후에는 중심 주파수만 바꾼다.

    properties (SetAccess = private)
        Platform  (1,1) string
        SerialNum (1,1) string
        Gain      (1,1) double
        Reopens   (1,1) double = 0   % 유실(overflow)로 수신기를 다시 연 횟수
    end

    properties (Access = private)
        Rx = []
        NumFrames (1,1) double
    end

    properties (Constant)
        SampleRate      = 20e6
        SamplesPerFrame = 200000
        UsbSuperSpeed   = 5e9
    end

    properties (Constant, Access = private)
        MaxAttempts   = 3
        MaxEmptyReads = 200
        EttusVendorId = 9472   % 0x2500
    end

    methods
        function obj = PowerScanner(opts)
            arguments
                opts.SerialNum (1,1) string = ""
                opts.Platform  (1,1) string = ""
                opts.Gain      (1,1) double {mustBeInRange(opts.Gain, 0, 76)} = 30
                opts.Duration  (1,1) duration = milliseconds(20)   % 채널 하나를 재는 길이
            end
            if opts.SerialNum ~= "" && opts.Platform ~= ""
                obj.Platform  = opts.Platform;
                obj.SerialNum = opts.SerialNum;
            else
                found = PowerScanner.list();
                found = found(found.Status == "Success", :);
                assert(~isempty(found), 'SSOM:NoRadio', '연결된 USRP 를 찾지 못했습니다.');
                if opts.SerialNum == ""
                    row = 1;
                else
                    row = find(found.SerialNum == opts.SerialNum, 1);
                    assert(~isempty(row), 'SSOM:NoRadio', '시리얼 %s 인 USRP 를 찾지 못했습니다.', opts.SerialNum);
                end
                obj.Platform  = found.Platform(row);
                obj.SerialNum = found.SerialNum(row);
            end
            obj.Gain      = opts.Gain;
            % 튜닝 직후 과도 구간인 첫 프레임은 버리므로 한 프레임 더 받는다
            obj.NumFrames = ceil(seconds(opts.Duration) * obj.SampleRate / obj.SamplesPerFrame) + 1;
        end

        function power = measure(obj, channel)
            %MEASURE  채널 하나로 튜닝해 전력을 잰다. 유실이 나면 수신기를 새로 열어 다시 잰다.
            arguments
                obj
                channel (1,1) double {mustBeInteger, mustBePositive}
            end
            centerFreqHz = (5000 + 5 * channel) * 1e6;
            for attempt = 1:obj.MaxAttempts
                try
                    if isempty(obj.Rx)
                        obj.open(centerFreqHz);
                    end
                    obj.Rx.CenterFrequency = centerFreqHz;
                    raw = obj.readBurst();
                    break
                catch err
                    % 유실 뒤 같은 객체로 계속 받으면 데이터가 어긋나므로 닫고 새로 연다
                    obj.close();
                    if attempt == obj.MaxAttempts || ~contains(err.message, "overflow", IgnoreCase=true)
                        error('SSOM:CaptureFailed', 'ch%d 수신 실패 (%d회 시도): %s', ...
                            channel, attempt, err.message);
                    end
                    obj.Reopens = obj.Reopens + 1;
                end
            end
            power = channelPower(raw(obj.SamplesPerFrame + 1:end));
        end

        function setGain(obj, gain)
            arguments
                obj
                gain (1,1) double {mustBeInRange(gain, 0, 76)}
            end
            obj.Gain = gain;
            if ~isempty(obj.Rx)
                obj.Rx.Gain = gain;
            end
        end

        function close(obj)
            if ~isempty(obj.Rx)
                release(obj.Rx);
                obj.Rx = [];
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Access = private)
        function open(obj, centerFreqHz)
            obj.Rx = comm.SDRuReceiver( ...
                'Platform', obj.Platform, ...
                'SerialNum', obj.SerialNum, ...
                'CenterFrequency', centerFreqHz, ...
                'MasterClockRate', obj.SampleRate, ...
                'DecimationFactor', 1, ...
                'Gain', obj.Gain, ...
                'SamplesPerFrame', obj.SamplesPerFrame, ...
                'OutputDataType', 'Same as transport data type', ...
                'EnableBurstMode', true, ...        % 버스트 한 번에 연속 수신해 유실 방지
                'NumFramesInBurst', obj.NumFrames);
        end

        function raw = readBurst(obj)
            % 버스트 하나를 받아 int16 열 벡터로 반환한다.
            raw = complex(zeros(obj.NumFrames * obj.SamplesPerFrame, 1, 'int16'));
            k = 0;
            emptyReads = 0;
            while k < obj.NumFrames
                [data, len, overflow] = obj.Rx();
                if overflow
                    error('SSOM:Overflow', 'Overflow: 수신 샘플이 유실되었습니다.');
                end
                if len > 0
                    raw(k * obj.SamplesPerFrame + (1:obj.SamplesPerFrame)) = data;
                    k = k + 1;
                else
                    emptyReads = emptyReads + 1;
                    assert(emptyReads < obj.MaxEmptyReads, 'SSOM:NoData', 'USRP 에서 샘플이 오지 않습니다.');
                end
            end
        end
    end

    methods (Static)
        function found = list()
            %LIST  연결된 USRP 를 표로 반환한다.
            [~, info] = evalc("findsdru");   % findsdru 의 UHD 로그 숨김
            info = info(~cellfun(@isempty, {info.SerialNum}));
            found = table(string({info.Platform})', string({info.SerialNum})', string({info.Status})', ...
                'VariableNames', ["Platform", "SerialNum", "Status"]);
        end

        function links = usbLinks()
            %USBLINKS  연결된 USRP 의 시리얼과 USB 링크 속도(bit/s) 표. USB 3.0 이면 5e9.
            %   USB 2.0 허브를 거치면 480e6 이 되고 20 MS/s 에서 overflow 로 수신이 안 된다.
            %   macOS 가 아니거나 장치를 못 찾으면 빈 표를 반환한다.
            links = table(strings(0, 1), zeros(0, 1), 'VariableNames', ["SerialNum", "LinkSpeed"]);
            if ~ismac
                return
            end
            [status, text] = system("ioreg -p IOUSB -l -w0");
            if status ~= 0
                return
            end
            devices = regexp(text, '\+-o ', 'split');   % 장치마다 "+-o 이름" 으로 시작
            for k = 1:numel(devices)
                if isempty(regexp(devices{k}, sprintf('"idVendor" = %d\\s', PowerScanner.EttusVendorId), 'once'))
                    continue
                end
                speed = regexp(devices{k}, '"UsbLinkSpeed" = (\d+)', 'tokens', 'once');
                serial = regexp(devices{k}, '"kUSBSerialNumberString" = "([^"]*)"', 'tokens', 'once');
                if ~isempty(speed) && ~isempty(serial)
                    links(end + 1, :) = {string(serial{1}), str2double(speed{1})}; %#ok<AGROW>
                end
            end
        end
    end
end
