#include "snow.hpp"
#include <cassert>
#include <iostream>
using namespace snow;

int main() {
    Engine e;
    auto keep=[](Id,unsigned){return true;};
    const Box display{0,0,1200,800};
    e.configure({display});
    e.intensity=0;
    e.windy=false;
    e.melt=0;
    Surface window{1,{0,100,1200,700},7};
    window.wide=true;
    e.sync({window},keep,true);
    e.flakes={
        {-1,200,60,30,0,0,false},
        {1201,200,-60,30,0,0,false},
        {-1,200,60,30,0,0,true},
        {300,95,0,100,0,0,false}
    };
    e.step(.05f);
    assert(e.flakes.size()==1 && e.flakes.front().ambient);
    const auto mass=e.drifts.at(1).heights;
    assert(*std::max_element(mass.begin(),mass.end())>0);

    Surface full{2,display,8};
    full.collects=false;
    full.fullscreen=true;
    e.sync({full},keep,true);
    e.flakes.clear();
    e.intensity=1;
    for(int i=0;i<60;++i) e.step(1.0f/30);
    assert(!e.flakes.empty());
    assert(std::all_of(e.flakes.begin(),e.flakes.end(),[&](auto f){return f.ambient && f.y>display.t;}));
    assert(e.drifts.at(1).heights==mass);
    e.sync({window},keep,true);
    assert(e.drifts.at(1).heights==mass);
    e.sync({},[](Id,unsigned){return false;},false);
    assert(e.drifts.empty());

    Surface rounded{3,{100,100,600,450},7,20};
    Surface widget{4,{0,0,300,300},9};
    e.sync({rounded,widget},keep,true);
    assert(e.covered(1,200,120));
    assert(!e.covered(1,100,101));
    auto& drift=e.drifts.at(3);
    for(int x=100;x<600;x+=5) drift.deposit(float(x),50);
    assert(drift.top(100)==rounded.edge(100));
    assert(drift.top(230)<rounded.edge(230));
    assert(std::abs(drift.top(230)-drift.top(260))>=2);
    e.clear();
    assert(e.flakes.empty() && drift.top(230)==rounded.edge(230));
    std::cout << "PASS: top/side snowfall, accumulation, fullscreen archive, clipping, rounded corners, varied crests and clearing\n";
}
