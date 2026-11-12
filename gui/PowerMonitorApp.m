classdef PowerMonitorApp < handle
    %POWERMONITORAPP  USRP 를 등록하고 채널 맵에서 고른 20 MHz 채널의 수신 전력을 계속 보여 주는 창.
    %   app = PowerMonitorApp                      빈 상태로 시작 (채널 맵을 클릭해 관찰)
    %   app = PowerMonitorApp(Channels=36:4:64)    ch36~ch64 를 첫 USRP 로 관찰하며 시작
    %
    %   USRP 표에서 기기를 고르고 채널 맵의 칸을 클릭하면 그 기기가 그 채널을 관찰한다.
    %   다시 클릭하면 해제한다. '클릭 단위' 를 40/80/160 MHz 로 두면 클릭한 칸이 속한
    %   대역 전체를 한 번에 고른다. '시작' 을 누르면 관찰 채널을 반복해서 훑는다.
    %   '기준값 저장' 을 눌러 두면 이후에는 채널별 증가량(dB)이 함께 표시된다.
    %   표시값은 최근 5바퀴의 중앙값이라 변화가 몇 초 늦게 반영된다.
    %   값은 보정 안 된 상대값(dBFS)이며 dBm 이 아니다.

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
        Sweeps   (1,1) double = 0
        SweepS   (1,1) double = NaN
        Running  (1,1) logical = false
        Busy     (1,1) logical = false
        Stale    (1,1) logical = false  % 측정 중에 설정이 바뀌어 화면을 다시 그려야 함
        Closing  (1,1) logical = false

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
        StatusLabel
    end

    properties (Constant, Access = private)
        Channels5GHz = [36:4:64, 100:4:144, 149:4:165]
        StatNames    = ["중앙값 (계속 나오는 신호)", "평균 (Wi-Fi 프레임 포함)"]
        StatColumn   = [2 1]            % StatNames 순서에 해당하는 Levels 열
        SmoothSweeps = 5                % 표시값에 쓰는 최근 바퀴 수. 주변 Wi-Fi 트래픽이
                                        % 한두 바퀴 튀는 것을 걸러 낸다
        ClipDb       = -1               % 최대 샘플이 이보다 크면 포화로 본다
        Widths       = [20 40 80 160]
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
            addpath(fullfile(rootDir, "device"), fullfile(rootDir, "measure"));
            assert(all(ismember(opts.Channels, obj.Channels5GHz)), 'SSOM:Channel', '5 GHz 20 MHz 채널 번호만 쓸 수 있습니다.');

            n = numel(obj.Channels5GHz);
            obj.Owner    = zeros(1, n);
            obj.Levels   = nan(n, 2);
            obj.Baseline = nan(n, 2);
            obj.Recent   = nan(n, 2, obj.SmoothSweeps);
            obj.PeakDb   = nan(n, 1);
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
            obj.Fig = uifigure('Name', '5 GHz 채널별 수신 전력', 'Position', [100 40 1000 900], ...
                'CloseRequestFcn', @(~, ~) obj.onClose());
            grid = uigridlayout(obj.Fig, [6 1]);
            grid.RowHeight = {120, 64, '1x', '1x', 215, 24};

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
            obj.Table = uitable(grid, 'ColumnName', ...
                ["채널", "중심 주파수 (MHz)", "USRP", "현재 (dBFS)", "기준값 (dBFS)", "증가량 (dB)", "최대 샘플 (dBFS)"], ...
                'RowName', {});
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
            obj.refresh();
        end

        function clearChannels(obj, mask)
            obj.Levels(mask, :) = NaN;
            obj.Baseline(mask, :) = NaN;
            obj.Recent(mask, :, :) = NaN;
            obj.PeakDb(mask) = NaN;
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
            if ~any(obj.Owner > 0)
                obj.setStatus("관찰할 채널이 없습니다. USRP 를 고르고 채널 맵의 칸을 클릭하세요.");
                return
            end
            if ~obj.checkUsb()
                return
            end
            obj.Running = true;
            obj.Busy = true;
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
                if isempty(order)
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
                    if ~obj.drawIfStale()
                        obj.drawData();
                    end
                    obj.showProgress();
                end
            end
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
            obj.refresh();
            obj.setStatus("지금 표시된 값을 기준값으로 저장했습니다.");
        end

        function onClearBaseline(obj)
            obj.Baseline(:) = NaN;
            obj.BaselineTime = NaT;
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
                text(ax, mean(ax.XLim), mean(limits), "'기준값 저장' 을 누르면 그때 대비 증가량이 표시됩니다", ...
                    'HorizontalAlignment', 'center', 'Color', [0.4 0.4 0.4]);
            end
            ylabel(ax, '증가량 (dB)');
            if hasBaseline
                title(ax, sprintf('기준값 대비 증가량  (기준값 %s 저장)', string(obj.BaselineTime, "HH:mm:ss")));
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
            used = unique(obj.Owner(obj.Owner > 0));
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
