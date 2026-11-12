% main  5 GHz 채널별 수신 전력 모니터 진입점 (수신 전용).
%   다른 컴퓨터의 B210 이 송신하는 잡음이 실제로 나오는지 확인한다.

close all force;   % 열려 있는 창까지 닫는다 (창이 남아 있으면 클래스가 갱신되지 않는다)
clear classes;     % 이전에 올라간 클래스 정의를 비워 수정한 코드를 반영한다
clc;

rootDir = fileparts(mfilename("fullpath"));
addpath(fullfile(rootDir, "device"), fullfile(rootDir, "measure"), fullfile(rootDir, "gui"));

% 대상 AP: P20 = ch40, 160 MHz (ch36~ch64). 논문 타깃 q = ch36, r = ch44
% 관찰 채널은 창의 채널 맵을 클릭해 바꿀 수 있다.
% 구분 없이 빈 상태로 시작하려면: app = PowerMonitorApp;
app = PowerMonitorApp(Channels=bandChannels(40, 160), Primary=40, Targets=[36 44], Gain=30);
