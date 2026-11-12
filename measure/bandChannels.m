function channels = bandChannels(primary, widthMHz)
%BANDCHANNELS  P20 채널과 대역폭으로 운용 대역의 20 MHz 채널 번호를 구한다.
%   bandChannels(40, 160)  ->  36 40 44 48 52 56 60 64
%   bandChannels(40, 80)   ->  36 40 44 48
%   채널 번호 1당 5 MHz 이므로 20 MHz 채널은 번호가 4씩 떨어져 있다.
arguments
    primary  (1,1) double {mustBeInteger, mustBePositive}
    widthMHz (1,1) double {mustBeMember(widthMHz, [20 40 80 160])}
end
valid = [36:4:64, 100:4:144, 149:4:165];
assert(ismember(primary, valid), 'SSOM:Channel', 'ch%d 는 5 GHz 20 MHz 채널이 아닙니다.', primary);

% 대역 묶음은 UNII 구간의 첫 채널(36, 100, 149)부터 차례로 센다
starts = [36 100 149];
base = starts(find(primary >= starts, 1, 'last'));
count = widthMHz / 20;
first = floor((primary - base) / 4 / count) * count;
channels = base + 4 * (first + (0:count - 1));
assert(all(ismember(channels, valid)), 'SSOM:Band', ...
    'ch%d 를 포함하는 %d MHz 대역이 없습니다.', primary, widthMHz);
end
