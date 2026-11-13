classdef PowerMonitorApp < handle
    %POWERMONITORAPP  USRP 를 등록하고 채널 맵에서 고른 20 MHz 채널의 수신 전력을 계속 보여 주는 창.
    %   app = PowerMonitorApp                      빈 상태로 시작 (채널 맵을 클릭해 관찰)
    %   app = PowerMonitorApp(Channels=36:4:64)    ch36~ch64 를 첫 USRP 로 관찰하며 시작
    %
    %   USRP 표에서 기기를 고르고 채널 맵의 칸을 클릭하면 그 기기가 그 채널을 관찰한다.
    %   다시 클릭하면 해제한다. '클릭 단위' 를 40/80/160 MHz 로 두면 클릭한 칸이 속한
    %   대역 전체를 한 번에 고른다. '시작' 을 누르면 관찰 채널을 반복해서 훑는다.
    %   측정을 시작하고 값이 안정되면(8초쯤 뒤) 그때 값을 기준값으로 자동 저장하고,
    %   이후에는 채널별 증가량(dB)을 함께 보여 준다. '기준값 저장' 으로 직접 다시 잡을 수 있다.
    %   표시값은 최근 5바퀴의 중앙값이라 변화가 몇 초 늦게 반영된다.
    %   값은 보정 안 된 상대값(dBFS)이며 dBm 이 아니다.
    %
    %   아래 '실제 송신 대역폭 모니터' 에서 P20 채널을 고르면, 전력을 한 바퀴 잴 때마다
    %   그 채널을 짧게 캡처해 다운링크 EHT PPDU 의 U-SIG 가 알리는 대역폭을 센다.
    %   (WLAN Toolbox 필요. Wi-Fi 7 단말에 다운링크 트래픽이 흘러야 PPDU 가 잡힌다.)

    properties (SetAccess = private)
        Radios   table                  % 등록된 USRP (Name, Platform, SerialNum, LinkSpeed)
        Owner    (1,:) double           % 5 GHz 채널별로 관찰하는 USRP 번호. 0 이면 관찰 안 함
        Levels   (:,2) double           % 채널별 표시 전력 [평균, 중앙값] (dBFS). 최근 몇 바퀴의 중앙값
        Baseline (:,2) double           % 저장한 기준값. 없으면 NaN
    end

    properties (Access = private)
        Scanners cell = {}              % Radios 와 같은 순서. 처음 쓸 때 만든다
        Selected (1,1) double = 1       % 채널 맵 클릭이 배정할 USRP 번호
        Recent   (:,2,:) double         % 채널별 최근 몇 바퀴의 측정값
        PeakDb   (:,1) double
        BaselineTime = NaT
        BaselineNote (1,1) string = ""  % 기준값을 어떻게 잡았는지 (그래프 제목에 표시)
        SettleStart  (1,:) uint64       % 채널별로 자동 기준값의 안정화 대기를 시작한 시각 (tic)
        Forced       (1,:) logical      % 흔들리는 채로 시간이 다 돼 자동 저장한 채널
        Sweeps   (1,1) double = 0
        SweepS   (1,1) double = NaN
        Running  (1,1) logical = false
        Busy     (1,1) logical = false
        Stale    (1,1) logical = false  % 측정 중에 설정이 바뀌어 화면을 다시 그려야 함
        AutoCheck
        Closing  (1,1) logical = false

        UsigChannel (1,1) double = 0    % 송신 대역폭 모니터가 캡처하는 P20 채널. 0 이면 끔
        UsigHistory = []                % 최근 PPDU (decodeUsig 표)
        UsigTrend   (:,:) double        % [시각, 대역폭별 PPDU 수]
        UsigStart   (1,1) uint64 = 0

        Fig
        RadioTable
        WidthDrop
        GainField
        StatDrop
        StartButton
        MapAxes
        LevelAxes
        RiseAxes
        Table
        UsigDrop
        UsigLabel
        UsigTable
        UsigAxes
        StatusLabel
    end

    properties (Constant, Access = private)
        Channels5GHz = [36:4:64, 100:4:144, 149:4:165]
        StatNames    = ["중앙값 (계속 나오는 신호)", "평균 (Wi-Fi 프레임 포함)"]
        StatColumn   = [2 1]            % StatNames 순서에 해당하는 Levels 열
        SmoothSweeps = 5                % 표시값에 쓰는 최근 바퀴 수. 주변 Wi-Fi 트래픽이
                                        % 한두 바퀴 튀는 것을 걸러 낸다
        ClipDb       = -1               % 최대 샘플이 이보다 크면 포화로 본다
        SettleS        = 8              % 자동 기준값: 측정 시작이나 설정 변경 뒤 기다리는 시간
        StableDb       = 2              % 자동 기준값: 최근 바퀴들이 이 폭 안에 들면 안정된 것으로 본다
        SettleTimeoutS = 15             % 자동 기준값: 이 시간이 지나면 흔들려도 저장한다
        Widths       = [20 40 80 160]
        UsigBursts   = 4                % 송신 대역폭 모니터 한 번의 캡처 길이 (버스트 수, 약 0.1초)
        UsigWindowS  = 60               % 추이 그래프에 남기는 시간
        UsigRecentS  = 10               % 요약 표에 쓰는 최근 구간
        ColorUnused  = [0.90 0.90 0.90]
        ColorRadios  = [0.45 0.68 0.90; 0.97 0.72 0.35; 0.70 0.58 0.88; 0.45 0.80 0.75]
    end

    methods
        % ========== 생성 함수 ==========
        function obj = PowerMonitorApp(opts)
            arguments
                opts.Channels (1,:) double = []
                opts.Gain     (1,1) double = 30
            end
            rootDir = fileparts(fileparts(mfilename("fullpath")));
            addpath(fullfile(rootDir, "device"), fullfile(rootDir, "measure"), fullfile(rootDir, "monitor"));
            assert(all(ismember(opts.Channels, obj.Channels5GHz)), 'SSOM:Channel', '5 GHz 20 MHz 채널 번호만 쓸 수 있습니다.');

            n = numel(obj.Channels5GHz);
            obj.Owner    = zeros(1, n);
            obj.Levels   = nan(n, 2);
            obj.Baseline = nan(n, 2);
            obj.Recent   = nan(n, 2, obj.SmoothSweeps);
            obj.PeakDb   = nan(n, 1);
            obj.SettleStart = repmat(tic, 1, n);
            obj.Forced   = false(1, n);
            obj.buildUi(opts.Gain);
            obj.findRadios();
            if height(obj.Radios) > 0
                obj.Owner(ismember(obj.Channels5GHz, opts.Channels)) = 1;
            end
            obj.redraw();
        end

        % ========== 창 닫기 함수 ==========
        function delete(obj)
            obj.dropScanners();
            if ~isempty(obj.Fig) && isvalid(obj.Fig)
                delete(obj.Fig);
            end
        end
    end

    methods (Access = private)
        % ========== 화면 구성 함수 ==========
        function buildUi(obj, gain)
            obj.Fig = uifigure('Name', '5 GHz 채널 모니터', 'Position', [60 40 1240 900], ...
                'CloseRequestFcn', @(~, ~) obj.onClose());
            grid = uigridlayout(obj.Fig, [6 1]);
            grid.RowHeight = {120, 64, '1x', '1x', 240, 24};

            top = uigridlayout(grid, [1 2]);
            top.ColumnWidth = {'1x', 430};
            top.Padding = [0 0 0 0];

            % --- USRP 등록 ---
            radioGrid = uigridlayout(top, [1 2]);
            radioGrid.ColumnWidth = {'1x', 110};
            radioGrid.Padding = [0 0 0 0];
            obj.RadioTable = uitable(radioGrid, 'ColumnName', ["USRP", "시리얼", "USB", "관찰 채널"], ...
                'RowName', {}, 'SelectionType', 'row', 'Multiselect', 'off', ...
                'ColumnWidth', {70, 80, 70, 'auto'}, ...
                'SelectionChangedFcn', @(~, event) obj.onRadioSelected(event));
            refreshButton = uibutton(radioGrid, 'Text', '기기 새로고침', ...
                'ButtonPushedFcn', @(~, ~) obj.onRefreshRadios());
            refreshButton.Layout.Row = 1;
            refreshButton.Layout.Column = 2;

            % --- 측정 설정 ---
            controls = uigridlayout(top, [4 4]);
            controls.RowHeight = {18, 26, 18, 26};
            controls.ColumnWidth = {'1x', '1x', '1x', '1x'};
            controls.Padding = [0 0 0 0];
            controls.RowSpacing = 4;
            titles = ["클릭 단위", "수신 Gain"];
            for k = 1:numel(titles)
                label = uilabel(controls, 'Text', titles(k));
                label.Layout.Row = 1;
                label.Layout.Column = k;
            end
            obj.WidthDrop = uidropdown(controls, 'Items', obj.Widths + " MHz", 'ItemsData', obj.Widths, ...
                'Tooltip', '채널 맵을 한 번 클릭할 때 고르는 폭. 40 MHz 이상이면 클릭한 칸이 속한 대역 전체를 고른다.');
            obj.WidthDrop.Layout.Row = 2;
            obj.WidthDrop.Layout.Column = 1;
            obj.GainField = uispinner(controls, 'Limits', [0 76], 'Step', 5, 'Value', gain, ...
                'ValueChangedFcn', @(~, ~) obj.onGainChanged());
            obj.GainField.Layout.Row = 2;
            obj.GainField.Layout.Column = 2;
            obj.StartButton = uibutton(controls, 'Text', '시작', 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(~, ~) obj.onStartStop());
            obj.StartButton.Layout.Row = 2;
            obj.StartButton.Layout.Column = 4;
            obj.AutoCheck = uicheckbox(controls, 'Text', '기준값 자동', 'Value', true, ...
                'Tooltip', '기준값이 없는 채널은 값이 안정되면 자동으로 기준값을 저장한다.', ...
                'ValueChangedFcn', @(~, ~) obj.restartSettle());
            obj.AutoCheck.Layout.Row = 2;
            obj.AutoCheck.Layout.Column = 3;
            label = uilabel(controls, 'Text', "전력 계산");
            label.Layout.Row = 3;
            label.Layout.Column = [1 2];
            obj.StatDrop = uidropdown(controls, 'Items', obj.StatNames, 'ItemsData', obj.StatColumn, ...
                'ValueChangedFcn', @(~, ~) obj.refresh());
            obj.StatDrop.Layout.Row = 4;
            obj.StatDrop.Layout.Column = [1 2];
            saveButton = uibutton(controls, 'Text', '기준값 저장', ...
                'Tooltip', '지금 상태를 저장한다. 이후 채널별 증가량이 표시된다.', ...
                'ButtonPushedFcn', @(~, ~) obj.onSaveBaseline());
            saveButton.Layout.Row = 4;
            saveButton.Layout.Column = 3;
            clearButton = uibutton(controls, 'Text', '기준값 지우기', ...
                'ButtonPushedFcn', @(~, ~) obj.onClearBaseline());
            clearButton.Layout.Row = 4;
            clearButton.Layout.Column = 4;

            % --- 채널 맵 / 그래프 / 표 ---
            obj.MapAxes = uiaxes(grid);
            obj.MapAxes.Toolbar.Visible = 'off';
            disableDefaultInteractivity(obj.MapAxes);
            axis(obj.MapAxes, 'off');
            obj.LevelAxes = uiaxes(grid);
            obj.RiseAxes = uiaxes(grid);
            bottom = uigridlayout(grid, [1 2]);
            bottom.ColumnWidth = {'1x', 730};
            bottom.Padding = [0 0 0 0];
            obj.Table = uitable(bottom, 'ColumnName', ...
                ["채널", "MHz", "USRP", "현재 dBFS", "기준 dBFS", "증가 dB", "최대 dBFS"], ...
                'RowName', {}, 'ColumnWidth', {44, 52, 62, '1x', '1x', '1x', '1x'});

            % --- 실제 송신 대역폭 모니터 ---
            panel = uipanel(bottom, 'Title', '실제 송신 대역폭 모니터 (P20 의 U-SIG, 다운링크 EHT PPDU)');
            usig = uigridlayout(panel, [2 3]);
            usig.RowHeight = {24, '1x'};
            usig.ColumnWidth = {130, 240, '1x'};
            usig.Padding = [6 6 6 6];
            obj.UsigDrop = uidropdown(usig, 'Items', ["끔", "P20 = ch" + obj.Channels5GHz], ...
                'ItemsData', [0 obj.Channels5GHz], 'Value', 0, ...
                'Tooltip', 'AP 의 P20 채널을 고르면 전력을 한 바퀴 잴 때마다 그 채널을 캡처해 U-SIG 를 푼다.', ...
                'ValueChangedFcn', @(~, event) obj.onUsigChanged(event));
            obj.UsigLabel = uilabel(usig, 'Text', "끔");
            obj.UsigLabel.Layout.Row = 1;
            obj.UsigLabel.Layout.Column = [2 3];
            obj.UsigTable = uitable(usig, 'RowName', {}, ...
                'ColumnName', ["Color", "폭(MHz)", "non-OFDMA", "Punct.", "PPDU", "비율(%)"], ...
                'ColumnWidth', {48, 62, 86, 54, 50, 60});
            obj.UsigTable.Layout.Row = 2;
            obj.UsigTable.Layout.Column = [1 2];
            obj.UsigAxes = uiaxes(usig);
            obj.UsigAxes.Layout.Row = 2;
            obj.UsigAxes.Layout.Column = 3;
            obj.UsigAxes.Toolbar.Visible = 'off';
            disableDefaultInteractivity(obj.UsigAxes);
            xlabel(obj.UsigAxes, '시간 (s)');
            ylabel(obj.UsigAxes, 'PPDU 수 / 갱신');
            obj.StatusLabel = uilabel(grid, 'Text', "채널 맵에서 관찰할 채널을 클릭하고 '시작' 을 누르세요.");
        end

        % ========== USRP 등록 함수 ==========
        function findRadios(obj)
            % 연결된 USRP 를 다시 찾는다. 계속 연결돼 있는 기기의 관찰 채널은 유지한다.
            obj.setStatus("USRP 를 찾는 중...");
            drawnow;
            before = obj.Radios;
            found = PowerScanner.list();
            found = sortrows(found(found.Status == "Success", :), "SerialNum");   % 실행마다 같은 순서
            links = PowerScanner.usbLinks();
            radios = table("radio" + (1:height(found))', found.Platform, found.SerialNum, nan(height(found), 1), ...
                'VariableNames', ["Name", "Platform", "SerialNum", "LinkSpeed"]);
            for k = 1:height(radios)
                speed = links.LinkSpeed(links.SerialNum == radios.SerialNum(k));
                if ~isempty(speed)
                    radios.LinkSpeed(k) = speed(1);
                end
            end

            owner = zeros(size(obj.Owner));
            for k = 1:height(radios)
                old = [];
                if ~isempty(before)
                    old = find(before.SerialNum == radios.SerialNum(k), 1);
                end
                if ~isempty(old)
                    owner(obj.Owner == old) = k;
                end
            end
            obj.clearChannels(obj.Owner > 0 & owner == 0);
            obj.dropScanners();
            obj.Radios = radios;
            obj.Owner = owner;
            obj.Scanners = cell(1, height(radios));
            obj.Selected = min(max(obj.Selected, 1), max(height(radios), 1));
            if isempty(radios)
                obj.setStatus("연결된 USRP 가 없습니다. 연결한 뒤 '기기 새로고침' 을 누르세요.");
            else
                obj.setStatus(sprintf("USRP %d대를 등록했습니다. 채널 맵에서 관찰할 채널을 클릭하세요.", height(radios)));
            end
        end

        function onRefreshRadios(obj)
            if obj.Busy
                obj.setStatus("측정 중에는 기기를 새로 찾을 수 없습니다. 먼저 정지하세요.");
                return
            end
            obj.findRadios();
            obj.redraw();
        end

        function onRadioSelected(obj, event)
            if ~isempty(event.Selection)
                obj.Selected = event.Selection(1);
            end
        end

        function scanner = scannerFor(obj, radio)
            if isempty(obj.Scanners{radio})
                obj.Scanners{radio} = PowerScanner(SerialNum=obj.Radios.SerialNum(radio), ...
                    Platform=obj.Radios.Platform(radio), Gain=obj.GainField.Value);
            end
            scanner = obj.Scanners{radio};
        end

        function dropScanners(obj)
            for k = 1:numel(obj.Scanners)
                if ~isempty(obj.Scanners{k})
                    delete(obj.Scanners{k});
                end
            end
            obj.Scanners = cell(1, numel(obj.Scanners));
        end

        % ========== 채널 배정 함수 ==========
        function onMapClicked(obj, index)
            % 클릭한 칸이 속한 대역(클릭 단위)을 고른 USRP 에 배정한다.
            % 그 대역을 이미 그 USRP 가 모두 보고 있으면 해제한다.
            if isempty(obj.Radios)
                obj.setStatus("등록된 USRP 가 없습니다. 연결한 뒤 '기기 새로고침' 을 누르세요.");
                return
            end
            try
                block = bandChannels(obj.Channels5GHz(index), obj.WidthDrop.Value);
            catch err
                obj.setStatus(err.message);
                return
            end
            mask = ismember(obj.Channels5GHz, block);
            if all(obj.Owner(mask) == obj.Selected)
                changed = mask;
                obj.Owner(mask) = 0;
            else
                changed = mask & obj.Owner ~= obj.Selected;
                obj.Owner(changed) = obj.Selected;
            end
            % 관찰하는 기기가 바뀐 채널은 이전 측정값과 기준값을 비교할 수 없으므로 비운다
            obj.clearChannels(changed);
            obj.restartSettle(changed);
            obj.refresh();
        end

        function clearChannels(obj, mask)
            obj.Levels(mask, :) = NaN;
            obj.Baseline(mask, :) = NaN;
            obj.Recent(mask, :, :) = NaN;
            obj.PeakDb(mask) = NaN;
            obj.Forced(mask) = false;
            if all(isnan(obj.Baseline), 'all')
                obj.BaselineTime = NaT;
            end
        end

        function onGainChanged(obj)
            for k = 1:numel(obj.Scanners)
                if ~isempty(obj.Scanners{k})
                    obj.Scanners{k}.setGain(obj.GainField.Value);
                end
            end
            hadBaseline = ~isnat(obj.BaselineTime);
            % Gain 이 다르면 같은 신호도 다른 값으로 잡히므로 측정값과 기준값을 모두 비운다
            obj.clearChannels(true(size(obj.Owner)));
            obj.restartSettle();
            if hadBaseline
                obj.setStatus("Gain 을 바꿔 기준값을 지웠습니다. 다시 저장하세요.");
            end
            obj.refresh();
        end

        % ========== 측정 함수 ==========
        function onStartStop(obj)
            if obj.Running
                obj.Running = false;   % 재고 있던 채널이 끝나면 멈춘다
                return
            end
            if isempty(obj.Radios)
                obj.setStatus("등록된 USRP 가 없습니다. 연결한 뒤 '기기 새로고침' 을 누르세요.");
                return
            end
            if ~any(obj.Owner > 0) && obj.UsigChannel == 0
                obj.setStatus("관찰할 채널이 없습니다. USRP 를 고르고 채널 맵의 칸을 클릭하세요.");
                return
            end
            if ~obj.checkUsb()
                return
            end
            obj.Running = true;
            obj.Busy = true;
            obj.restartSettle();
            obj.StartButton.Text = '정지';
            try
                obj.setStatus("수신기를 여는 중... (기기마다 4~5초)");
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
            for k = 1:numel(obj.Scanners)
                if ~isempty(obj.Scanners{k})
                    obj.Scanners{k}.close();   % 멈춘 동안에는 USRP 를 놓아 준다
                end
            end
            obj.StartButton.Text = '시작';
            obj.redraw();
        end

        function sweepLoop(obj)
            while obj.Running
                order = find(obj.Owner > 0);
                if isempty(order) && obj.UsigChannel == 0
                    % 측정 중에 채널을 모두 해제한 경우. 다시 고를 때까지 기다린다
                    obj.setStatus("관찰할 채널이 없습니다. 채널 맵의 칸을 클릭하세요.");
                    pause(0.2);
                    if ~isvalid(obj)
                        return
                    end
                    obj.drawIfStale();
                    continue
                end
                started = tic;
                for index = order
                    radio = obj.Owner(index);
                    if radio == 0
                        continue   % 이번 바퀴 도중에 해제된 채널
                    end
                    power = obj.scannerFor(radio).measure(obj.Channels5GHz(index));
                    drawnow;   % 버튼과 채널 맵 입력을 처리한다. 이때 배정이 바뀌거나 창이 닫힐 수 있다
                    if ~isvalid(obj)
                        return
                    end
                    if ~obj.Running
                        break
                    end
                    if obj.Owner(index) ~= radio
                        obj.drawIfStale();
                        continue   % 재는 동안 배정이 바뀌었으면 버린다
                    end
                    obj.Recent(index, :, :) = cat(3, obj.Recent(index, :, 2:end), [power.MeanDb, power.MedianDb]);
                    obj.Levels(index, :) = median(obj.Recent(index, :, :), 3, 'omitnan');
                    obj.PeakDb(index) = power.PeakDb;
                    if index == order(end)
                        obj.Sweeps = obj.Sweeps + 1;
                        obj.SweepS = toc(started);
                    end
                    obj.autoBaseline();
                    if ~obj.drawIfStale()
                        obj.drawData();
                    end
                    obj.showProgress();
                end
                if obj.Running && obj.UsigChannel > 0 && ~obj.usigStep()
                    return
                end
            end
        end

        % ========== 송신 대역폭 모니터 함수 ==========
        function onUsigChanged(obj, event)
            try
                obj.UsigHistory = decodeUsig(zeros(0, 1), 20e6);   % 열 구성이 같은 빈 표
            catch err
                event.Source.Value = 0;
                obj.UsigChannel = 0;
                uialert(obj.Fig, "U-SIG 디코더를 쓸 수 없습니다 (WLAN Toolbox 필요): " + err.message, ...
                    '송신 대역폭 모니터');
                return
            end
            obj.UsigChannel = event.Value;
            obj.UsigTrend = zeros(0, 1 + numel(obj.Widths));
            obj.UsigStart = tic;
            obj.refresh();
        end

        function radio = usigRadio(obj)
            % P20 을 캡처할 USRP. 그 채널을 관찰하는 기기가 있으면 그 기기, 없으면 표에서 고른 기기
            radio = obj.Owner(obj.Channels5GHz == obj.UsigChannel);
            if isempty(radio) || radio == 0
                radio = min(obj.Selected, height(obj.Radios));
            end
        end

        function alive = usigStep(obj)
            % P20 을 짧게 캡처해 다운링크 EHT PPDU 의 U-SIG 를 풀고 표와 추이 그래프에 더한다
            channel = obj.UsigChannel;
            waveforms = obj.scannerFor(obj.usigRadio()).capture(channel, obj.UsigBursts);
            drawnow;   % 버튼 입력을 처리한다. 이때 모니터 채널이 바뀌거나 창이 닫힐 수 있다
            alive = isvalid(obj);
            if ~alive || ~obj.Running || obj.UsigChannel ~= channel
                return
            end
            elapsed = toc(obj.UsigStart);
            ppdus = obj.UsigHistory([], :);
            for k = 1:numel(waveforms)
                ppdus = [ppdus; decodeUsig(waveforms{k}, 20e6, EhtOnly=true)]; %#ok<AGROW>
            end
            ppdus = ppdus(~ppdus.Uplink, :);
            ppdus.TimeS(:) = elapsed;
            obj.UsigHistory = [obj.UsigHistory; ppdus];
            obj.UsigHistory = obj.UsigHistory(obj.UsigHistory.TimeS > elapsed - obj.UsigRecentS, :);
            obj.UsigTrend = [obj.UsigTrend; elapsed, sum(ppdus.BandwidthMHz == obj.Widths, 1)];
            obj.UsigTrend = obj.UsigTrend(obj.UsigTrend(:, 1) > elapsed - obj.UsigWindowS, :);
            obj.drawUsig();
            if ~any(obj.Owner > 0)
                obj.setStatus("송신 대역폭 모니터만 측정 중 (전력을 볼 채널은 채널 맵에서 클릭)");
            end
        end

        function drawUsig(obj)
            ax = obj.UsigAxes;
            trend = obj.UsigTrend;
            if obj.UsigChannel == 0 || isempty(trend)
                obj.UsigTable.Data = {};
                cla(ax);
                legend(ax, 'off');
                if obj.UsigChannel == 0
                    obj.UsigLabel.Text = "끔";
                else
                    obj.UsigLabel.Text = sprintf("ch%d 측정 전. '시작' 을 누르면 함께 측정합니다.", obj.UsigChannel);
                end
                return
            end
            summary = summarizeUsig(obj.UsigHistory);
            obj.UsigTable.Data = summary(:, ["BssColor", "BandwidthMHz", "NonOfdma", "PuncturedInfo", "Count", "SharePct"]);
            obj.UsigLabel.Text = sprintf("ch%d 최근 %d초: 다운링크 EHT %d개 (갱신 주기 %.1f초)", ...
                obj.UsigChannel, obj.UsigRecentS, height(obj.UsigHistory), mean(diff([0; trend(:, 1)])));
            if isempty(obj.UsigHistory)
                obj.UsigLabel.Text = obj.UsigLabel.Text + " / Wi-Fi 7 단말에 트래픽 필요";
            end
            bar(ax, trend(:, 1), trend(:, 2:end), 'stacked', 'BarWidth', 1);
            legend(ax, obj.Widths + " MHz", 'Location', 'northeastoutside');
            xlim(ax, [max(0, trend(end, 1) - obj.UsigWindowS), max(trend(end, 1), 10)]);
            xlabel(ax, '시간 (s)');
            ylabel(ax, 'PPDU 수 / 갱신');
        end

        % ========== 기준값 함수 ==========
        function onSaveBaseline(obj)
            watched = obj.Owner > 0;
            if ~any(watched) || any(isnan(obj.Recent(watched, :, :)), 'all')
                obj.setStatus(sprintf("관찰 채널을 %d바퀴 다 잰 뒤에 기준값을 저장할 수 있습니다.", obj.SmoothSweeps));
                return
            end
            obj.Baseline(:) = NaN;
            obj.Baseline(watched, :) = obj.Levels(watched, :);
            obj.BaselineTime = datetime("now");
            obj.BaselineNote = "직접";
            obj.Forced(:) = false;
            obj.refresh();
            obj.setStatus("지금 표시된 값을 기준값으로 저장했습니다.");
        end

        function autoBaseline(obj)
            % 기준값이 없는 관찰 채널은 값이 안정되면 지금 표시값을 기준값으로 저장한다.
            % 채널마다 따로 판단하고, 이미 기준값이 있는 채널은 건드리지 않는다.
            need = obj.pendingBaseline();
            if ~any(need)
                return
            end
            waited = arrayfun(@toc, obj.SettleStart);
            recent = obj.Recent(:, obj.StatDrop.Value, :);
            measured = ~any(isnan(recent), 3)';
            shaky = (max(recent, [], 3) - min(recent, [], 3))' > obj.StableDb;
            % 주변 트래픽으로 흔들리는 채널은 가라앉기를 기다리되, 너무 오래 걸리면 그대로 저장한다
            ready = need & measured & waited >= obj.SettleS & (~shaky | waited >= obj.SettleTimeoutS);
            if ~any(ready)
                return
            end
            obj.Baseline(ready, :) = obj.Levels(ready, :);
            obj.Forced(ready) = shaky(ready);
            obj.BaselineTime = datetime("now");
            obj.BaselineNote = "자동";
            if any(obj.Forced)
                obj.BaselineNote = "자동, ch" + join(string(obj.Channels5GHz(obj.Forced)), "/ch") + " 는 흔들리는 중에 저장";
            end
            obj.Stale = true;
        end

        function need = pendingBaseline(obj)
            % 자동 기준값을 기다리는 채널
            need = obj.AutoCheck.Value & obj.Owner > 0 & any(isnan(obj.Baseline), 2)';
        end

        function restartSettle(obj, mask)
            arguments
                obj
                mask (1,:) logical = true(size(obj.Owner))
            end
            obj.SettleStart(mask) = tic;
        end

        function onClearBaseline(obj)
            obj.Baseline(:) = NaN;
            obj.BaselineTime = NaT;
            obj.restartSettle();   % 자동이 켜져 있으면 안정된 뒤 다시 잡는다
            obj.refresh();
        end

        % ========== 화면 갱신 함수 ==========
        function refresh(obj)
            % 버튼과 채널 맵 콜백이 부르는 화면 갱신. 측정 중에는 측정 루프가 그리는 도중에
            % 끼어들 수 있으므로 직접 그리지 않고 표시만 해 두면 루프가 다시 그린다
            if obj.Busy
                obj.Stale = true;
            else
                obj.redraw();
            end
        end

        function drawn = drawIfStale(obj)
            drawn = obj.Stale;
            if drawn
                obj.redraw();
            end
        end

        function redraw(obj)
            obj.Stale = false;
            obj.drawRadios();
            obj.drawMap();
            obj.drawData();
            obj.drawUsig();
        end

        function color = radioColor(obj, radio)
            color = obj.ColorRadios(mod(radio - 1, height(obj.ColorRadios)) + 1, :);
        end

        function drawRadios(obj)
            n = height(obj.Radios);
            data = cell(n, 4);
            removeStyle(obj.RadioTable);
            for k = 1:n
                channels = obj.Channels5GHz(obj.Owner == k);
                watching = '-';
                if ~isempty(channels)
                    watching = char(join("ch" + channels, " "));
                end
                data(k, :) = {char(obj.Radios.Name(k)), char(obj.Radios.SerialNum(k)), ...
                    usbText(obj.Radios.LinkSpeed(k)), watching};
                % 채널 맵에서 이 기기가 보는 칸과 같은 색
                addStyle(obj.RadioTable, uistyle('BackgroundColor', obj.radioColor(k)), 'cell', [k 1]);
            end
            obj.RadioTable.Data = data;
            if n > 0
                obj.RadioTable.Selection = obj.Selected;
            end
        end

        function drawMap(obj)
            ax = obj.MapAxes;
            cla(ax);
            channels = obj.Channels5GHz;
            % 주파수가 떨어진 구간(ch64-ch100, ch144-ch149) 사이는 칸을 띄운다
            left = (0:numel(channels) - 1) + 0.5 * cumsum([0, diff(channels) > 4]);
            for k = 1:numel(channels)
                color = obj.ColorUnused;
                if obj.Owner(k) > 0
                    color = obj.radioColor(obj.Owner(k));
                end
                rectangle(ax, 'Position', [left(k), 0, 1, 1], 'FaceColor', color, 'EdgeColor', 'w', ...
                    'LineWidth', 2, 'ButtonDownFcn', @(~, ~) obj.onMapClicked(k));
                % 글자가 클릭을 가로채지 않게 한다
                text(ax, left(k) + 0.5, 0.5, string(channels(k)), 'HorizontalAlignment', 'center', ...
                    'FontWeight', 'bold', 'PickableParts', 'none');
            end
            xlim(ax, [0, left(end) + 1]);
            ylim(ax, [0 1]);
        end

        function drawData(obj)
            column = obj.StatDrop.Value;
            owner = obj.Owner;   % 그리는 도중에 배정이 바뀌어도 어긋나지 않게 복사해 쓴다
            shown = find(owner > 0);
            n = numel(shown);
            channels = obj.Channels5GHz(shown);
            level = obj.Levels(shown, column);
            base = obj.Baseline(shown, column);
            rise = level - base;
            hasBaseline = ~isnat(obj.BaselineTime);
            colors = zeros(n, 3);   % 막대는 채널 맵과 같은 USRP 색
            for k = 1:n
                colors(k, :) = obj.radioColor(owner(shown(k)));
            end
            if n > 12
                ticks = string(channels);   % 칸이 좁으면 번호만 쓴다
            else
                ticks = "ch" + channels;
            end

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
            if n > 0
                bar(ax, 1:n, level, 0.7, 'FaceColor', 'flat', 'CData', colors, 'BaseValue', limits(1));
            end
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
            if n == 0
                text(ax, 0.5, mean(limits), "채널 맵에서 관찰할 채널을 클릭하세요", ...
                    'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
            end

            % 기준값 대비 증가량 막대
            ax = obj.RiseAxes;
            cla(ax);
            known = rise(isfinite(rise));
            limits = [min([-3; known]) - 4, max([10; known]) + 4];
            if n > 0
                bar(ax, 1:n, rise, 0.7, 'FaceColor', 'flat', 'CData', colors);
            end
            for k = find(isfinite(rise))'
                if rise(k) >= 0
                    side = 'bottom';
                else
                    side = 'top';
                end
                text(ax, k, rise(k), sprintf('%+.1f', rise(k)), 'FontWeight', 'bold', ...
                    'HorizontalAlignment', 'center', 'VerticalAlignment', side);
            end
            obj.styleAxes(ax, n, ticks, limits);
            if ~hasBaseline && n > 0
                text(ax, mean(ax.XLim), mean(limits), "기준값이 저장되면 그때 대비 증가량이 표시됩니다", ...
                    'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
            end
            ylabel(ax, '증가량 (dB)');
            if hasBaseline
                title(ax, sprintf('기준값 대비 증가량  (기준값 %s 저장: %s)', ...
                    string(obj.BaselineTime, "HH:mm:ss"), obj.BaselineNote));
            else
                title(ax, '기준값 대비 증가량');
            end

            % 숫자 표
            cells = cell(n, 7);
            for k = 1:n
                cells(k, :) = {channels(k), 5000 + 5 * channels(k), ...
                    char(obj.Radios.Name(owner(shown(k)))), ...
                    formatDb(level(k), '%.1f'), formatDb(base(k), '%.1f'), ...
                    formatDb(rise(k), '%+.1f'), formatDb(obj.PeakDb(shown(k)), '%.1f')};
            end
            obj.Table.Data = cells;
        end

        function styleAxes(~, ax, n, ticks, limits)
            if n == 0
                ax.XLim = [0 1];
                ax.XTick = [];
            else
                ax.XLim = [0.4, n + 0.6];
                ax.XTick = 1:n;
                ax.XTickLabel = ticks;
            end
            ax.YLim = limits;
            ax.YGrid = 'on';
            ax.Box = 'on';
        end

        function showProgress(obj)
            message = sprintf("측정 중 · %d바퀴 · 한 바퀴 %.1f초", obj.Sweeps, obj.SweepS);
            if any(obj.pendingBaseline())
                message = message + " · 값이 안정되면 기준값을 자동 저장합니다";
            end
            reopens = sum(cellfun(@(s) s.Reopens, obj.Scanners(~cellfun(@isempty, obj.Scanners))));
            if reopens > 0
                message = message + sprintf(" · 유실로 다시 연 횟수 %d", reopens);
            end
            clipped = obj.Channels5GHz(obj.Owner > 0 & obj.PeakDb' > obj.ClipDb);
            if ~isempty(clipped)
                message = message + " · 입력 포화 (ch" + join(string(clipped), ", ch") + "): Gain 을 낮추세요";
            end
            obj.setStatus(message);
        end

        function setStatus(obj, message)
            obj.StatusLabel.Text = message;
        end

        % ========== 연결 확인 함수 ==========
        function ok = checkUsb(obj)
            % 관찰에 쓰는 USRP 가 USB 3.0 으로 연결돼 있는지 확인한다
            used = obj.Owner(obj.Owner > 0);
            if obj.UsigChannel > 0
                used(end + 1) = obj.usigRadio();
            end
            used = unique(used);
            slow = used(obj.Radios.LinkSpeed(used)' < PowerScanner.UsbSuperSpeed);
            ok = isempty(slow);
            if ~ok
                message = sprintf("%s 이 USB 3.0 으로 연결되어 있지 않습니다. " + ...
                    "USB 2.0 허브를 거치면 20 MS/s 에서 overflow 로 수신이 안 됩니다. " + ...
                    "USB 3.0 포트에 직접 연결한 뒤 '기기 새로고침' 을 누르세요.", join(obj.Radios.Name(slow), ", "));
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


% ========== 표 글자 표시 함수 ==========
function text = formatDb(value, format)
if isfinite(value)
    text = sprintf(format, value);
else
    text = '-';
end
end

function text = usbText(linkSpeed)
if isnan(linkSpeed)
    text = '?';
elseif linkSpeed >= PowerScanner.UsbSuperSpeed
    text = '3.0';
else
    text = '2.0 (느림)';
end
end
