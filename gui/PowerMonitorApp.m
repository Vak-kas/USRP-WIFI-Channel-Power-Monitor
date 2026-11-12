classdef PowerMonitorApp < handle
    %POWERMONITORAPP  운용 대역의 20 MHz 채널별 수신 전력을 계속 재서 보여 주는 창.
    %   app = PowerMonitorApp                                  P20 ch40, 160 MHz, 타깃 ch36/ch44
    %   app = PowerMonitorApp(Primary=40, WidthMHz=160, Targets=[36 44], Gain=30)
    %
    %   '시작' 을 누르면 대역을 반복해서 훑는다. 송신 전에 '기준값 저장' 을 눌러 두면
    %   이후에는 채널별 증가량(dB)이 함께 표시된다.
    %   표시값은 최근 5바퀴의 중앙값이라 변화가 몇 초 늦게 반영된다.
    %   값은 보정 안 된 상대값(dBFS)이며 dBm 이 아니다.

    properties (SetAccess = private)
        Channels (1,:) double           % 운용 대역의 20 MHz 채널
        Primary  (1,1) double
        Targets  (1,:) double
        Levels   (:,2) double           % 채널별 표시 전력 [평균, 중앙값] (dBFS). 최근 몇 바퀴의 중앙값
        Baseline (:,2) double           % 저장한 기준값. 없으면 NaN
    end

    properties (Access = private)
        Scanner = []
        Recent  (:,2,:) double          % 채널별 최근 몇 바퀴의 측정값
        PeakDb  (:,1) double
        BaselineTime = NaT
        Sweeps   (1,1) double = 0
        SweepS   (1,1) double = NaN
        BandId   (1,1) double = 0       % 대역이 바뀔 때마다 증가. 훑는 도중 바뀐 것을 알아챈다
        Running  (1,1) logical = false
        Busy     (1,1) logical = false
        Closing  (1,1) logical = false

        Fig
        WidthDrop
        PrimaryDrop
        TargetField
        GainField
        StatDrop
        StartButton
        SaveButton
        ClearButton
        LevelAxes
        RiseAxes
        Table
        StatusLabel
    end

    properties (Constant, Access = private)
        Channels5GHz = [36:4:64, 100:4:144, 149:4:165]
        Widths       = [20 40 80 160]
        StatNames    = ["중앙값 (계속 나오는 신호)", "평균 (Wi-Fi 프레임 포함)"]
        StatColumn   = [2 1]            % StatNames 순서에 해당하는 Levels 열
        SmoothSweeps = 5                % 표시값에 쓰는 최근 바퀴 수. 주변 Wi-Fi 트래픽이
                                        % 한두 바퀴 튀는 것을 걸러 낸다
        ClipDb       = -1               % 최대 샘플이 이보다 크면 포화로 본다
        ColorPrimary = [0.30 0.69 0.31]
        ColorTarget  = [0.90 0.30 0.25]
        ColorIdle    = [0.70 0.70 0.70]
    end

    methods
        % ========== 생성 함수 ==========
        function obj = PowerMonitorApp(opts)
            arguments
                opts.Primary  (1,1) double = 40
                opts.WidthMHz (1,1) double = 160
                opts.Targets  (1,:) double = [36 44]
                opts.Gain     (1,1) double = 30
            end
            rootDir = fileparts(fileparts(mfilename("fullpath")));
            addpath(fullfile(rootDir, "device"), fullfile(rootDir, "measure"));

            obj.Primary = opts.Primary;
            obj.Targets = opts.Targets;
            obj.setBand(bandChannels(opts.Primary, opts.WidthMHz));
            obj.buildUi(opts.WidthMHz, opts.Gain);
            obj.redraw();
            obj.checkUsb();
        end

        % ========== 창 닫기 함수 ==========
        function delete(obj)
            if ~isempty(obj.Scanner)
                delete(obj.Scanner);
            end
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
        end
    end

    methods (Access = private)
        % ========== 화면 구성 함수 ==========
        function buildUi(obj, widthMHz, gain)
            obj.Fig = uifigure('Name', '5 GHz 채널별 수신 전력', 'Position', [100 100 980 760], ...
                'CloseRequestFcn', @(~, ~) obj.onClose());
            grid = uigridlayout(obj.Fig, [5 1]);
            grid.RowHeight = {60, '1x', '1x', 220, 24};

            controls = uigridlayout(grid, [2 8]);
            controls.RowHeight = {18, 26};
            controls.ColumnWidth = {95, 80, 90, 70, '1x', 80, 100, 100};
            controls.Padding = [0 0 0 0];
            titles = ["대역폭", "P20", "타깃 채널", "수신 Gain", "전력 계산", "", "", ""];
            for k = 1:numel(titles)
                label = uilabel(controls, 'Text', titles(k));
                label.Layout.Row = 1;
                label.Layout.Column = k;
            end

            obj.WidthDrop = uidropdown(controls, 'Items', obj.Widths + " MHz", 'ItemsData', obj.Widths, ...
                'Value', widthMHz, 'ValueChangedFcn', @(~, event) obj.onBandChanged(event));
            obj.PrimaryDrop = uidropdown(controls, 'Items', "ch" + obj.Channels5GHz, ...
                'ItemsData', obj.Channels5GHz, 'Value', obj.Primary, ...
                'ValueChangedFcn', @(~, event) obj.onBandChanged(event));
            obj.TargetField = uieditfield(controls, 'text', 'Value', char(join(string(obj.Targets), " ")), ...
                'Tooltip', '올라가야 하는 채널 번호를 띄어 써서 입력 (예: 36 44)', ...
                'ValueChangedFcn', @(~, ~) obj.onTargetsChanged());
            obj.GainField = uispinner(controls, 'Limits', [0 76], 'Step', 5, 'Value', gain, ...
                'ValueChangedFcn', @(~, ~) obj.onGainChanged());
            obj.StatDrop = uidropdown(controls, 'Items', obj.StatNames, 'ItemsData', obj.StatColumn, ...
                'ValueChangedFcn', @(~, ~) obj.redraw());
            obj.StartButton = uibutton(controls, 'Text', '시작', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) obj.onStartStop());
            obj.SaveButton = uibutton(controls, 'Text', '기준값 저장', ...
                'Tooltip', '송신 전 상태를 저장한다. 이후 채널별 증가량이 표시된다.', ...
                'ButtonPushedFcn', @(~, ~) obj.onSaveBaseline());
            obj.ClearButton = uibutton(controls, 'Text', '기준값 지우기', ...
                'ButtonPushedFcn', @(~, ~) obj.onClearBaseline());
            row = [obj.WidthDrop, obj.PrimaryDrop, obj.TargetField, obj.GainField, ...
                obj.StatDrop, obj.StartButton, obj.SaveButton, obj.ClearButton];
            for k = 1:numel(row)
                item = row(k);
                item.Layout.Row = 2;
                item.Layout.Column = k;
            end

            obj.LevelAxes = uiaxes(grid);
            obj.RiseAxes = uiaxes(grid);
            obj.Table = uitable(grid, 'ColumnName', ...
                ["채널", "중심 주파수 (MHz)", "구분", "현재 (dBFS)", "기준값 (dBFS)", "증가량 (dB)", "최대 샘플 (dBFS)"], ...
                'RowName', {});
            obj.StatusLabel = uilabel(grid, 'Text', "'시작' 을 누르면 측정을 시작합니다.");
        end

        % ========== 대역 설정 함수 ==========
        function setBand(obj, channels)
            % 대역이 바뀌면 이전 측정값과 기준값은 채널이 맞지 않으므로 모두 비운다
            obj.Channels = channels;
            n = numel(channels);
            obj.Levels   = nan(n, 2);
            obj.Baseline = nan(n, 2);
            obj.Recent   = nan(n, 2, obj.SmoothSweeps);
            obj.PeakDb   = nan(n, 1);
            obj.BaselineTime = NaT;
            obj.BandId = obj.BandId + 1;
        end

        function onBandChanged(obj, event)
            try
                channels = bandChannels(obj.PrimaryDrop.Value, obj.WidthDrop.Value);
            catch err
                event.Source.Value = event.PreviousValue;
                uialert(obj.Fig, err.message, '대역 설정');
                return
            end
            obj.Primary = obj.PrimaryDrop.Value;
            if ~isequal(channels, obj.Channels)
                obj.setBand(channels);
            end
            obj.redraw();
        end

        function onTargetsChanged(obj)
            obj.Targets = unique(str2double(regexp(obj.TargetField.Value, '\d+', 'match')));
            obj.redraw();
        end

        function onGainChanged(obj)
            if ~isempty(obj.Scanner)
                obj.Scanner.setGain(obj.GainField.Value);
            end
            if ~isnat(obj.BaselineTime)
                % Gain 이 다르면 같은 신호도 다른 값으로 잡히므로 기준값을 다시 잡아야 한다
                obj.clearBaseline();
                obj.setStatus("Gain 을 바꿔 기준값을 지웠습니다. 송신 전 상태에서 다시 저장하세요.");
            end
            obj.Recent(:) = NaN;   % Gain 이 다른 측정값이 섞이지 않게 비운다
            obj.Levels(:) = NaN;
            obj.redraw();
        end

        % ========== 측정 함수 ==========
        function onStartStop(obj)
            if obj.Running
                obj.Running = false;   % 재고 있던 채널이 끝나면 멈춘다
                return
            end
            if ~obj.checkUsb()
                return
            end
            obj.Running = true;
            obj.Busy = true;
            obj.StartButton.Text = '정지';
            try
                if isempty(obj.Scanner)
                    obj.setStatus("USRP 를 찾는 중...");
                    drawnow;
                    obj.Scanner = PowerScanner(Gain=obj.GainField.Value);
                end
                obj.setStatus("수신기를 여는 중... (4~5초)");
                drawnow;
                obj.sweepLoop();
                if isvalid(obj) && ~obj.Closing
                    obj.setStatus("정지했습니다.");
                end
            catch err
                if isvalid(obj) && ~obj.Closing
                    obj.setStatus("오류: " + err.message);
                    uialert(obj.Fig, err.message, '측정 실패');
                end
            end
            if ~isvalid(obj)
                return
            end
            obj.Running = false;
            obj.Busy = false;
            if obj.Closing
                delete(obj);
                return
            end
            if ~isempty(obj.Scanner)
                obj.Scanner.close();   % 멈춘 동안에는 USRP 를 놓아 준다
            end
            obj.StartButton.Text = '시작';
        end

        function sweepLoop(obj)
            while obj.Running
                bandId = obj.BandId;
                channels = obj.Channels;
                started = tic;
                for k = 1:numel(channels)
                    power = obj.Scanner.measure(channels(k));
                    drawnow;   % 버튼 입력을 처리한다. 이때 대역이 바뀌거나 창이 닫힐 수 있다
                    if ~isvalid(obj) || ~obj.Running || obj.BandId ~= bandId
                        break
                    end
                    obj.Recent(k, :, :) = cat(3, obj.Recent(k, :, 2:end), [power.MeanDb, power.MedianDb]);
                    obj.Levels(k, :) = median(obj.Recent(k, :, :), 3, 'omitnan');
                    obj.PeakDb(k) = power.PeakDb;
                    if k == numel(channels)
                        obj.Sweeps = obj.Sweeps + 1;
                        obj.SweepS = toc(started);
                    end
                    obj.redraw();
                    obj.showProgress();
                end
                if ~isvalid(obj)
                    return
                end
            end
        end

        % ========== 기준값 함수 ==========
        function onSaveBaseline(obj)
            if any(isnan(obj.Recent), 'all')
                obj.setStatus(sprintf("%d바퀴를 다 잰 뒤에 기준값을 저장할 수 있습니다.", obj.SmoothSweeps));
                return
            end
            obj.Baseline = obj.Levels;
            obj.BaselineTime = datetime("now");
            obj.redraw();
            obj.setStatus("지금 표시된 값을 기준값으로 저장했습니다.");
        end

        function onClearBaseline(obj)
            obj.clearBaseline();
            obj.redraw();
        end

        function clearBaseline(obj)
            obj.Baseline = nan(numel(obj.Channels), 2);
            obj.BaselineTime = NaT;
        end

        % ========== 화면 갱신 함수 ==========
        function redraw(obj)
            column = obj.StatDrop.Value;
            n = numel(obj.Channels);
            level = obj.Levels(:, column);
            base = obj.Baseline(:, column);
            rise = level - base;
            hasBaseline = ~isnat(obj.BaselineTime);

            isPrimary = obj.Channels == obj.Primary;
            isTarget = ismember(obj.Channels, obj.Targets) & ~isPrimary;
            colors = repmat(obj.ColorIdle, n, 1);
            colors(isTarget, :) = repmat(obj.ColorTarget, nnz(isTarget), 1);
            colors(isPrimary, :) = repmat(obj.ColorPrimary, nnz(isPrimary), 1);
            roles = repmat("", 1, n);
            roles(isTarget) = "타깃";
            roles(isPrimary) = "P20";
            ticks = "ch" + obj.Channels;
            ticks(roles ~= "") = ticks(roles ~= "") + "\newline" + roles(roles ~= "");

            % 현재 전력 막대
            ax = obj.LevelAxes;
            cla(ax);
            known = [level; base];
            known = known(isfinite(known));
            if isempty(known)
                limits = [-80 -20];
            else
                limits = [floor(min(known) / 10) * 10 - 10, ceil(max(known) / 10) * 10 + 10];
            end
            bar(ax, 1:n, level, 0.7, 'FaceColor', 'flat', 'CData', colors, 'BaseValue', limits(1));
            hold(ax, 'on');
            for k = find(isfinite(base))'
                plot(ax, k + [-0.42 0.42], base([k k]), 'k-', 'LineWidth', 2);
            end
            for k = find(isfinite(level))'
                text(ax, k, level(k), sprintf('%.1f', level(k)), 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom');
            end
            hold(ax, 'off');
            obj.styleAxes(ax, n, ticks, limits);
            ylabel(ax, '수신 전력 (dBFS)');
            if hasBaseline
                title(ax, '채널별 수신 전력  (검은 선 = 기준값)');
            else
                title(ax, '채널별 수신 전력');
            end

            % 기준값 대비 증가량 막대
            ax = obj.RiseAxes;
            cla(ax);
            known = rise(isfinite(rise));
            limits = [min([-3; known]) - 4, max([10; known]) + 4];
            bar(ax, 1:n, rise, 0.7, 'FaceColor', 'flat', 'CData', colors);
            for k = find(isfinite(rise))'
                if rise(k) >= 0
                    side = 'bottom';
                else
                    side = 'top';
                end
                text(ax, k, rise(k), sprintf('%+.1f', rise(k)), 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', side);
            end
            if ~hasBaseline
                text(ax, (n + 1) / 2, mean(limits), "송신 전에 '기준값 저장' 을 누르면 증가량이 표시됩니다", ...
                    'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
            end
            obj.styleAxes(ax, n, ticks, limits);
            ylabel(ax, '증가량 (dB)');
            if hasBaseline
                title(ax, sprintf('기준값 대비 증가량  (기준값 %s 저장)', string(obj.BaselineTime, "HH:mm:ss")));
            else
                title(ax, '기준값 대비 증가량');
            end

            % 숫자 표
            cells = cell(n, 7);
            for k = 1:n
                cells(k, :) = {obj.Channels(k), 5000 + 5 * obj.Channels(k), char(roles(k)), ...
                    formatDb(level(k), '%.1f'), formatDb(base(k), '%.1f'), ...
                    formatDb(rise(k), '%+.1f'), formatDb(obj.PeakDb(k), '%.1f')};
            end
            obj.Table.Data = cells;
        end

        function styleAxes(~, ax, n, ticks, limits)
            ax.XLim = [0.4, n + 0.6];
            ax.XTick = 1:n;
            ax.XTickLabel = ticks;
            ax.YLim = limits;
            ax.YGrid = 'on';
            ax.Box = 'on';
        end

        function showProgress(obj)
            message = sprintf("측정 중 · %d바퀴 · 한 바퀴 %.1f초", obj.Sweeps, obj.SweepS);
            if obj.Scanner.Reopens > 0
                message = message + sprintf(" · 유실로 다시 연 횟수 %d", obj.Scanner.Reopens);
            end
            clipped = obj.Channels(obj.PeakDb > obj.ClipDb);
            missing = setdiff(obj.Targets, obj.Channels);
            if ~isempty(clipped)
                message = message + " · 입력 포화 (ch" + join(string(clipped), ", ch") + "): Gain 을 낮추세요";
            elseif ~isempty(missing)
                message = message + " · 타깃 ch" + join(string(missing), ", ch") + " 는 운용 대역 밖입니다";
            end
            obj.setStatus(message);
        end

        function setStatus(obj, message)
            obj.StatusLabel.Text = message;
        end

        % ========== 연결 확인 함수 ==========
        function ok = checkUsb(obj)
            speeds = PowerScanner.usbLinkSpeeds();
            ok = isempty(speeds) || any(speeds >= PowerScanner.UsbSuperSpeed);
            if ~ok
                message = sprintf("B210 이 USB 3.0 으로 연결되어 있지 않습니다 (링크 속도 %g Mbit/s). " + ...
                    "USB 2.0 허브를 거치면 20 MS/s 에서 overflow 로 수신이 안 됩니다. " + ...
                    "USB 3.0 포트에 직접 연결하세요.", max(speeds) / 1e6);
                obj.setStatus(message);
                uialert(obj.Fig, message, 'USB 연결');
            end
        end

        function onClose(obj)
            if obj.Busy
                % 측정 루프가 돌고 있으면 루프가 끝난 뒤에 지운다
                obj.Closing = true;
                obj.Running = false;
                obj.Fig.Visible = 'off';
            else
                delete(obj);
            end
        end
    end
end


% ========== 표 숫자 표시 함수 ==========
function text = formatDb(value, format)
if isfinite(value)
    text = sprintf(format, value);
else
    text = '-';
end
end
