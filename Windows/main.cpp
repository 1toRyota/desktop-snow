#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <chrono>
#include <cwctype>
#include <memory>
#include <string>
#include "snow.hpp"

using namespace snow;
using Clock=std::chrono::steady_clock;
namespace {
constexpr wchar_t ControllerClass[]=L"DesktopSnow.Controller";
constexpr wchar_t OverlayClass[]=L"DesktopSnow.Overlay";
constexpr wchar_t SettingsKey[]=L"Software\\DesktopSnow";
constexpr wchar_t RunKey[]=L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr UINT TrayEvent=WM_APP+1;
enum Command : UINT { Pause=101, Wind, Accumulate, Clear, StartAtLogin, Exit,
                       Light=120, Medium, Heavy, SlowMelt=130, MediumMelt, FastMelt };
constexpr Id GroundBase=Id(1)<<(sizeof(Id)*8-1);

Box box(RECT r) { return {r.left,r.top,r.right,r.bottom}; }
DWORD setting(const wchar_t* name,DWORD fallback) {
    DWORD size=sizeof(fallback), value{};
    return RegGetValueW(HKEY_CURRENT_USER,SettingsKey,name,RRF_RT_REG_DWORD,nullptr,&value,&size)==ERROR_SUCCESS?value:fallback;
}
void save(const wchar_t* name,DWORD value) {
    RegSetKeyValueW(HKEY_CURRENT_USER,SettingsKey,name,REG_DWORD,&value,sizeof(value));
}

struct Monitor { Box area, work; };
struct Overlay {
    HWND window{};
    HDC memory{};
    HBITMAP bitmap{};
    HGDIOBJ previous{};
    std::uint32_t* pixels{};
    Box area{};
    Overlay(HWND controller,Box bounds):area(bounds) {
        window=CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_TOPMOST,
            OverlayClass,L"",WS_POPUP,area.l,area.t,area.width(),area.height(),nullptr,nullptr,
            GetModuleHandleW(nullptr),nullptr);
        if (!window) return;
        memory=CreateCompatibleDC(nullptr);
        if (!memory) return;
        BITMAPINFO info{};
        info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth=area.width();
        info.bmiHeader.biHeight=-area.height();
        info.bmiHeader.biPlanes=1;
        info.bmiHeader.biBitCount=32;
        void* buffer=nullptr;
        bitmap=CreateDIBSection(memory,&info,DIB_RGB_COLORS,&buffer,nullptr,0);
        if (!bitmap) return;
        pixels=static_cast<std::uint32_t*>(buffer);
        previous=SelectObject(memory,bitmap);
        SetWindowPos(window,HWND_TOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOOWNERZORDER);
        (void)controller;
    }
    ~Overlay() {
        if (previous) SelectObject(memory,previous);
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        if (window) DestroyWindow(window);
    }
    void put(int x,int y,std::uint32_t color) {
        if (x<area.l || x>=area.r || y<area.t || y>=area.b) return;
        pixels[std::size_t(y-area.t)*area.width()+x-area.l]=color;
    }
    static std::uint32_t pixel(int r,int g,int b,int a=255) {
        return (std::uint32_t(a)<<24)|(std::uint32_t(r*a/255)<<16)|(std::uint32_t(g*a/255)<<8)|std::uint32_t(b*a/255);
    }
    void paint(const Engine& engine) {
        if (!pixels) return;
        std::fill_n(pixels,std::size_t(area.width())*area.height(),0);
        if (engine.accumulation) {
            for (std::size_t n=engine.surfaces.size();n>0;--n) {
                auto i=n-1;
                const auto& s=engine.surfaces[i];
                if (!s.collects || !s.box.overlaps(Box{area.l,area.t,area.r,area.b+32})) continue;
                const auto& drift=engine.drifts.at(s.id);
                for (int x=std::max(s.box.l,area.l);x<std::min(s.box.r,area.r);++x) {
                    float edge=s.edge(x+.5f), top=drift.top(x+.5f);
                    if (edge-top<.5f) continue;
                    for (int y=std::max(int(std::ceil(top)),area.t);y<std::min(int(std::ceil(edge)),area.b);++y) {
                        if (engine.covered(i,x+.5f,y+.5f) || engine.inFullscreen(x+.5f,y+.5f)) continue;
                        float depth=(y-top)/(edge-top);
                        if (y-top<2.5f) put(x,y,pixel(247,252,255));
                        else put(x,y,pixel(int(223-46*depth),int(245-41*depth),int(255-20*depth),244));
                    }
                }
            }
        }
        constexpr int colors[][3]={{251,254,255},{223,246,255},{197,229,255},{226,222,255}};
        for (auto f:engine.flakes) {
            if (!area.contains(f.x,f.y) || !engine.drawFlake(f)) continue;
            int x=int(std::floor(f.x/2))*2, y=int(std::floor(f.y/2))*2;
            int size=(f.shade==0?3:2);
            auto rgb=colors[f.shade%4];
            auto color=pixel(rgb[0],rgb[1],rgb[2],f.shade==0?235:190);
            for (int dy=0;dy<size;++dy) for (int dx=0;dx<size;++dx) put(x+dx,y+dy,color);
            if (f.shade==0 && f.phase>5) {
                put(x-1,y+1,color); put(x+3,y+1,color); put(x+1,y-1,color); put(x+1,y+3,color);
            }
        }
        POINT target{area.l,area.t}, origin{};
        SIZE size{area.width(),area.height()};
        BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
        if (UpdateLayeredWindow(window,nullptr,&target,&size,memory,&origin,0,&blend,ULW_ALPHA)
            && !IsWindowVisible(window)) ShowWindow(window,SW_SHOWNOACTIVATE);
    }
};

struct App {
    HWND controller{};
    HICON icon{};
    Engine engine;
    std::vector<Monitor> monitors;
    std::vector<std::unique_ptr<Overlay>> overlays;
    Clock::time_point tick=Clock::now(), lastScan{};
    bool paused{};
    DWORD intensity=std::clamp(setting(L"Intensity",1),0ul,2ul);
    DWORD melting=std::clamp(setting(L"Melting",1),0ul,2ul);
    App() {
        engine.windy=setting(L"Wind",1)!=0;
        engine.accumulation=setting(L"Accumulation",1)!=0;
        applyRates();
    }
    void applyRates() {
        constexpr float rates[]{.35f,.75f,1.45f};
        constexpr float melts[]{.08f,.22f,.65f};
        engine.intensity=rates[intensity];
        engine.melt=melts[melting];
    }
    static BOOL CALLBACK monitorProc(HMONITOR monitor,HDC,LPRECT,LPARAM arg) {
        MONITORINFO info{sizeof(info)};
        if (GetMonitorInfoW(monitor,&info))
            reinterpret_cast<App*>(arg)->monitors.push_back({box(info.rcMonitor),box(info.rcWork)});
        return TRUE;
    }
    void rebuild() {
        monitors.clear();
        EnumDisplayMonitors(nullptr,nullptr,monitorProc,reinterpret_cast<LPARAM>(this));
        overlays.clear();
        std::vector<Box> bounds;
        for (auto m:monitors) {
            bounds.push_back(m.area);
            auto overlay=std::make_unique<Overlay>(controller,m.area);
            if (overlay->pixels) overlays.push_back(std::move(overlay));
        }
        engine.configure(std::move(bounds));
        lastScan={};
    }
    struct Scan { App* app; std::vector<Surface> items; HWND foreground; };
    static BOOL CALLBACK windowProc(HWND hwnd,LPARAM arg) {
        auto& scan=*reinterpret_cast<Scan*>(arg);
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
        DWORD pid{};
        GetWindowThreadProcessId(hwnd,&pid);
        if (!pid || pid==GetCurrentProcessId()) return TRUE;
        DWORD cloaked=0;
        if (SUCCEEDED(DwmGetWindowAttribute(hwnd,DWMWA_CLOAKED,&cloaked,sizeof(cloaked))) && cloaked) return TRUE;
        wchar_t className[160]{};
        GetClassNameW(hwnd,className,160);
        std::wstring cls=className;
        if (cls==L"Progman" || cls==L"WorkerW" || cls==L"DesktopSnow.Overlay" || cls==L"Windows.UI.Core.CoreWindow") return TRUE;
        bool taskbar=cls==L"Shell_TrayWnd" || cls==L"Shell_SecondaryTrayWnd";
        RECT raw{};
        if (taskbar || FAILED(DwmGetWindowAttribute(hwnd,DWMWA_EXTENDED_FRAME_BOUNDS,&raw,sizeof(raw)))) {
            if (!GetWindowRect(hwnd,&raw)) return TRUE;
        }
        auto rect=box(raw);
        if (rect.width()<40 || rect.height()<24 || rect.width()>32768 || rect.height()>32768) return TRUE;
        Surface s{reinterpret_cast<Id>(hwnd),rect,pid};
        s.taskbar=taskbar;
        bool onScreen=false;
        auto edgeMatches=[](int a,int b){ return std::abs(a-b)<=3; };
        for (auto m:scan.app->monitors) {
            if (!rect.overlaps(m.area)) continue;
            onScreen=true;
            bool spans=edgeMatches(rect.l,m.area.l)&&edgeMatches(rect.r,m.area.r);
            s.wide|=spans;
            bool full=spans&&edgeMatches(rect.t,m.area.t)&&edgeMatches(rect.b,m.area.b);
            bool fill=edgeMatches(rect.l,m.work.l)&&edgeMatches(rect.r,m.work.r)&&edgeMatches(rect.t,m.work.t)&&edgeMatches(rect.b,m.work.b);
            if (!taskbar && hwnd==scan.foreground && (full || (fill && IsZoomed(hwnd)))) s.fullscreen=true;
        }
        if (!onScreen) return TRUE;
        LONG_PTR style=GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
        if (!taskbar && (style&WS_EX_TRANSPARENT)) return TRUE;
        bool tool=(style&WS_EX_TOOLWINDOW)!=0 || cls==L"#32768";
        s.collects=!s.fullscreen && !tool;
        s.protectsContent=taskbar || tool;
        if (!taskbar && !s.fullscreen && !IsZoomed(hwnd)) {
            int corner=0;
            if (SUCCEEDED(DwmGetWindowAttribute(hwnd,33,&corner,sizeof(corner))) && corner==1) s.radius=0;
            else {
                // A themed caption on Windows 11 has a small rounded frame.
                static const bool windows11=[] {
                    using VersionFn=LONG(WINAPI*)(OSVERSIONINFOW*);
                    auto fn=reinterpret_cast<VersionFn>(GetProcAddress(GetModuleHandleW(L"ntdll.dll"),"RtlGetVersion"));
                    OSVERSIONINFOW version{sizeof(version)};
                    return fn && fn(&version)==0 && version.dwBuildNumber>=22000;
                }();
                if (windows11 && (GetWindowLongPtrW(hwnd,GWL_STYLE)&WS_CAPTION))
                    s.radius=(corner==3?4.0f:8.0f)*GetDpiForWindow(hwnd)/96.0f;
            }
        }
        scan.items.push_back(s);
        return TRUE;
    }
    void scan() {
        Scan result{this,{},GetForegroundWindow()};
        EnumWindows(windowProc,reinterpret_cast<LPARAM>(&result));
        for (auto& candidate:result.items) {
            for (const auto& front:result.items) {
                if (candidate.id==front.id) break;
                if (front.fullscreen && front.box.l<=candidate.box.l && front.box.t<=candidate.box.t
                    && front.box.r>=candidate.box.r && front.box.b>=candidate.box.b) {
                    candidate.collects=false;
                    break;
                }
            }
            if (candidate.taskbar) {
                candidate.collects=std::none_of(result.items.begin(),result.items.end(),[&](const Surface& s){
                    return s.fullscreen && s.box.overlaps(candidate.box);
                });
            }
        }
        for (std::size_t i=0;i<monitors.size();++i) {
            auto r=monitors[i].area;
            Surface ground{GroundBase+i,Box{r.l,r.b-2,r.r,r.b}};
            ground.ground=true;
            ground.collects=std::none_of(result.items.begin(),result.items.end(),[&](const Surface& s){
                return s.fullscreen && s.box.contains(float(r.l+r.width()/2),float(r.b-3));
            });
            result.items.push_back(ground);
        }
        engine.sync(std::move(result.items),[](Id id,unsigned owner){
            if (id>=GroundBase) return false;
            auto hwnd=reinterpret_cast<HWND>(id);
            DWORD pid{};
            return IsWindow(hwnd) && GetWindowThreadProcessId(hwnd,&pid)!=0 && pid==owner;
        },!paused);
    }
    bool addTray() const {
        NOTIFYICONDATAW data{};
        data.cbSize=sizeof(data); data.hWnd=controller; data.uID=1;
        data.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP;
        data.uCallbackMessage=TrayEvent; data.hIcon=icon;
        lstrcpynW(data.szTip,L"Desktop Snow",ARRAYSIZE(data.szTip));
        return Shell_NotifyIconW(NIM_ADD,&data)!=FALSE;
    }
    void removeTray() const {
        NOTIFYICONDATAW data{};
        data.cbSize=sizeof(data); data.hWnd=controller; data.uID=1;
        Shell_NotifyIconW(NIM_DELETE,&data);
    }
    bool startsAtLogin() const {
        return RegGetValueW(HKEY_CURRENT_USER,RunKey,L"DesktopSnow",RRF_RT_REG_SZ,nullptr,nullptr,nullptr)==ERROR_SUCCESS;
    }
    bool toggleLogin() {
        if (startsAtLogin()) return RegDeleteKeyValueW(HKEY_CURRENT_USER,RunKey,L"DesktopSnow")==ERROR_SUCCESS;
        wchar_t path[32768];
        DWORD len=GetModuleFileNameW(nullptr,path,ARRAYSIZE(path));
        if (!len || len>=ARRAYSIZE(path)) return false;
        std::wstring command=L"\""+std::wstring(path,len)+L"\"";
        return RegSetKeyValueW(HKEY_CURRENT_USER,RunKey,L"DesktopSnow",REG_SZ,
            command.c_str(),DWORD((command.size()+1)*sizeof(wchar_t)))==ERROR_SUCCESS;
    }
    void menu() {
        HMENU popup=CreatePopupMenu();
        auto item=[&](UINT id,const wchar_t* label,bool checked=false){
            AppendMenuW(popup,MF_STRING|(checked?MF_CHECKED:0),id,label);
        };
        item(Pause,paused?L"Продолжить снегопад":L"Пауза");
        item(Wind,L"Порывы ветра",engine.windy);
        item(Accumulate,L"Сугробы на окнах и панели задач",engine.accumulation);
        item(Clear,L"Убрать весь снег");
        auto rates=CreatePopupMenu(), melt=CreatePopupMenu();
        const wchar_t* rateLabels[]={L"Лёгкий снег",L"Обычный снег",L"Сильный снег"};
        const wchar_t* meltLabels[]={L"Медленно",L"Обычно",L"Быстро"};
        for (UINT i=0;i<3;++i) {
            AppendMenuW(rates,MF_STRING|(i==intensity?MF_CHECKED:0),Light+i,rateLabels[i]);
            AppendMenuW(melt,MF_STRING|(i==melting?MF_CHECKED:0),SlowMelt+i,meltLabels[i]);
        }
        AppendMenuW(popup,MF_POPUP,reinterpret_cast<UINT_PTR>(rates),L"Интенсивность");
        AppendMenuW(popup,MF_POPUP,reinterpret_cast<UINT_PTR>(melt),L"Таяние");
        AppendMenuW(popup,MF_SEPARATOR,0,nullptr);
        item(StartAtLogin,L"Запускать при входе",startsAtLogin());
        item(Exit,L"Завершить Desktop Snow");
        POINT cursor{};
        GetCursorPos(&cursor);
        SetForegroundWindow(controller);
        UINT selected=TrackPopupMenu(popup,TPM_RETURNCMD|TPM_RIGHTBUTTON,cursor.x,cursor.y,0,controller,nullptr);
        PostMessageW(controller,WM_NULL,0,0);
        DestroyMenu(popup);
        if (selected==Pause) paused=!paused;
        else if (selected==Wind) { engine.windy=!engine.windy; save(L"Wind",engine.windy); }
        else if (selected==Accumulate) { engine.accumulation=!engine.accumulation; engine.clear(); save(L"Accumulation",engine.accumulation); }
        else if (selected==Clear) engine.clear();
        else if (selected==StartAtLogin && !toggleLogin())
            MessageBoxW(controller,L"Windows не удалось изменить настройку автозапуска.",L"Desktop Snow",MB_OK|MB_ICONWARNING);
        else if (selected==Exit) { DestroyWindow(controller); return; }
        else if (selected>=Light && selected<=Heavy) { intensity=selected-Light; save(L"Intensity",intensity); }
        else if (selected>=SlowMelt && selected<=FastMelt) { melting=selected-SlowMelt; save(L"Melting",melting); }
        applyRates();
        for (const auto& overlay:overlays) overlay->paint(engine);
    }
    void frame() {
        auto now=Clock::now();
        float dt=std::chrono::duration<float>(now-tick).count();
        tick=now;
        bool refresh=now-lastScan>std::chrono::milliseconds(paused?200:66);
        if (refresh) { scan(); lastScan=now; }
        if (!paused) engine.step(dt);
        if (!paused || refresh) for (const auto& overlay:overlays) overlay->paint(engine);
    }
};
App* app=nullptr;
UINT taskbarCreated{};
LRESULT CALLBACK overlayMessages(HWND hwnd,UINT msg,WPARAM w,LPARAM l) {
    if (msg==WM_NCHITTEST) return HTTRANSPARENT;
    if (msg==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    return DefWindowProcW(hwnd,msg,w,l);
}
LRESULT CALLBACK controllerMessages(HWND hwnd,UINT msg,WPARAM w,LPARAM l) {
    if (taskbarCreated && msg==taskbarCreated && app) { app->addTray(); return 0; }
    switch (msg) {
    case WM_TIMER: if (app) app->frame(); return 0;
    case WM_DISPLAYCHANGE: case WM_SETTINGCHANGE: if (app) app->rebuild(); return 0;
    case TrayEvent:
        if (app && (l==WM_RBUTTONUP || l==WM_LBUTTONUP || l==WM_CONTEXTMENU)) app->menu();
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd,1);
        if (app) { app->removeTray(); app->overlays.clear(); }
        PostQuitMessage(0);
        return 0;
    default: return DefWindowProcW(hwnd,msg,w,l);
    }
}
HICON snowIcon() {
    constexpr int side=32;
    BITMAPINFO info{};
    info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=side; info.bmiHeader.biHeight=-side;
    info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32;
    void* raw=nullptr;
    HBITMAP color=CreateDIBSection(nullptr,&info,DIB_RGB_COLORS,&raw,nullptr,0);
    if (!color || !raw) { if (color) DeleteObject(color); return nullptr; }
    auto pixels=static_cast<std::uint32_t*>(raw);
    for (int y=0;y<side;++y) for (int x=0;x<side;++x) {
        int dx=x-15,dy=y-15;
        bool inside=dx*dx+dy*dy<=142;
        bool arm=std::abs(dx)<=1 || std::abs(dy)<=1 || std::abs(dx-dy)<=1 || std::abs(dx+dy)<=1;
        pixels[y*side+x]=inside?(arm?0xffeafaffu:0xff183348u):0;
    }
    BYTE mask[side*side/8]{};
    HBITMAP mono=CreateBitmap(side,side,1,1,mask);
    ICONINFO iconInfo{TRUE,0,0,mono,color};
    HICON icon=mono?CreateIconIndirect(&iconInfo):nullptr;
    if (mono) DeleteObject(mono);
    DeleteObject(color);
    return icon;
}
}
int WINAPI WinMain(HINSTANCE instance,HINSTANCE,LPSTR,int) {
    HANDLE single=CreateMutexW(nullptr,FALSE,L"Local\\DesktopSnow.Windows");
    if (!single || GetLastError()==ERROR_ALREADY_EXISTS) { if(single) CloseHandle(single); return 0; }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    App state;
    app=&state;
    state.icon=snowIcon();
    WNDCLASSW overlay{};
    overlay.hInstance=instance; overlay.lpszClassName=OverlayClass; overlay.lpfnWndProc=overlayMessages;
    WNDCLASSW controller{};
    controller.hInstance=instance; controller.lpszClassName=ControllerClass;
    controller.lpfnWndProc=controllerMessages; controller.hIcon=state.icon;
    if (!RegisterClassW(&overlay) || !RegisterClassW(&controller)) {
        if (state.icon) DestroyIcon(state.icon);
        CloseHandle(single);
        return 1;
    }
    state.controller=CreateWindowExW(WS_EX_TOOLWINDOW,ControllerClass,L"Desktop Snow",WS_POPUP,
        0,0,0,0,nullptr,nullptr,instance,nullptr);
    taskbarCreated=RegisterWindowMessageW(L"TaskbarCreated");
    if (!state.controller || !state.addTray()) {
        MessageBoxW(nullptr,L"Не удалось запустить значок Desktop Snow в области уведомлений.",L"Desktop Snow",MB_OK|MB_ICONERROR);
        if (state.controller) DestroyWindow(state.controller);
        if (state.icon) DestroyIcon(state.icon);
        CloseHandle(single);
        return 1;
    }
    state.rebuild();
    if (state.overlays.empty() || !SetTimer(state.controller,1,33,nullptr)) {
        MessageBoxW(state.controller,L"Не удалось создать слой снега для дисплея.",L"Desktop Snow",MB_OK|MB_ICONERROR);
        DestroyWindow(state.controller);
        if (state.icon) DestroyIcon(state.icon);
        CloseHandle(single);
        return 1;
    }
    MSG message{};
    int result;
    while ((result=GetMessageW(&message,nullptr,0,0))>0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (IsWindow(state.controller)) DestroyWindow(state.controller);
    if (state.icon) DestroyIcon(state.icon);
    CloseHandle(single);
    return result<0?1:0;
}
