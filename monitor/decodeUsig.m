function ppdus = decodeUsig(waveform, sampleRate, threshold, opts)
%DECODEUSIG  P20 의 20 MHz 캡처에서 PPDU 를 찾아 형식과 U-SIG 내용을 표로 반환한다.
%   ppdus = decodeUsig(waveform, 20e6)
%   EHT PPDU 의 프리앰블(L-SIG, U-SIG)은 20 MHz 서브채널마다 복제되므로, PPDU 가
%   160 MHz 로 나가도 P20 만 캡처하면 U-SIG 를 풀 수 있다.
%   열: TimeS, Format, DurationMs, PowerDb, 그리고 EHT PPDU 에서만 채워지는
%   BandwidthMHz, Uplink, BssColor, CompressionMode, NonOfdma, PuncturedInfo
%   EhtOnly=true 면 L-SIG 로 EHT 후보만 골라 풀어 훨씬 빠르다 (EHT 가 아닌 PPDU 는 표에서 빠진다).
arguments
    waveform   (:,1) double
    sampleRate (1,1) double = 20e6
    threshold  (1,1) double = 0.5   % 패킷 검출 임계값
    opts.EhtOnly (1,1) logical = false
end
assert(sampleRate == 20e6, "decodeUsig 는 20 MS/s 캡처만 지원합니다.");

cbw = 'CBW20';
ind = wlanFieldIndices(wlanNonHTConfig);
preambleLen = double(ind.LSIG(2));
symbolLen = 80;                      % 20 MS/s 에서 OFDM 심볼(4 us) 길이
detectLen = preambleLen + 4 * symbolLen;   % 형식 판별에 L-SIG 뒤 심볼이 더 필요하다
searchLen = 20000;                   % 패킷 검출을 한 번에 살피는 구간 (1 ms)
ehtCfg = wlanEHTRecoveryConfig(ChannelBandwidth=cbw);
ehtInd = wlanFieldIndices(ehtCfg);
usigInfo = wlanEHTOFDMInfo('U-SIG', ehtCfg);
dataBitsPerSymbol = [24 36 48 72 96 144 192 216];   % L-SIG RATE(MCS 0~7)별 심볼당 비트 수
rateCodes = [13 15 5 7 9 11 1 3];
bandwidths = [20 40 80 160 320 320];                 % U-SIG BW 필드 0~5

rows = {};
offset = 0;
while offset + detectLen < numel(waveform)
    % 남은 파형 전체를 넘기면 호출마다 통째로 검사하므로 짧은 구간씩 살핀다
    searchEnd = min(offset + searchLen, numel(waveform));
    pktOffset = wlanPacketDetect(waveform(offset + 1:searchEnd), cbw, 0, threshold);
    if isempty(pktOffset)
        if searchEnd == numel(waveform)
            break
        end
        offset = searchEnd - ind.LSTF(2);   % 경계에 걸친 L-STF 를 놓치지 않게 겹친다
        continue
    end
    start = offset + pktOffset;
    if start + detectLen > numel(waveform)
        break
    end
    offset = start + preambleLen;   % 실패해도 다음 탐색은 프리앰블 뒤부터

    % 주파수/타이밍 동기 (프리앰블 구간만 다룬다)
    pkt = waveform(start + 1:min(start + 2 * detectLen, end));
    cfo = wlanCoarseCFOEstimate(pkt(ind.LSTF(1):ind.LSTF(2)), cbw);
    pkt = frequencyOffset(pkt, sampleRate, -cfo);
    timing = wlanSymbolTimingEstimate(pkt(1:preambleLen), cbw);
    if timing < 0 || timing + detectLen > numel(pkt)
        continue
    end
    pkt = pkt(timing + 1:end);
    cfo = wlanFineCFOEstimate(pkt(ind.LLTF(1):ind.LLTF(2)), cbw);
    pkt = frequencyOffset(pkt, sampleRate, -cfo);

    % 채널 추정, L-SIG
    lltf = wlanLLTFDemodulate(pkt(ind.LLTF(1):ind.LLTF(2)), cbw);
    chanEst = wlanLLTFChannelEstimate(lltf, cbw);
    noiseVar = wlanLLTFNoiseEstimate(lltf);
    [lsigBits, failCheck] = wlanLSIGRecover(pkt(ind.LSIG(1):ind.LSIG(2)), chanEst, noiseVar, cbw);
    mcs = find(rateCodes == bit2int(double(lsigBits(1:4)), 4)) - 1;
    lsigLength = bit2int(double(lsigBits(6:17)), 12, false);
    if failCheck || isempty(mcs) || lsigLength == 0
        continue
    end
    % L-SIG 의 RATE/LENGTH 가 알려주는 PPDU 길이만큼 건너뛴다
    durationUs = 20 + 4 * ceil((16 + 8 * lsigLength + 6) / dataBitsPerSymbol(mcs + 1));
    offset = start + timing + round(durationUs * 1e-6 * sampleRate);
    % EHT PPDU 는 L-SIG 의 RATE 가 6 Mbps 이고 LENGTH 가 3의 배수다
    if opts.EhtOnly && (mcs ~= 0 || mod(lsigLength, 3) ~= 0)
        continue
    end

    format = string(wlanFormatDetect(pkt(ind.LSIG(1):ind.LSIG(1) + 4 * symbolLen - 1), chanEst, noiseVar, cbw));
    row = {(start + timing) / sampleRate, format, durationUs / 1e3, ...
        10 * log10(mean(abs(pkt(1:preambleLen)).^2)), NaN, false, NaN, NaN, false, NaN};

    if opts.EhtOnly && ~startsWith(format, "EHT")
        continue
    end
    if startsWith(format, "EHT")
        % L-SIG/RL-SIG 로 가장자리 부반송파까지 채널을 보강한 뒤 U-SIG 복원
        lsigDemod = wlanEHTDemodulate(pkt(ehtInd.LSIG(1):ehtInd.RLSIG(2)), 'L-SIG', ehtCfg);
        preEhtChanEst = wlanPreEHTChannelEstimate(lsigDemod, chanEst, cbw);
        usigDemod = wlanEHTDemodulate(pkt(ehtInd.USIG(1):ehtInd.USIG(2)), 'U-SIG', ehtCfg);
        usigDemod = wlanEHTTrackPilotError(usigDemod, preEhtChanEst, ehtCfg, 'U-SIG');
        [eqUsig, csi] = wlanEHTEqualize(usigDemod(usigInfo.DataIndices, :, :), ...
            preEhtChanEst(usigInfo.DataIndices, :, :), noiseVar, ehtCfg, 'U-SIG');
        [usigBits, failCrc] = wlanUSIGBitRecover(eqUsig, noiseVar, csi);
        if failCrc
            continue
        end
        % U-SIG-1: PHY 버전(1~3), BW(4~6), UL/DL(7), BSS Color(8~13)
        % U-SIG-2: PPDU Type And Compression Mode(1~2), Punctured Channel Information(4~8)
        sym1 = double(usigBits(1:26));
        sym2 = double(usigBits(27:52));
        compressionMode = bit2int(sym2(1:2), 2, false);
        row(5:10) = {bandwidths(bit2int(sym1(4:6), 3, false) + 1), logical(sym1(7)), ...
            bit2int(sym1(8:13), 6, false), compressionMode, ...
            ismember(compressionMode, [1 2]), bit2int(sym2(4:8), 5, false)};
    end
    rows(end + 1, :) = row; %#ok<AGROW>
end

names = ["TimeS", "Format", "DurationMs", "PowerDb", "BandwidthMHz", "Uplink", ...
    "BssColor", "CompressionMode", "NonOfdma", "PuncturedInfo"];
if isempty(rows)
    ppdus = table('Size', [0 numel(names)], 'VariableNames', names, 'VariableTypes', ...
        ["double", "string", "double", "double", "double", "logical", "double", "double", "logical", "double"]);
else
    ppdus = cell2table(rows, 'VariableNames', names);
end
end
