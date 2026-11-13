% main  5 GHz 채널 모니터 진입점 (수신 전용).
%   USRP 로 원하는 채널의 수신 전력과, AP 가 실제로 쓰는 송신 대역폭을 관찰한다.

close all force;   % 열려 있는 창까지 닫는다 (창이 남아 있으면 클래스가 갱신되지 않는다)
clear classes;     % 이전에 올라간 클래스 정의를 비워 수정한 코드를 반영한다
clc;

rootDir = fileparts(mfilename("fullpath"));
addpath(fullfile(rootDir, "device"), fullfile(rootDir, "measure"), fullfile(rootDir, "monitor"), ...
    fullfile(rootDir, "gui"));

% 빈 상태로 시작한다. 창에서 USRP 를 고르고 채널 맵을 클릭해 관찰할 채널을 정한다.
% 채널을 정해 둔 채 시작하려면: app = PowerMonitorApp(Channels=bandChannels(40, 160));
app = PowerMonitorApp;
