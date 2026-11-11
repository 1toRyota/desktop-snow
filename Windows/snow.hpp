#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <unordered_map>
#include <vector>

namespace snow {
using Id = std::uintptr_t;
struct Box {
    int l{}, t{}, r{}, b{};
    int width() const { return r-l; }
    int height() const { return b-t; }
    bool contains(float x, float y) const { return x>=l && x<r && y>=t && y<b; }
    bool overlaps(Box other) const { return l<other.r && r>other.l && t<other.b && b>other.t; }
};
struct Surface {
    Id id;
    Box box;
    unsigned owner{};
    float radius{};
    bool collects{true}, fullscreen{}, wide{}, ground{}, taskbar{}, protectsContent{};
    float normal(float x) const {
        if (radius<=0) return 1;
        float dx=std::clamp(1-std::min(x-box.l, box.r-x)/radius, 0.0f, 1.0f);
        return std::sqrt(1-dx*dx);
    }
    float edge(float x) const { return box.t + radius*(1-normal(x)); }
    bool contains(float x,float y) const {
        return box.contains(x,y) && y>=edge(x) && y<box.b-(edge(x)-box.t);
    }
};
struct Drift {
    Surface surface;
    std::vector<float> heights;
    static constexpr int spacing=5;
    explicit Drift(Surface s): surface(s), heights(size(s)) {}
    static std::size_t size(Surface s) { return (s.box.width()+spacing-1)/spacing+1; }
    float cap(float x) const {
        float u=x-surface.box.l, phase=float(surface.id%997)*0.618f;
        if (surface.taskbar) return 14+3*std::sin(u/29+phase);
        if (surface.ground) return 24;
        return 20+5*std::sin(u/19+phase)+3*std::sin(u/8.5f+phase*1.7f);
    }
    float top(float x) const {
        float pos=std::clamp((x-surface.box.l)/spacing,0.0f,float(heights.size()-1));
        auto i=std::size_t(pos);
        float h=std::lerp(heights[i],heights[std::min(i+1,heights.size()-1)],pos-i);
        float support=std::clamp((surface.normal(x)-0.7071f)/0.2429f,0.0f,1.0f);
        return surface.edge(x)-std::floor(std::min(h,cap(x))*0.5f)*2*support*support*(3-2*support);
    }
    void deposit(float x,float amount) {
        int center=std::clamp(int((x-surface.box.l)/spacing),0,int(heights.size())-1);
        constexpr float weights[]{1,.75f,.35f,.1f};
        for (int i=std::max(0,center-3);i<=std::min(int(heights.size())-1,center+3);++i) {
            float at=std::min(float(surface.box.r),float(surface.box.l+i*spacing));
            if (surface.normal(at)>0.7071f)
                heights[i]=std::min(cap(at)+(surface.taskbar?4.0f:0.0f),heights[i]+amount*weights[std::abs(i-center)]);
        }
    }
};
struct Flake {
    float x,y,vx,vy,phase;
    unsigned shade;
    bool ambient{}, shed{};
    Id source{};
};
class Engine {
    std::mt19937 random{std::random_device{}()};
    std::vector<float> topCredit, sideCredit;
    float clock{}, gustTime{}, targetWind{};
    unsigned serial{};
    float between(float a,float b) { return std::uniform_real_distribution<float>(a,b)(random); }
    void spawn(float x,float y,bool ambient,Id source=0) {
        if (flakes.size()>=3500) return;
        flakes.push_back({x,y,between(-6,6),between(26,67),between(0,6.28f),
                         unsigned(random()%4),ambient,source!=0,source});
    }
    void release(Drift& drift,float fraction) {
        for (std::size_t i=0;i<drift.heights.size();++i) {
            float mass=drift.heights[i]*fraction;
            float x=std::min(float(drift.surface.box.r-1),float(drift.surface.box.l+i*Drift::spacing));
            for (int n=0;n<std::min(4,int(mass/2));++n) {
                auto count=flakes.size();
                spawn(x,drift.top(x),false,drift.surface.id);
                if (flakes.size()>count) flakes.back().vx=between(-55,55);
            }
            drift.heights[i]-=mass;
        }
    }
public:
    std::vector<Box> monitors;
    std::vector<Surface> surfaces; // Front to back, including non-collecting occluders.
    std::unordered_map<Id,Drift> drifts;
    std::vector<Flake> flakes;
    float intensity=.75f, melt=.22f, wind{};
    bool windy=true, accumulation=true;
    void configure(std::vector<Box> layout) {
        monitors=std::move(layout);
        topCredit.assign(monitors.size(),0);
        sideCredit.assign(monitors.size(),0);
    }
    void clear() {
        flakes.clear();
        for (auto& [id,drift]:drifts) std::fill(drift.heights.begin(),drift.heights.end(),0);
    }
    template<class Keep> void sync(std::vector<Surface> incoming,Keep keep,bool shed) {
        for (auto it=drifts.begin();it!=drifts.end();) {
            bool present=std::any_of(incoming.begin(),incoming.end(),[&](auto s){return s.id==it->first;});
            if (!present && !keep(it->first,it->second.surface.owner)) it=drifts.erase(it);
            else ++it;
        }
        for (auto s:incoming) {
            if (!s.collects) continue;
            auto it=drifts.find(s.id);
            if (it!=drifts.end() && it->second.surface.owner!=s.owner) {
                drifts.erase(it);
                it=drifts.end();
            }
            if (it==drifts.end()) { drifts.emplace(s.id,Drift(s)); continue; }
            auto& drift=it->second;
            const auto old=drift.surface.box;
            bool visible=std::any_of(surfaces.begin(),surfaces.end(),[&](auto previous){return previous.id==s.id && previous.collects;});
            if (shed && visible && !s.ground) {
                float change=std::hypot(float(s.box.l-old.l),float(s.box.t-old.t))+std::abs(s.box.width()-old.width())*.35f;
                if (change>2) release(drift,std::min(1.0f,change/125));
            }
            drift.heights.resize(Drift::size(s),0);
            drift.surface=s;
        }
        surfaces=std::move(incoming);
    }
    bool covered(std::size_t index,float x,float y) const {
        for (std::size_t j=0;j<index;++j)
            if (!surfaces[j].ground && surfaces[j].contains(x,y)) return true;
        return false;
    }
    bool inFullscreen(float x,float y) const {
        return std::any_of(surfaces.begin(),surfaces.end(),[&](auto s){return s.fullscreen && s.box.contains(x,y);});
    }
    bool drawFlake(const Flake& f) const {
        if (!f.ambient && inFullscreen(f.x,f.y)) return false;
        for (const auto& s:surfaces)
            if (s.protectsContent && s.contains(f.x,f.y)) return false;
        return true;
    }
    void step(float dt) {
        dt=std::clamp(dt,0.0f,.05f);
        clock+=dt;
        if (clock>=gustTime) { targetWind=between(-65,65); gustTime=clock+between(5,14); }
        wind+=((windy?targetWind:0)-wind)*dt*.45f;
        for (std::size_t i=0;i<monitors.size();++i) {
            auto m=monitors[i];
            topCredit[i]+=dt*intensity*m.width()/17;
            while (topCredit[i]>=1) {
                --topCredit[i];
                bool ambient=(++serial%20)==0;
                float x=between(float(m.l),float(m.r));
                auto full=std::find_if(surfaces.begin(),surfaces.end(),[&](auto s){return s.fullscreen && s.box.overlaps(m) && x>=s.box.l && x<s.box.r;});
                if (full==surfaces.end()) spawn(x,float(m.t-4),ambient);
                else if (ambient) spawn(x,float(std::max(m.t,full->box.t)+2),true);
            }
            sideCredit[i]+=dt*std::max(0.0f,std::abs(wind)-8)*intensity*m.height()*.88f/(17*43);
            while (sideCredit[i]>=1) {
                --sideCredit[i];
                float x=float(wind>0?m.l-4:m.r+4), y=between(float(m.t),m.t+m.height()*.88f);
                if (std::none_of(monitors.begin(),monitors.end(),[&](auto other){return other.contains(x,y);}))
                    spawn(x,y,(++serial%20)==0);
            }
        }
        std::size_t kept=0;
        for (auto f:flakes) {
            float oldY=f.y, oldX=f.x;
            f.x+=(f.vx+wind+std::sin(clock*1.3f+f.phase)*12)*dt;
            if (f.shed) f.vy=std::min(240.0f,f.vy+100*dt);
            f.y+=f.vy*dt;
            if (!f.ambient && inFullscreen(f.x,f.y)) continue;
            if (!f.ambient && std::any_of(surfaces.begin(),surfaces.end(),[&](auto s) {
                if (!s.wide || oldX==f.x) return false;
                float edge;
                if (oldX<s.box.l && f.x>=s.box.l) edge=float(s.box.l);
                else if (oldX>=s.box.r && f.x<s.box.r) edge=float(s.box.r);
                else return false;
                float y=std::lerp(oldY,f.y,(edge-oldX)/(f.x-oldX));
                return y>=s.box.t && y<s.box.b;
            })) continue;
            Drift* hit=nullptr;
            float hitY=1e10f;
            if (accumulation) for (std::size_t i=0;i<surfaces.size();++i) {
                auto s=surfaces[i];
                if (!s.collects || s.id==f.source || f.x<s.box.l || f.x>=s.box.r || s.normal(f.x)<.7071f) continue;
                if (inFullscreen(f.x,s.edge(f.x))) continue;
                auto& drift=drifts.at(s.id);
                float top=drift.top(f.x);
                if (oldY+1<=top && f.y+1>=top && top<hitY && !covered(i,f.x,s.edge(f.x)-.5f)) {
                    hit=&drift;
                    hitY=top;
                }
            }
            if (hit) { hit->deposit(f.x,1.15f); continue; }
            if (std::any_of(monitors.begin(),monitors.end(),[&](auto m){return Box{m.l-90,m.t-90,m.r+90,m.b+90}.contains(f.x,f.y);}))
                flakes[kept++]=f;
        }
        flakes.resize(kept);
        for (const auto& s:surfaces) if (s.collects) {
            auto& drift=drifts.at(s.id);
            for (std::size_t i=0;i<drift.heights.size();++i) {
                auto& h=drift.heights[i];
                h=std::max(0.0f,h-melt*dt);
                if (s.taskbar && h>=drift.cap(float(s.box.l+i*Drift::spacing))+2) {
                    float x=std::min(float(s.box.r-1),float(s.box.l+i*Drift::spacing));
                    if (x>=s.box.l) spawn(x,drift.top(x),false,s.id);
                    h-=2;
                }
            }
        }
    }
};
}
