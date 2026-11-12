function power = channelPower(raw, blockLen)
%CHANNELPOWER  int16 IQ 캡처 하나의 수신 전력을 구한다.
%   power.MeanDb    전체 평균 전력
%   power.MedianDb  blockLen 샘플 구간별 전력의 중앙값.
%                   Wi-Fi 프레임처럼 띄엄띄엄 오는 신호에는 덜 흔들리고,
%                   계속 나오는 잡음에는 평균과 같은 값이 된다.
%   power.PeakDb    I/Q 중 가장 큰 샘플. 0 에 가까우면 입력 포화.
%   값은 보정 안 된 상대값(dBFS)이며 dBm 이 아니다.
arguments
    raw      (:,1) {mustBeNumeric}
    blockLen (1,1) double {mustBeInteger, mustBePositive} = 20000   % 20 MS/s 에서 1 ms
end
x = double(raw) / 32768;
power.PeakDb = 20 * log10(max(max(abs(real(x))), max(abs(imag(x)))) + eps);

x = x - mean(x);   % LO 누설로 중심 주파수에 생기는 DC 성분 제거
numBlocks = floor(numel(x) / blockLen);
assert(numBlocks >= 1, 'SSOM:Capture', '캡처가 한 구간(%d 샘플)보다 짧습니다.', blockLen);
blockPower = mean(abs(reshape(x(1:numBlocks * blockLen), blockLen, numBlocks)).^2, 1);
power.MeanDb   = 10 * log10(mean(blockPower) + eps);
power.MedianDb = 10 * log10(median(blockPower) + eps);
end
