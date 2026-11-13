function summary = summarizeUsig(ppdus)
%SUMMARIZEUSIG  decodeUsig 결과에서 다운링크 EHT PPDU 를 조합별로 센다.
%   summary 는 BSS Color / 대역폭 / non-OFDMA 여부 / puncturing 값 조합별
%   PPDU 수(Count), 평균 세기(PowerDb), 비율(SharePct)이다.
downlink = ppdus(startsWith(ppdus.Format, "EHT") & ~ppdus.Uplink, :);
summary = groupsummary(downlink, ["BssColor", "BandwidthMHz", "NonOfdma", "PuncturedInfo"], "mean", "PowerDb");
summary.Properties.VariableNames(end - 1:end) = ["Count", "PowerDb"];
summary.SharePct = round(100 * summary.Count / max(height(downlink), 1), 1);
end
