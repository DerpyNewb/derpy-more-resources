-- Run from the workspace root with Lua 5.1.
math.huge = nil   -- not safe to assume in the game's Lua (2026-10-21 handoff): the runtime must not need it
core = { add_listener = function() end }
cm = { add_first_tick_callback = function() end }
cm.log_to_dis=function(_,x,y) return x,y end
out = function() end
dofile('Modding Files/source/resource_overhaul/terrain_routes.lua')
local R = DERPY_MR_TERRAIN_ROUTES
R.vehicles={
    industrial={land='land_chd',sea='sea_chd'},
    human={land='land_wood',sea='sea_emp'},
    ['*']={land='land_wood',sea='sea_emp'}
}
cm.get_faction=function(_,key) return {is_null_interface=function() return false end,
    culture=function() return key=='seller' and 'industrial' or 'human' end} end
assert(R.vehicle('seller',false)=='land_chd' and R.vehicle('seller',true)=='sea_chd','industrial faction needs its own cart and ship')
assert(R.vehicle('buyer',true)=='sea_emp','incoming traffic must use the supplier culture')
assert(R.vehicle(nil,true)==nil,'missing ownership retains the legacy fallback')
R.vehicles={}
local switches = {route_agreements=false}
DERPY_MR_FLOWS = {mct=function(k) return switches[k] end}
assert(not R.shown('agreements') and R.shown('contracts'), 'route visibility defaults or switches lost')
local stopped = {}
DERPY_MR_FLOWS.stopped=function(f,dir,stem) return stopped[f..dir..stem]==true end
DERPY_MR_FLOWS_GOODS={{stem='grain'},{stem='iron'}}
local goods=R.goods('seller','buyer')
assert(#goods==2 and goods[1]=='grain', 'enabled trade resources must have stable icon order')
stopped.sellerexportgrain=true
goods=R.goods('seller','buyer')
assert(#goods==1 and goods[1]=='iron', 'stopped exports still advertised by carts')
stopped.buyerimportiron=true
assert(#R.goods('seller','buyer')==0, 'stopped imports still advertised by carts')
local reads=0
DERPY_MR_FLOWS.trade=function(f,preview)
    assert(preview,'display must never commit a trade')
    reads=reads+1
    return {buyer={'grain'}}
end
cm.get_faction=function(_,key) return key end
local plans={}
goods=R.carried({'grain','iron'},'seller','buyer',plans)
R.carried({'grain'},'seller','buyer',plans)
assert(#goods==1 and goods[1]=='grain' and reads==1,'icons must use allocator preview once per exporter')
assert(#R.carried({'grain'},'seller','other',plans)==0,'goods must be destined for this recipient')
DERPY_MR_FLOWS=nil
local trunk = {{0,0},{0,1},{0,2},{0,3},{0,4}}
local seen = {}
local visible = R.unshared(trunk, seen)
assert(visible[1] and visible[5], 'first road must retain its complete trunk')
visible = R.unshared({{0,4},{0,3},{0,2},{0,1},{0,0}}, seen)
assert(next(visible)==nil, 'reverse traffic duplicated the shared trunk')
visible = R.unshared({{0,1},{0,2},{0,3},{1,3},{2,3}}, seen)
assert(not visible[1] and not visible[2] and visible[3] and visible[4] and visible[5],
       'offset shared road must merge until its branch')
visible = R.unshared({{-1,2},{0,2},{1,2}}, seen)
assert(visible[2], 'crossing roads must retain their separate directions')
visible = R.unshared({{1,0},{1,1},{1,2}}, seen)
assert(visible[1] and visible[2], 'nearby parallel roads must stay on their own tiles')
local waiting={path=trunk}
local leading={path=trunk,distance=2,active=true}
assert(not R.can_depart(waiting,{leading}), 'never dispatch into an occupied shared road')
local arriving={path=trunk,reverse=true}
assert(R.can_depart(arriving,{leading}),'opposite traffic must use its separate lane')
assert(not R.can_depart({path={{-1,2},{0,2},{1,2}}},{leading}),'crossing junctions must still wait for clearance')
local reversed={trunk[5],trunk[4],trunk[3],trunk[2],trunk[1]}
assert(R.can_depart({path=reversed},{leading}),'physical direction must not depend on path table order')
local tight={{0,0},{1,0},{0,1}}
assert(not R.can_depart({path=tight,reverse=true},{{path=tight,distance=0,active=true}}),
       'opposing carts must take turns through a narrow sharp bend')
assert(R.can_depart({path={{4,0},{4,1}}},{leading}), 'disjoint roads may carry traffic together')
leading.active=false
assert(R.can_depart(waiting,{leading}), 'arrived carts must release their shared road')
-- Spacing in time, not the whole road: a hub every route shares let one cart through at a time.
local long={}
for y=0,19 do long[#long+1]={0,y} end
assert(not R.can_depart({path=long},{{path=long,distance=R.GAP-2,active=true}}),'a follower left inside the gap')
assert(R.can_depart({path=long},{{path=long,distance=R.GAP,active=true}}),'a follower must leave once its leader is the gap ahead')
local function branch(x) local p={} for i=3,1,-1 do p[#p+1]={x*i,0} end for y=0,8 do p[#p+1]={0,y} end return p end
assert(not R.can_depart({path=branch(1)},{{path=branch(-1),distance=0,active=true}}),'two branches reached their junction together')
assert(R.can_depart({path=branch(1)},{{path=branch(-1),distance=R.GAP,active=true}}),'a later branch must merge behind the gap')
local g = { w = 5, h = 5, data = string.rep('/', 25), bridges = {} }
local network = {}
for y=0,4 do network[R.index(g,1,y)]=true end
local parallel = {{2,0},{2,1},{2,2},{2,3},{2,4}}
local bundled = R.bundle(parallel,network,g)
local joined = false
for i=2,#bundled-1 do joined = joined or bundled[i][1]==1 end
assert(joined, 'nearby parallel roads must actually join the shared corridor')
assert(bundled[1][1]==2 and bundled[#bundled][1]==2, 'bundling moved a settlement endpoint')
local blocked = {w=5,h=5,data=string.rep('/',5)..'/AA//'..'/AA//'..'/AA//'..string.rep('/',5),bridges={}}
bundled = R.bundle(parallel,network,blocked)
for _,point in ipairs(bundled) do
    assert(point[1]~=1 or point[2]==0 or point[2]==4, 'bundling crossed an impassable corridor')
end
bundled = R.bundle(parallel,network,g,function(x) return x==1 end)
for _,point in ipairs(bundled) do assert(point[1]~=1,'bundling crossed hostile land') end
-- A trunk four hexes off the raw road sat outside the corridor, so the road ran beside it as a braid.
local wide = { w = 12, h = 20, data = string.rep('/', 240), bridges = {} }
local trunk4, raw4, on = {}, {}, 0
for y=0,19 do trunk4[R.index(wide,5,y)]=true raw4[#raw4+1]={1,y} end
for _,point in ipairs(R.bundle(raw4,trunk4,wide)) do if point[1]==5 then on=on+1 end end
assert(on>=10,'a road four hexes from a trunk must join it, not run beside it')
local fork_grid={w=16,h=40,data=string.rep('/',640),bridges={}}
local fork,trunk6,joined6={},{},0
for y=0,29 do fork[#fork+1]={1,y};trunk6[R.index(fork_grid,7,y)]=true end
for _,point in ipairs(R.bundle(fork,trunk6,fork_grid)) do if point[1]==7 then joined6=joined6+1 end end
assert(joined6>=15,'a shallow fork needs a connected corridor to its nearby trunk')
local function solve(a, b, limit)
    local job = R.start(g, a, b)
    for _ = 1, limit or 100 do
        local done, path = R.advance(job, 2)
        if done then return path end
    end
    error('unbounded route work')
end
local p = solve({1, 2}, {3, 2})
assert(p and p[1][1] == 1 and p[#p][1] == 3)
g.data = string.rep('/', 5) .. '//A//' .. '//A//' .. '//A//' .. '//A//'
p = solve({1, 2}, {3, 2})
local gap = false
for _, point in ipairs(p) do
    assert(not (point[1] == 2 and point[2] ~= 0), 'route crossed blocked terrain')
    gap = gap or (point[1] == 2 and point[2] == 0)
end
assert(gap, 'route did not go around wall')
g.data = string.rep('A', 25)
assert(solve({1, 2}, {3, 2}) == nil)
assert(solve({-1, 2}, {3, 2}) == nil)
assert(solve({1, 2}, {5, 2}) == nil)
g.bridges[12] = {14}
assert(solve({1, 2}, {3, 2}), 'verified bridge was ignored')

-- Hostile land is a cost, not a wall: x = 2 is enemy territory from y = 1 up.
g.data, g.bridges = string.rep('/', 25), {}
local function enemy(x, y) return x == 2 and y >= 1 end
local function crossings(path) local n = 0; for _, q in ipairs(path) do if enemy(q[1], q[2]) then n = n + 1 end end; return n end
local function solve_avoiding(a, b)
    local job = R.start(g, a, b, enemy)
    for _ = 1, 100 do local done, path = R.advance(job, 2); if done then return path end end
end
assert(#solve({1, 1}, {3, 1}) == 3, 'open ground should go straight')
p = solve_avoiding({1, 1}, {3, 1})
assert(p and crossings(p) == 0 and #p == 5, 'route crossed enemy land with a short detour open')
p = solve_avoiding({1, 4}, {3, 4})
assert(p and crossings(p) == 1, 'route should still cross when the detour is far longer')
local function fac(name, war, attitude, rebel)
    return { name = function() return name end, is_null_interface = function() return false end, is_rebel = function() return rebel == true end,
             at_war_with = function() return war == true end, diplomatic_attitude_towards = function() return attitude or 0 end }
end
local trader = fac('trader')
assert(R.hostile(fac('trader', true, -500, true), {trader}) == false, 'a party is never hostile to its own route')
assert(R.hostile(fac('x', true), {trader}) and R.hostile(fac('x', false, 0, true), {trader}), 'war and rebels')
assert(R.hostile(fac('x', false, R.AGGRESSIVE), {trader}) and not R.hostile(fac('x', false, R.AGGRESSIVE + 1), {trader}),
       'aggressive starts at very unfriendly')

-- TRADE REACH: enemy land is a wall and the road has a length limit. The detour from (1,4) to (3,4) round
-- the enemy column is 10 steps; straight through it is 2.
local function solve_walled(a, b, max)
    local job = R.start(g, a, b, enemy)
    job.wall, job.max = true, max
    local done, path
    repeat done, path = R.advance(job, 1000) until done
    return path
end
p = solve_walled({1, 4}, {3, 4})
assert(p and crossings(p) == 0 and #p == 11, 'a wall must be walked round, however long the way')
assert(solve_walled({1, 4}, {3, 4}, 10) and not solve_walled({1, 4}, {3, 4}, 9), 'a road longer than its limit is no road')
local function settled(x, y) return { owning_faction = function() return trader end, settlement = function()
    return { logical_position_x = function() return x end, logical_position_y = function() return y end } end } end
local enemy_land, open_land = { is_null_interface = function() return false end, owning_faction = function() return fac('x', true) end },
                              { is_null_interface = function() return false end, owning_faction = function() return trader end }
cm.model = function() return { campaign_name_key = function() return 'test' end,
    get_region_at_logical_position = function(_, x, y) return enemy(x, y) and enemy_land or open_land end } end
local saved_grids = R.grids
R.grids = { test = g }
local ok, why, road = R.reach(settled(1, 4), settled(3, 4), 10)
assert(ok and road and crossings(road) == 0, 'a safe road within reach keeps the trade')
local journey = R.journey(settled(1, 1), settled(3, 1))
assert(journey and crossings(journey) == 0, 'cargo must use a solved road round hostile ground')
ok, why = R.reach(settled(1, 4), settled(3, 4), 9)
assert(ok == false and why == 'enemy', 'only the enemy stands between them: ' .. tostring(why))
ok, why = R.reach(settled(1, 4), settled(3, 4), 1)
assert(ok == false and why == 'far', 'further apart than the reach, before any search')
g.data = string.rep('/', 5) .. '//A//' .. '//A//' .. '//A//' .. '//A//'   -- mountains, not enemies, in the way
ok, why = R.reach(settled(1, 4), settled(3, 2), 5)
assert(ok == false and why == 'far', 'a long way round with no enemy to blame is too far: ' .. tostring(why))
g.data = string.rep('/', 25)
assert(R.reach(settled(1, 4), settled(3, 4), 9) == false, 'the grid restored')
local byte,decodes=string.byte,0
string.byte=function(s,i) if s==g.data then decodes=decodes+1 end return byte(s,i) end
R.reach(settled(1,0),settled(3,0),10)
local first_decodes=decodes
R.reach(settled(1,0),settled(3,0),10)
string.byte=byte
assert(decodes==first_decodes,'static native edges must not be decoded again for each treaty')
R.grids = {}
assert(R.reach(settled(1, 4), settled(3, 4), 1) == true, 'a map with no grid never stops trade')
assert(R.journey(settled(1, 4), settled(3, 4)) == nil, 'unknown maps retain legacy shipment positions')
R.grids, cm.model = saved_grids, nil

local empty = { num_items = function() return 0 end }
local faction = { culture=function() return 'human' end, name = function() return 'viewer' end, is_null_interface = function() return false end,
                  factions_trading_with = function() return false end, factions_met = function() return empty end,
                  region_list = function() return empty end, get_foreign_visible_regions_for_player = function() return empty end }
local ships = { { f='viewer', from='a', to='b', x=1, y=2 } }
DERPY_MR_FLOWS = { ships = function() return ships end, routes = function() return {} end,
                  capital = function() return nil end, stopped=function() return false end }
R.grid = g
R.cache['a>b'] = { {1,2}, {1,1}, {1,0}, {2,0}, {3,0}, {3,1}, {3,2} }
R.queued['a>b'] = R.epoch
local adds, removes, live_scenes = {}, {}, {}
cm.get_local_faction_name = function() return 'viewer' end
cm.get_faction = function() return faction end
cm.get_camera_position = function() return 0, 0, 20 end
cm.log_to_dis = function(_, x, y) return x, y end
cm.get_region=function() return settled(1,2) end
cm.add_scripted_composite_scene_to_logical_position = function(_, id, kind, x,y,fx,fy,once,seen,unseen,viewer)
    assert(not once and not seen and not unseen and viewer == faction, 'fog/owner filter lost')
    adds[#adds+1] = { id=id, kind=kind, x=x, y=y }
    live_scenes[id]=true
    return true
end
cm.remove_scripted_composite_scene = function(_, id) removes[#removes+1] = id;live_scenes[id]=nil end
R.refresh()
local kinds = {}
for _, a in ipairs(adds) do kinds[#kinds+1] = a.x .. ',' .. a.y .. '=' .. a.kind end
table.sort(kinds)
-- every second hex; with no MCT the size is small (0) and the set the default (0), where the owner 'viewer'
-- hashes to colour 2; the bin is the display angle / 15 degrees, folded to 0-165
assert(table.concat(kinds, ' ') == '1,0=derpy_mr_route_dash_0_2_9_b0 1,2=derpy_mr_route_cargo_0 '
    .. '1,2=derpy_mr_route_dash_0_2_6 3,0=derpy_mr_route_dash_0_2_3_b4 3,2=derpy_mr_route_dash_0_2_6', table.concat(kinds, ' '))
R.refresh()
assert(#adds == 5 and #removes == 0, 'unchanged routes recreated scenes')
-- The MCT's line size and colour set pick the scenes: 'large' is size 2 and 'pale' set 2, so 'viewer' is 2 * 4 + 2.
DERPY_MR_FLOWS.mct = function(key) return ({ route_size = 'large', route_colours = 'pale' })[key] end
R.refresh()
kinds = {}
for _, p in pairs(R.scenes) do kinds[#kinds+1] = p.x .. ',' .. p.y .. '=' .. p.scene end
table.sort(kinds)
assert(table.concat(kinds, ' ') == '1,0=derpy_mr_route_dash_2_10_9_b0 1,2=derpy_mr_route_cargo_2 '
    .. '1,2=derpy_mr_route_dash_2_10_6 3,0=derpy_mr_route_dash_2_10_3_b4 3,2=derpy_mr_route_dash_2_10_6', table.concat(kinds, ' '))
assert(#removes == 5 and #adds == 10, 'a new line style left the old scenes up')
DERPY_MR_FLOWS.mct = function() return 'huge' end
local size, set = R.style()
assert(size == 0 and set == 0, 'a choice this build does not know draws as designed')
DERPY_MR_FLOWS.mct = nil
R.refresh()
assert(#removes == 10 and #adds == 15, 'no MCT: back to the default style')
-- Angles come from display positions, not logical ones: a stretched x axis turns the diagonal dashes.
cm.log_to_dis = function(_, x, y) return x * 2, y end
R.refresh()
assert(#removes == 12 and #adds == 17, 'a dash whose direction changed kept its old scene')
cm.log_to_dis = function(_, x, y) return x, y end
ships = {}
R.refresh()
assert(#removes == 17 and next(R.scenes) == nil, 'ended routes left scenes behind')

-- A new turn re-paths a shown route once, and the old line stays up until the new path lands.
local old = R.cache['a>b']
local function region(x, y) return { is_null_interface = function() return false end, owning_faction = function() return trader end,
    settlement = function() return { is_null_interface = function() return false end,
        logical_position_x = function() return x end, logical_position_y = function() return y end } end } end
cm.get_region = function(_, key) return key == 'a' and region(1, 2) or region(3, 2) end
cm.model = function() return { get_region_at_logical_position = function() return region(0, 0) end } end
core.trigger_event = function() end
assert(R.path('a', 'b') == old and #R.queue == 0, 'a path already worked out this turn was queued again')
R.epoch = R.epoch + 1
assert(R.path('a', 'b') == old and R.path('a', 'b') == old and #R.queue == 1, 'a new turn should queue one re-path and keep the old line')
R.pump()
assert(#R.queue == 0 and R.cache['a>b'] ~= old and R.cache['a>b'][1][1] == 1, 'the re-path did not replace the old line')
local function list(items)
    return { num_items=function() return #items end, item_at=function(_, i) return items[i+1] end }
end
local ally = { culture=function() return 'human' end, name=function() return 'ally' end, is_null_interface=function() return false end,
               is_dead=function() return false end, factions_trading_with=function() return false end }
faction.factions_met = function() return list({ally}) end
faction.get_foreign_visible_regions_for_player = function()
    return list({{name=function() return 'a' end},{name=function() return 'b' end}})
end
ships = { {f='ally',from='a',to='b',x=1,y=2}, {f='unknown',from='a',to='b',x=1,y=2} }
local links, cargo = R.links(faction)
assert(#links == 1 and #cargo == 1 and cargo[1].f == 'ally', 'unknown faction routes revealed')
ships[1].road = {{1,2}, {1,1}, {2,1}, {3,2}}
links = R.links(faction)
assert(links[1].path == ships[1].road, 'a shipment line must follow its saved journey')
local checked_mode
DERPY_MR_FLOWS.routes = function() return {{enabled=true, from='a', to='b'}} end
DERPY_MR_FLOWS.route_status = function(_, _, mode) checked_mode = mode; return true end
R.links(faction)
assert(checked_mode == 'show', 'map contract checks must use the multiplayer-safe UI mode')
DERPY_MR_FLOWS.routes = function() return {} end
ships={{f='viewer',from='a',to='b',stem='grain',road=ships[1].road},
       {f='viewer',from='b',to='a',stem='iron'},
       {f='viewer',from='a',to='b',stem='grain'}}
DERPY_MR_FLOWS.routes=function() return {{enabled=true,from='a',to='b',stem='coal'}} end
links,cargo=R.links(faction)
assert(#links==1 and #cargo==3,'shared endpoints must retain individual cargo markers')
assert(table.concat(links[1].goods[1],',')=='grain,coal' and table.concat(links[1].goods[2],',')=='iron',
       'shared routes must merge unique goods in their physical direction')
DERPY_MR_FLOWS.routes=function() return {} end
ships={{f='ally',from='a',to='b',x=1,y=2}}
faction.get_foreign_visible_regions_for_player = function() return empty end
links, cargo = R.links(faction)
assert(#links == 0 and #cargo == 0, 'hidden foreign endpoints revealed')

-- An agreement draws its line only while its trade runs, and along the trade's own road.
ships = {}
local road, verdict, modes = { {1,2}, {2,2}, {3,2} }, false, {}
faction.factions_trading_with = function() return list({ally}) end
ally.factions_trading_with = function() return list({faction}) end
DERPY_MR_FLOWS.capital = function(f) return { name = function() return f:name() .. '_home' end } end
DERPY_MR_FLOWS.reach = function(_, _, mode)
    modes[#modes + 1] = mode
    if mode == 'peek' and verdict == nil then return nil end
    return verdict, nil, verdict and road or nil
end
links = R.links(faction)
assert(#links == 0, 'a cut-off agreement drew a line')
verdict = true
cm.get_faction=function(_,key) return key=='ally' and ally or faction end
DERPY_MR_FLOWS.trade=function(f,preview)
    assert(preview,'route refresh committed a trade')
    return {[f==faction and 'ally' or 'viewer']={'grain','iron'}}
end
links = R.links(faction)
assert(#links == 1 and links[1].path == road, 'an open agreement should draw its own road')
DERPY_MR_FLOWS.stopped=function() return true end
assert(#R.links(faction)==0, 'all resources stopped must remove empty agreement roads')
ships={{f='viewer',from='a',to='b',stem='grain',x=1,y=2,road=road}}
assert(#R.links(faction)==1, 'resource switches must not recall travelling cargo')
DERPY_MR_FLOWS.mct=function(k) if k=='route_shipments' then return false end end
local hidden_links,hidden_cargo=R.links(faction)
assert(#hidden_links==0 and #hidden_cargo==0,'hidden shipments left their road or marker behind')
ships={}
DERPY_MR_FLOWS.stopped=function() return false end
DERPY_MR_FLOWS.mct=function(k) if k=='route_agreements' then return false end end
assert(#R.links(faction)==0,'agreement visibility switch was ignored')
DERPY_MR_FLOWS.mct=nil
adds = {}
R.refresh()
local at = {}
for _, a in ipairs(adds) do at[#at + 1] = a.x .. ',' .. a.y end
table.sort(at)
assert(table.concat(at, ' ') == '1,2 3,2', 'the trade road is the one drawn: ' .. table.concat(at, ' '))
-- unknown: the map peeks, works out one per refresh, and comes back for the rest
verdict, modes, R.budget, R.dirty = nil, {}, 1, false
links = R.links(faction)
assert(table.concat(modes, ',') == 'peek,show,peek' and R.dirty == true and R.budget == 0,
       'one new answer per refresh: ' .. table.concat(modes, ','))
local corner={{0,0},{1,0},{1,1}}
local x,y=R.sample(corner,2)
assert(x==0.875 and y==0.125,'rounded dash must sit on the quadratic cart curve')
assert(R.dash(corner,2,0,0)==R.dash({corner[3],corner[2],corner[1]},2,0,0),
       'reverse traffic must use the same physical rounded line')
assert(R.corner({{0,0},{4,0}},1)==nil,'never round a disconnected bridge span')
local node,next_node,angle=R.corner(corner,2)
assert(node==corner[2] and next_node==corner[3] and math.abs(angle-math.pi/2)<0.001,
       'cart turn must use the same incoming/outgoing edges as its dash')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
verdict = true
R.refresh()
assert(#R.traffic==2 and not R.traffic[1].reverse and R.traffic[2].reverse,
       'two-way trade must queue carts at both endpoints')
table.remove(R.traffic,2) -- Inspect one cart's icon handoff below; both lanes are checked separately.
adds = {}
R.animate()
assert(#adds==2 and adds[1].kind:match('^derpy_mr_route_cart_curve_') and adds[2].kind:match('^derpy_mr_icon_grain_'), 'cart and its resource icon must start together')
local first = adds[1]
local first_icon=adds[2].id
R.animate()
assert(#adds==2, 'a cart or its icon was respawned during its smooth segment')
for i=1,9 do R.animate() end
assert(#adds==4 and (adds[3].x~=first.x or adds[3].y~=first.y), 'cart did not advance to the next segment')
assert(adds[4].id~=first_icon and live_scenes[first_icon], 'retain the previous icon while its replacement starts rendering')
R.animate()
assert(not live_scenes[first_icon] and live_scenes[adds[4].id], 'retire the held icon after the replacement has a render update')
DERPY_MR_FLOWS.mct=function(k) if k=='route_icons' then return false end end
R.animate()
for id in pairs(live_scenes) do assert(not id:match('_icon_'),'hiding icons must remove both buffers immediately') end
DERPY_MR_FLOWS.mct=nil
for i=1,9 do R.animate() end
R.animate()
assert(adds[#adds].x==road[#road][1], 'cart teleported to its origin instead of turning at the destination')
local phase = R.traffic[1].distance
R.refresh()
assert(R.traffic[1].distance==phase, 'redrawing a road restarted its cart')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return true end} end} end
R.clear();R.refresh();adds={}
table.remove(R.traffic,2)
R.animate()
assert(#adds==2 and adds[1].kind:match('^derpy_mr_route_boat_curve_')
    and adds[2].kind:match('^derpy_mr_sea_icon_grain_'),'sea traffic needs a boat and a water-level resource icon')
local first_boat=adds[1].id
R.animate()
assert(#adds==2,'a boat or icon restarted during its curve')
cm.model = function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
R.traffic[1].age=0;R.traffic[1].distance=1;R.traffic[1].steps=1
R.animate()
assert(adds[3].kind:match('^derpy_mr_route_cart_curve_') and adds[4].kind:match('^derpy_mr_icon_grain_'),
       'traffic must switch back to land models and terrain-anchored icons at the coast')
cm.get_camera_position = function() return 10000,10000,20 end
R.refresh(); R.animate()
assert(next(R.cart_scenes)==nil and #R.traffic==0, 'offscreen carts were not culled')
local saved_links = R.links
R.links = function()
    local links = {}
    for i=1,R.CART_LIMIT+4 do links[i]={key='traffic'..i,owner='viewer',path=road} end
    return links,{}
end
cm.get_camera_position = function() return 0,0,20 end
R.refresh()
assert(#R.traffic==R.CART_LIMIT, 'dense networks exceeded the animated cart cap')
local decals = 0
for _ in pairs(R.scenes) do decals = decals + 1 end
assert(decals==2, 'twelve routes sharing one road must draw just one dotted line')
R.clear(); R.refresh()
cm.model=function() return {get_region_at_logical_position=function() return {is_null_interface=function() return false end} end} end
local departures,last_departure={},{}
for tick=1,250 do
    R.animate()
    local active=0
    for _,trip in ipairs(R.traffic) do
        if trip.active then
            active=active+1
            if trip.last_departure==R.traffic_clock then
                assert(R.traffic_clock-(last_departure[trip.key] or -60)>=60,'a short route departed again too soon')
                if not last_departure[trip.key] then departures[#departures+1]=trip.key end
                last_departure[trip.key]=R.traffic_clock
            end
        end
    end
    for i,a in ipairs(R.traffic) do for j=i+1,#R.traffic do
        local b=R.traffic[j]
        if a.active and b.active and a.reverse==b.reverse then
            assert(math.abs(a.distance-b.distance)>=R.GAP,'queued routes duplicated carts in one lane')
        end
    end end
end
assert(#departures>=4 and departures[1]=='traffic1' and departures[2]=='traffic2' and departures[3]=='traffic3',
       'shared-road departures must remain in order through arrival and return queues: '..table.concat(departures,','))
local highway={}
for y=0,199 do highway[#highway+1]={0,y} end
R.links=function() return {{key='two_way',from='a',owner='viewer',path=highway,goods={{'grain'},{'iron'}}}},{} end
R.clear();R.refresh()
assert(#R.traffic==2 and R.traffic[2].distance==199,'incoming traffic must start at the far endpoint')
for tick=1,70 do R.animate() end
assert(R.traffic[1].active and R.traffic[2].active,'separate lanes must permit simultaneous imports and exports')
assert(R.traffic[1].stem=='grain' and R.traffic[2].stem=='iron','directional carts must retain their own resources')
R.links=function()
    local links={}
    for k=1,10 do
        local p={}
        for y=0,9 do p[#p+1]={k*3,y} end
        links[k]={key='partner'..string.format('%02d',k),from='a',owner='viewer',path=p,goods={{'grain'},{'iron'}}}
    end
    return links,{}
end
R.clear();R.refresh()
assert(#R.traffic==R.CART_LIMIT,'ten two-way routes must fill the cart cap')
for k=1,10 do assert(R.traffic[k].key==string.format('partner%02d',k),'a route got its return cart before every route had one') end
for k=11,R.CART_LIMIT do assert(R.traffic[k].key:match(':return$'),'return carts must follow the first pass') end
R.animate()
for _,trip in ipairs(R.traffic) do assert(trip.active,'independent roads must depart without a global queue') end
-- Both land and sea traffic repeat within one turn; a one-way route never drives an empty leg.
for _,sea in ipairs({false,true}) do
    cm.model=function() return {get_region_at_logical_position=function() return {is_null_interface=function() return sea end} end} end
    R.links=function() return {{key='loop',from='a',owner='viewer',path=road,goods={{'grain'},{}}}},{} end
    R.clear();R.refresh()
    R.vehicles={supplier={land='land_chd',sea='sea_chd'}}
    local get_faction=cm.get_faction
    cm.get_faction=function(_,key)
        if key=='supplier' then return {is_null_interface=function() return false end,culture=function() return 'supplier' end} end
        return get_faction(cm,key)
    end
    R.traffic[1].factions={'supplier','buyer'}
    local departures=0
    for tick=1,260 do
        if tick%25==0 then R.refresh() end
        R.animate()
        local trip=R.traffic[1]
        if trip.last_departure==R.traffic_clock then
            departures=departures+1
            assert(not trip.reverse and trip.stem=='grain','a one-way route drove an empty leg')
            assert(trip.vehicle_faction=='supplier','a loop must keep its supplier vehicle')
        end
    end
    assert(departures>=4,'active trade must loop without a faction turn')
    -- An import-only route starts on its loaded leg, not by driving out empty first.
    R.links=function() return {{key='import',from='a',owner='viewer',path=road,goods={{},{'iron'}}}},{} end
    R.clear();R.refresh();R.animate()
    assert(R.traffic[1].active and R.traffic[1].reverse and R.traffic[1].stem=='iron','an import route left on its empty leg')
    cm.get_faction=get_faction;R.vehicles={}
end
R.links=function() return {{key='idle',from='a',owner='viewer',path=road,goods={{},{}}}},{} end
R.clear();R.refresh();R.animate()
assert(#R.traffic==0 and next(R.cart_scenes)==nil and next(R.icon_scenes)==nil,
    'zero-flow agreements must retain their road without advertising active traffic')
assert(next(R.scenes)~=nil,'idle agreement should retain its dotted road')
R.links = saved_links
R.clear()
assert(next(R.cart_scenes)==nil and #R.traffic==0, 'cleanup left animated traffic behind')
assert(next(R.icon_scenes)==nil,'cleanup left resource icons behind')
assert(next(live_scenes)==nil,'cleanup left an old icon buffer or scene in the engine')
print('terrain routes harness ok: routing, corridor merging, rounded geometry, ordered traffic, fog and cleanup')
