function outputs = animate_vibration_3d(result,p,outdir,options)
% [읽기 안내] 계산된 몸체 자세를 모터·축·센서·지지대가 있는 3D 장면으로 재생합니다.
% 입력 result.t는 N×1(s), q는 N×6([이동 m, 회전 rad]), accel은 N×3(m/s^2)입니다.
% p.geometry는 가정한 형상, options는 표시 설정이며 출력 outputs에 그림·영상 경로를 담습니다.
% [주1] 연구 실행기의 result는 가상 물리 모델 결과입니다. 아래 영문 설명의
% measured라는 표현은 실제 계측 파일이 입력되었다는 뜻으로 읽지 마세요.
% 애니메이션은 새 운동방정식을 풀지 않고 입력된 궤적을 시각화합니다.
%ANIMATE_VIBRATION_3D Render a six-DOF motor and its measured vibration.
% outputs = animate_vibration_3d(result,p,outdir,options)
%
% Required result fields: t [s], q [m,m,m,rad,rad,rad], accel [m/s^2],
% rotor_angle [rad], rpm [rev/min]. q is CG displacement about the static
% equilibrium. Dynamic sensor acceleration excludes gravity. The geometry is
% illustrative: this is an uncalibrated research model, not a CAD digital twin.
%
% options (all optional):
%   visible          'on' (default) or 'off'
%   exportVideo      false (default); MPEG-4, then Motion JPEG AVI fallback
%   maxFrames        240 (default), uniform samples from the result timeline
%   motionScale      30 (default); DISPLAY translation AND rotation multiplier
%   rotorSpeedScale  0.02 (default); DISPLAY rotor-angle multiplier
%   frameRate        30 (default), exported video frames per second
%   realtime         false (default); pace interactive playback by physical time
%   closeFigure      true for invisible figures, false for visible figures
%
% The plots, printed angle, displacement and acceleration are always physical
% values. Rotor-angle slowing is explicitly labelled because normal movie
% frame rates cannot resolve the physical rotor speed without temporal alias.
% Video duration is nFrames/frameRate; physical time is printed in each frame.
% A PNG at maximum CG translation is always saved. No simulation data change.
% Uses MATLAB graphics only: Simscape/Robotics/VR toolboxes are not needed.

if nargin < 3 || isempty(outdir), outdir = fullfile(pwd,'reports'); end
if nargin < 4 || isempty(options), options = struct; end
options = set_default(options,'visible','on');
options = set_default(options,'exportVideo',false);
options = set_default(options,'maxFrames',240);
options = set_default(options,'motionScale',30);
% [주2] motionScale은 장면 속 이동과 회전을 함께 확대하는 표시 배율입니다.
% 실제 계산된 변위·각도는 바뀌지 않으며 오른쪽 그래프에는 원래 수치를 표시합니다.
options = set_default(options,'rotorSpeedScale',0.02);
% 빠른 회전은 영상 프레임만으로 구분하기 어려워 회전자 표시 각도를 줄입니다.
% 이는 실제 회전수를 바꾸는 설정이 아니며 잔상·역회전처럼 보이는 에일리어싱도 가능합니다.
options = set_default(options,'frameRate',30);
options = set_default(options,'realtime',false);
options = set_default(options,'closeFigure',strcmpi(options.visible,'off'));
validateattributes(options.motionScale,{'numeric'},{'scalar','finite','positive'});
validateattributes(options.rotorSpeedScale,{'numeric'},{'scalar','finite','positive'});
validateattributes(options.maxFrames,{'numeric'},{'scalar','integer','>=',2});
validateattributes(options.frameRate,{'numeric'},{'scalar','finite','positive'});
assert(any(strcmpi(options.visible,{'on','off'})), 'visible must be on or off.');
t = result.t(:); q = result.q; accel = result.accel;
validateattributes(t,{'numeric'},{'column','finite','real','nonempty'});
assert(numel(t)>=2 && all(diff(t)>0),'Time must be strictly increasing.');
validateattributes(q,{'numeric'},{'size',[numel(t),6],'finite','real'});
validateattributes(accel,{'numeric'},{'size',[numel(t),3],'finite','real'});
rotorAngle = result.rotor_angle(:); rpm = result.rpm(:);
validateattributes(rotorAngle,{'numeric'},{'size',[numel(t),1],'finite','real'});
validateattributes(rpm,{'numeric'},{'size',[numel(t),1],'finite','real'});
assert(isstruct(p) && isfield(p,'geometry'),'p.geometry is required.');
g = p.geometry;
validateattributes(g.body_size,{'numeric'},{'size',[1,3],'finite','positive'});
validateattributes(g.mount_points,{'numeric'},{'size',[4,3],'finite','real'});
validateattributes(g.sensor_position,{'numeric'},{'size',[1,3],'finite','real'});
validateattributes(g.shaft_length,{'numeric'},{'scalar','finite','positive'});
validateattributes(g.rotor_radius,{'numeric'},{'scalar','finite','positive'});
if ~exist(outdir,'dir'), mkdir(outdir); end
scenario = 'scenario';
if isfield(result,'scenario')
    if isstruct(result.scenario) && isfield(result.scenario,'name')
        scenario = char(result.scenario.name);
    elseif ischar(result.scenario) || isstring(result.scenario)
        scenario = char(result.scenario);
    end
end
fileTag = regexprep(scenario,'[^A-Za-z0-9_-]','_');
if isempty(fileTag), fileTag = 'scenario'; end
outputs = struct('snapshot',fullfile(outdir,['vibration_3d_' fileTag '.png']), ...
    'video','','figure',[],'motionScale',options.motionScale, ...
    'rotorSpeedScale',options.rotorSpeedScale,'snapshotTime',NaN, ...
    'videoFrameCount',0,'videoDuration',0);
indices = unique(round(linspace(1,numel(t),min(options.maxFrames,numel(t)))));
% [주3] 1 kHz의 모든 샘플을 영상으로 그리지 않고 시간축에서 일부를 골라 재생합니다.
% 영상 길이는 프레임 수/frameRate이며 실험 시간과 같지 않을 수 있습니다.
timelineSpeed = (t(end)-t(1))*options.frameRate/(numel(indices)-1);
outputs.videoTimelineSpeed = timelineSpeed;

fig = figure('Color',[0.055 0.075 0.11],'Name','Vibration NPU | 6-DOF research scene', ...
    'NumberTitle','off','Visible',options.visible,'Position',[60 60 1480 860]);
figureCleanup = onCleanup(@() cleanup_figure(fig,options.closeFigure)); %#ok<NASGU>
annotation(fig,'textbox',[0.035 0.935 0.94 0.045], ...
    'String',['6-DOF motor vibration  |  ' scenario],'Interpreter','none', ...
    'Color',[0.93 0.96 1],'FontSize',19,'FontWeight','bold','EdgeColor','none');
annotation(fig,'textbox',[0.035 0.898 0.94 0.035], ...
    'String',sprintf(['Illustrative geometry / uncalibrated parameters  |  ' ...
    'Pose display gain x%.3g  |  Rotor angle display factor %.3g'], ...
    options.motionScale,options.rotorSpeedScale), ...
    'Color',[0.69 0.79 0.90],'FontSize',10,'EdgeColor','none');

ax = axes('Parent',fig,'Position',[0.035 0.225 0.62 0.66]);
style_axes(ax); hold(ax,'on'); axis(ax,'equal'); view(ax,[-36 24]);
xlabel(ax,'X / shaft axis [m]'); ylabel(ax,'Y [m]'); zlabel(ax,'Z [m]');
set(ax,'Projection','perspective');
L = g.body_size(1); R = min(g.body_size(2:3))/2;
shaftRadius = R*0.16; rotorX = L/2+g.shaft_length*0.70;
springLength = max(0.022,0.48*g.body_size(3));
baseTop = min(g.mount_points(:,3))-springLength;
baseHalf = [max(L*0.78,rotorX+g.rotor_radius*0.15), ...
    max(g.body_size(2)*0.85,g.rotor_radius*1.25)];
draw_box(ax,[0 0 baseTop-0.006],[2*baseHalf 0.012],[0.23 0.28 0.35]);
for ix = [-1 1]
    for iy = [-1 1]
        draw_box(ax,[ix*baseHalf(1)*0.85 iy*baseHalf(2)*0.80 baseTop+0.001], ...
            [0.008 0.008 0.003],[0.63 0.70 0.77]);
    end
end
body = hgtransform('Parent',ax);
% [주4] 몸체에 속한 그림은 공통 좌표변환 아래 둡니다. 몸체가 움직이면
% 센서·축도 함께 움직이며, 회전자는 몸체 안에서 한 번 더 회전합니다.
draw_cylinder_x(body,[-L/2 0 0],L,R,[0.22 0.48 0.66]);
for x = linspace(-0.39*L,0.37*L,10)
    draw_cylinder_x(body,[x 0 0],0.013*L,1.075*R,[0.37 0.62 0.76]);
end
draw_cylinder_x(body,[-L/2-0.003 0 0],0.007,R*0.96,[0.15 0.26 0.34]);
draw_cylinder_x(body,[L/2-0.003 0 0],0.007,R*0.96,[0.15 0.26 0.34]);
draw_cylinder_x(body,[L/2 0 0],g.shaft_length,shaftRadius,[0.74 0.79 0.83]);
plot3_local(body,[-0.60*L L/2+g.shaft_length], [0 0],[0 0], ...
    'Color',[0.75 0.84 0.90],'LineStyle','--','LineWidth',0.7);
for k = 1:4
    draw_box(body,g.mount_points(k,:)+[0 0 0.004],[0.022 0.015 0.008], ...
        [0.27 0.41 0.51]);
end
sensorSize = [0.019 0.013 0.006];
draw_box(body,g.sensor_position+sensorSize.*[0 0 0.5],sensorSize,[0.10 0.78 0.50]);
text('Parent',body,'Position',g.sensor_position+[0 0 0.013], ...
    'String','3-axis sensor','Color',[0.48 1 0.75],'FontSize',9);
draw_triad(body,g.sensor_position+[0 0 sensorSize(3)],0.017,false);
plot3_local(body,0,0,0,'Marker','o','Color',[1 0.91 0.38], ...
    'MarkerFaceColor',[1 0.91 0.38],'MarkerSize',4);

rotor = hgtransform('Parent',body);
draw_cylinder_x(rotor,[-0.003 0 0],0.006,g.rotor_radius,[0.80 0.62 0.25]);
draw_cylinder_x(rotor,[-0.004 0 0],0.008,shaftRadius*1.7,[0.47 0.50 0.54]);
draw_cylinder_x(rotor,[0.003 g.rotor_radius*0.70 0],0.008, ...
    g.rotor_radius*0.19,[0.96 0.30 0.18]);
plot3_local(rotor,[0.004 0.004],[0 g.rotor_radius*0.70],[0 0], ...
    'Color',[1 0.91 0.63],'LineWidth',2);
text(ax,rotorX,0,g.rotor_radius+0.013,'Eccentric rotor', ...
    'Color',[1 0.80 0.43],'FontSize',9,'HorizontalAlignment','center');
anchors = g.mount_points; anchors(:,3) = baseTop+0.002;
% 지지대 아래 끝은 바닥에 고정하고 위 끝은 몸체 자세에 따라 옮깁니다.
% 코일 곡선은 시각화용 도형이며 추가적인 스프링 물리 계산을 하지 않습니다.
springs = gobjects(4,1);
for k = 1:4
    [sx,sy,sz] = spring_curve(anchors(k,:),g.mount_points(k,:),0.004,6);
    springs(k) = plot3(ax,sx,sy,sz,'Color',[0.72 0.79 0.87],'LineWidth',1.5);
end
draw_triad(ax,[-baseHalf(1)*0.80 -baseHalf(2)*0.83 baseTop+0.004],0.03,true);
trail = plot3(ax,NaN,NaN,NaN,'Color',[0.98 0.52 0.30],'LineWidth',1.2);
maxTranslation = max(abs(q(:,1:3)*options.motionScale),[],1);
% A circumscribed radius encloses every displayed rotation, so camera bounds
% remain fixed even when the pose gain makes a rotation appreciable.
bodyExtent = max(norm([rotorX+0.02 g.rotor_radius g.rotor_radius]), ...
    max(sqrt(sum(g.mount_points.^2,2))))+0.015;
limit = max(maxTranslation+bodyExtent,[baseHalf abs(baseTop)]+0.01);
xlim(ax,[-limit(1) limit(1)]); ylim(ax,[-limit(2) limit(2)]);
zlim(ax,[-limit(3) limit(3)]);
camlight(ax,'headlight'); lighting(ax,'gouraud');

colors = [0.98 0.44 0.37;0.39 0.86 0.58;0.39 0.68 1];
dispAxes = axes('Parent',fig,'Position',[0.715 0.665 0.255 0.19]);
% [주5] 변위 그래프는 m를 um로, 각도 표시는 rad를 mrad로 바꿔 읽기 쉽게 합니다.
% 이 단위 변환과 장면 확대 배율은 서로 다른 것이므로 수치를 구분해서 읽습니다.
style_axes(dispAxes); hold(dispAxes,'on');
for k=1:3, plot(dispAxes,t,q(:,k)*1e6,'Color',colors(k,:),'LineWidth',0.9); end
title(dispAxes,'Physical CG translation','Color',[0.9 0.94 1]);
ylabel(dispAxes,'Displacement [um]');
xlim(dispAxes,[t(1) t(end)]);
legend(dispAxes,{'X','Y','Z'},'Location','northeast','TextColor',[0.9 0.94 1], ...
    'Color',[0.07 0.10 0.15],'Orientation','horizontal');
dispCursor = plot(dispAxes,[t(1) t(1)],ylim(dispAxes),'w:','LineWidth',1.1);
accAxes = axes('Parent',fig,'Position',[0.715 0.405 0.255 0.19]);
style_axes(accAxes); hold(accAxes,'on');
for k=1:3, plot(accAxes,t,accel(:,k),'Color',colors(k,:),'LineWidth',0.8); end
title(accAxes,'Dynamic acceleration at sensor','Color',[0.9 0.94 1]);
ylabel(accAxes,'Acceleration [m/s^2]');
xlabel(accAxes,'Physical time [s]'); xlim(accAxes,[t(1) t(end)]);
accCursor = plot(accAxes,[t(1) t(1)],ylim(accAxes),'w:','LineWidth',1.1);
orbitAxes = axes('Parent',fig,'Position',[0.745 0.085 0.205 0.23]);
style_axes(orbitAxes); hold(orbitAxes,'on');
plot(orbitAxes,q(:,2)*1e6,q(:,3)*1e6,'Color',[0.40 0.49 0.61],'LineWidth',0.6);
orbitMarker = plot(orbitAxes,q(1,2)*1e6,q(1,3)*1e6,'o', ...
    'MarkerFaceColor',[1 0.59 0.31],'MarkerEdgeColor','none','MarkerSize',6);
title(orbitAxes,'Physical CG orbit (Y-Z)','Color',[0.9 0.94 1]);
xlabel(orbitAxes,'Y [um]');
ylabel(orbitAxes,'Z [um]'); axis(orbitAxes,'equal');
orbitLimit = max(1e-3,max(abs(q(:,2:3)),[],'all')*1e6*1.1);
xlim(orbitAxes,[-orbitLimit orbitLimit]); ylim(orbitAxes,[-orbitLimit orbitLimit]);
readout = annotation(fig,'textbox',[0.045 0.035 0.62 0.165], ...
    'String','','Color',[0.89 0.94 1],'FontSize',10,'FontName','FixedWidth', ...
    'EdgeColor',[0.28 0.38 0.48],'BackgroundColor',[0.075 0.11 0.16], ...
    'Margin',10,'Interpreter','none');
policyReadout = annotation(fig,'textbox',[0.045 0.202 0.62 0.027], ...
    'String','Physical replay; classification data not provided.',...
    'Color',[0.69 0.79 0.90],'FontSize',10,'EdgeColor','none','Interpreter','none');
hasPolicy = isfield(result,'class_stream') && isfield(result,'safety') ...
    && numel(result.class_stream)==numel(t) && isequal(size(result.safety),[numel(t),7]);

writer = []; videoCleanup = []; %#ok<NASGU>
% [주6] 영상 저장은 렌더링된 화면을 프레임별로 기록합니다. 저장된 정지 그림은
% 무게중심 이동이 가장 큰 시각을 고르며, 최대 가속도 시각과 다를 수 있습니다.
if options.exportVideo
    [writer,outputs.video] = open_video(outdir,fileTag,options.frameRate);
    videoCleanup = onCleanup(@() close_video(writer));
end
animationStart = tic;
for frame = 1:numel(indices)
    if ~isgraphics(fig), error('Vibration3D:Closed','The scene was closed during rendering.'); end
    i = indices(frame);
    update_frame(i);
    drawnow;
    if ~isempty(writer)
        % getframe may require a working desktop/display. A rendering error is
        % surfaced rather than pretending an exported video was produced.
        writeVideo(writer,getframe(fig));
        outputs.videoFrameCount = outputs.videoFrameCount+1;
    end
    if options.realtime && strcmpi(options.visible,'on')
        pause(max(0,t(i)-t(indices(1))-toc(animationStart)));
    end
end
if ~isempty(writer)
    close(writer); % Surface finalization failures; cleanup below is best-effort.
    clear videoCleanup;
    outputs.videoDuration = outputs.videoFrameCount/options.frameRate;
end
[~,peakIndex] = max(sum(q(:,1:3).^2,2));
update_frame(peakIndex); drawnow;
outputs.snapshotTime = t(peakIndex);
set(fig,'PaperPositionMode','auto','InvertHardcopy','off');
print(fig,outputs.snapshot,'-dpng','-r160');
if ~options.closeFigure, outputs.figure = fig; end

    function update_frame(i)
        % [주7] q의 roll/pitch/yaw로 표시 회전행렬을 만들고 이동 벡터를 붙입니다.
        % 그리기는 유한 회전행렬을 쓰지만 원래 역학은 작은 각도 근사라는 점은 같습니다.
        pose = eye(4); pose(1:3,1:3) = rotation_zyx(q(i,4:6)*options.motionScale);
        pose(1:3,4) = (q(i,1:3)*options.motionScale).';
        set(body,'Matrix',pose);
        rotorPose = eye(4);
        rotorPose(1:3,1:3) = rotation_zyx([rotorAngle(i)*options.rotorSpeedScale 0 0]);
        rotorPose(1,4) = rotorX;
        set(rotor,'Matrix',rotorPose);
        endpoints = (pose(1:3,1:3)*g.mount_points.'+pose(1:3,4)).';
        for j=1:4
            [sx,sy,sz] = spring_curve(anchors(j,:),endpoints(j,:),0.004,6);
            set(springs(j),'XData',sx,'YData',sy,'ZData',sz);
        end
        tailStart = max(1,i-round(0.7/median(diff(t))));
        shownTrail = q(tailStart:i,1:3)*options.motionScale;
        set(trail,'XData',shownTrail(:,1),'YData',shownTrail(:,2),'ZData',shownTrail(:,3));
        set(dispCursor,'XData',[t(i) t(i)]); set(accCursor,'XData',[t(i) t(i)]);
        set(orbitMarker,'XData',q(i,2)*1e6,'YData',q(i,3)*1e6);
        if hasPolicy
            if isfield(result,'frame_index') && i<result.frame_index(1)
                policyText='NPU: waiting for 64 samples | policy observer; forcing is prescribed';
            else
                policyText=sprintf(['NPU class %d | warn %d | derate %d | latch %d | ' ...
                    'allowed %.0f%% (observer only)'],result.class_stream(i),...
                    result.safety(i,2:4),100*result.safety(i,6));
            end
            set(policyReadout,'String',policyText);
        end
        set(readout,'String',sprintf([ ...
            't = %7.3f s   rpm = %7.1f   true rotor angle = %6.1f deg (mod 360)\n' ...
            'CG [X Y Z] = [%9.2f %9.2f %9.2f] um\n' ...
            'roll/pitch/yaw = [%8.3f %8.3f %8.3f] mrad\n' ...
            'Dynamic sensor a = [%8.3f %8.3f %8.3f] m/s^2\n' ...
            'Scene pose x%.3g; rotor angle x%.3g; movie timeline x%.3g. May alias.'], ...
            t(i),rpm(i),mod(rotorAngle(i)*180/pi,360),q(i,1:3)*1e6, ...
            q(i,4:6)*1e3,accel(i,:),options.motionScale,options.rotorSpeedScale, ...
            timelineSpeed));
    end
end

function s = set_default(s,name,value)
if ~isfield(s,name) || isempty(s.(name)), s.(name)=value; end
end

function style_axes(ax)
set(ax,'Color',[0.055 0.075 0.11],'XColor',[0.76 0.83 0.91], ...
    'YColor',[0.76 0.83 0.91],'ZColor',[0.76 0.83 0.91], ...
    'GridColor',[0.42 0.53 0.65],'GridAlpha',0.25,'FontSize',9,'Box','on');
grid(ax,'on');
end

function draw_box(parent,center,dimensions,color)
corners = [-1 -1 -1;1 -1 -1;1 1 -1;-1 1 -1; ...
    -1 -1 1;1 -1 1;1 1 1;-1 1 1];
vertices = corners.*(dimensions/2)+center;
faces = [1 4 3 2;5 6 7 8;1 2 6 5;2 3 7 6;3 4 8 7;4 1 5 8];
patch('Parent',parent,'Faces',faces,'Vertices',vertices,'FaceColor',color, ...
    'EdgeColor',color*0.66,'FaceLighting','gouraud');
end

function draw_cylinder_x(parent,start,lengthX,radius,color)
[cy,cz,cx] = cylinder(radius,40);
surface('Parent',parent,'XData',start(1)+cx*lengthX, ...
    'YData',start(2)+cy,'ZData',start(3)+cz,'FaceColor',color, ...
    'EdgeColor','none','FaceLighting','gouraud','AmbientStrength',0.45);
for k=1:2
    patch('Parent',parent,'XData',start(1)+ones(1,size(cy,2))*(k-1)*lengthX, ...
        'YData',start(2)+cy(k,:),'ZData',start(3)+cz(k,:), ...
        'FaceColor',color*0.90,'EdgeColor','none','FaceLighting','gouraud');
end
end

function h = plot3_local(parent,x,y,z,varargin)
h = line('Parent',parent,'XData',x,'YData',y,'ZData',z,varargin{:});
end

function draw_triad(parent,origin,scale,labels)
colors = [0.98 0.35 0.29;0.29 0.87 0.47;0.28 0.61 1];
names = 'XYZ';
for k=1:3
    tip = origin; tip(k)=tip(k)+scale;
    plot3_local(parent,[origin(1) tip(1)],[origin(2) tip(2)],[origin(3) tip(3)], ...
        'Color',colors(k,:),'LineWidth',2,'Marker','.', 'MarkerSize',9);
    if labels
        text('Parent',parent,'Position',tip,'String',names(k), ...
            'Color',colors(k,:),'FontWeight','bold','FontSize',10);
    end
end
end

function R = rotation_zyx(a)
% a=[roll pitch yaw]에 대해 Rz(yaw)*Ry(pitch)*Rx(roll) 순서의 회전입니다.
cx=cos(a(1)); sx=sin(a(1)); cy=cos(a(2)); sy=sin(a(2));
cz=cos(a(3)); sz=sin(a(3));
R = [cz*cy cz*sy*sx-sz*cx cz*sy*cx+sz*sx; ...
    sz*cy sz*sy*sx+cz*cx sz*sy*cx-cz*sx; -sy cy*sx cy*cx];
end

function [x,y,z] = spring_curve(bottom,top,radius,turns)
direction = top-bottom;
if norm(direction)<eps, direction=[0 0 1]; end
direction = direction/norm(direction);
helper=[1 0 0]; if abs(dot(helper,direction))>0.9, helper=[0 1 0]; end
u=cross(direction,helper); u=u/norm(u); v=cross(direction,u);
s=linspace(0,1,100).';
% Smoothly taper the coil at its two attachment points.
envelope=min(1,min(s*12,(1-s)*12));
points=bottom+s.*(top-bottom)+radius*envelope.*( ...
    cos(2*pi*turns*s).*u+sin(2*pi*turns*s).*v);
x=points(:,1); y=points(:,2); z=points(:,3);
end

function [writer,path] = open_video(outdir,fileTag,frameRate)
path = fullfile(outdir,['vibration_3d_' fileTag '.mp4']);
writer=[];
try
    writer=VideoWriter(path,'MPEG-4'); writer.FrameRate=frameRate; open(writer);
catch mp4Error
    close_video(writer);
    warning('Vibration3D:AVIFallback','MPEG-4 unavailable (%s). Trying Motion JPEG AVI.',mp4Error.message);
    path=fullfile(outdir,['vibration_3d_' fileTag '.avi']);
    writer=VideoWriter(path,'Motion JPEG AVI'); writer.FrameRate=frameRate; open(writer);
end
end

function close_video(writer)
if ~isempty(writer)
    try, close(writer); catch, end %#ok<CTCH>
end
end

function cleanup_figure(fig,shouldClose)
if shouldClose && isgraphics(fig), close(fig); end
end
