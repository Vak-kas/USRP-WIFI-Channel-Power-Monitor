% testMeasureOffline  USRP 없이 채널 계산과 전력 계산을 확인한다.

%% 대역 채널
assert(isequal(bandChannels(40, 160), 36:4:64));
assert(isequal(bandChannels(40, 80), 36:4:48));
assert(isequal(bandChannels(60, 80), 52:4:64));
assert(isequal(bandChannels(40, 40), [36 40]));
assert(isequal(bandChannels(44, 20), 44));
assert(isequal(bandChannels(112, 160), 100:4:128));
assert(isequal(bandChannels(157, 80), 149:4:161));
for bad = {{165, 40}, {140, 160}, {38, 20}}
    try
        bandChannels(bad{1}{:});
        error('SSOM:Test', '오류가 나야 하는 입력이 통과했습니다.');
    catch err
        assert(ismember(err.identifier, ["SSOM:Band", "SSOM:Channel"]), err.message);
    end
end

%% 전력: 알려진 크기의 잡음
rng(1);
n = 400000;
sigma = 0.01;   % 복소 잡음 전력 sigma^2 -> -40 dBFS
noise = sigma / sqrt(2) * (randn(n, 1) + 1i * randn(n, 1));
toInt16 = @(x) complex(int16(real(x) * 32768), int16(imag(x) * 32768));
p = channelPower(toInt16(noise));
assert(abs(p.MeanDb + 40) < 0.1 && abs(p.MedianDb + 40) < 0.1);

%% 전력: DC 성분은 빼고 잰다
p = channelPower(toInt16(noise + 0.1));
assert(abs(p.MeanDb + 40) < 0.1);

%% 전력: 10 dB 올리면 10 dB 올라간다
p10 = channelPower(toInt16(noise * sqrt(10)));
assert(abs(p10.MeanDb + 30) < 0.1);

%% 전력: 짧은 버스트는 평균만 올리고 중앙값은 그대로 둔다
bursty = noise;
bursty(1:40000) = bursty(1:40000) * 100;   % 20 ms 중 2 ms 동안 40 dB 큰 신호
p = channelPower(toInt16(bursty));
assert(p.MeanDb > -15 && abs(p.MedianDb + 40) < 0.1);

%% 전력: 포화 검출
clipped = repmat(int16([32767; -32768; 100; 100]), 5000, 1);
p = channelPower(complex(clipped, int16(0)));
assert(p.PeakDb > -0.01);

disp("testMeasureOffline 통과");
