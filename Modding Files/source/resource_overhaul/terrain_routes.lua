-- Generated campaign grids precede this source. Rendering never changes stores or shipments.
DERPY_MR_TERRAIN_ROUTES = DERPY_MR_TERRAIN_ROUTES or {}
local R = DERPY_MR_TERRAIN_ROUTES
R.grids = DERPY_MR_ROUTE_GRIDS or {}
R.vehicles = DERPY_MR_VEHICLE_PROFILES or {}
R.vehicle_profiles = {}
R.cache, R.queue, R.scenes = {}, {}, {}
R.traffic, R.cart_scenes, R.icon_scenes, R.CART_LIMIT = {}, {}, {}, 16
R.alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
R.masks = {}
for i = 1, 64 do R.masks[string.byte(R.alphabet, i)] = i - 1 end
R.dirs = {
    { {0,1}, {1,0}, {1,-1}, {0,-1}, {-1,-1}, {-1,0} },
    { {0,1}, {1,1}, {1,0}, {0,-1}, {-1,0}, {-1,1} }
}
R.bits = { 1, 2, 4, 8, 16, 32 }

function R.index(g, x, y)
    if x >= 0 and y >= 0 and x < g.w and y < g.h then return y * g.w + x + 1 end
end

function R.point(g, id)
    return { (id - 1) % g.w, math.floor((id - 1) / g.w) }
end

function R.push(h, item)
    local i = #h + 1
    while i > 1 do
        local parent = math.floor(i / 2)
        if h[parent][1] <= item[1] then break end
        h[i], i = h[parent], parent
    end
    h[i] = item
end

function R.pop(h)
    local first, last = h[1], table.remove(h)
    if #h > 0 then
        local i = 1
        while i * 2 <= #h do
            local child = i * 2
            if child < #h and h[child + 1][1] < h[child][1] then child = child + 1 end
            if last[1] <= h[child][1] then break end
            h[i], i = h[child], child
        end
        h[i] = last
    end
    return first
end

-- Enemy or aggressive land costs R.AVOID per hex: a route detours round it where it can and still crosses
-- where it cannot (an island, a besieged pass). Aggressive is the diplomacy screen's "very unfriendly" or worse.
R.AVOID, R.AGGRESSIVE, R.epoch, R.queued, R.budget = 5, -70, 1, {}, 1

function R.hostile(owner, parties)
    for _, p in ipairs(parties) do
        if owner:name() == p:name() then return false end
    end
    if owner:is_rebel() then return true end
    for _, p in ipairs(parties) do
        if owner:at_war_with(p) or owner:diplomatic_attitude_towards(p:name()) <= R.AGGRESSIVE then return true end
    end
    return false
end

function R.start(g, a, b, avoid)
    if g.edge_data ~= g.data then g.edges, g.edge_data = {}, g.data end
    local first, target = R.index(g, a[1], a[2]), R.index(g, b[1], b[2])
    local j = { g = g, target = target, dest = b, open = {}, costs = {}, prev = {}, count = 0, avoid = avoid, seen = {} }
    if first and target then j.costs[first] = 0; R.push(j.open, {0, first, 0}) end
    return j
end

function R.advance(j, budget)
    local g = j.g
    for _ = 1, budget do
        if #j.open == 0 or j.count >= 200000 then return true end
        local node = R.pop(j.open)
        local id, cost = node[2], node[3]
        if id == j.target then
            local reverse, path = {}, {}
            while id do reverse[#reverse + 1] = R.point(g, id); id = j.prev[id] end
            for i = #reverse, 1, -1 do path[#path + 1] = reverse[i] end
            return true, path
        end
        if j.costs[id] == cost then
            j.count = j.count + 1
            local x, y = (id - 1) % g.w, math.floor((id - 1) / g.w)
            -- Native reciprocal edges are immutable; diplomacy and bridge checks remain live.
            local neighbours = g.edges[id]
            if not neighbours then
                neighbours = {}
                local mask = R.masks[string.byte(g.data, id)] or 0
                for d, delta in ipairs(R.dirs[x % 2 + 1]) do
                    local other = R.index(g, x + delta[1], y + delta[2])
                    local back = R.bits[(d + 2) % 6 + 1]
                    local m = other and R.masks[string.byte(g.data, other)] or 0
                    if other and math.floor(mask / R.bits[d]) % 2 == 1 and math.floor(m / back) % 2 == 1 then
                        neighbours[#neighbours + 1] = other
                    end
                end
                g.edges[id] = neighbours
            end
            local bridges = g.bridges[id]
            for n = 1, #neighbours + (bridges and #bridges or 0) do
                local other = n <= #neighbours and neighbours[n] or bridges[n - #neighbours]
                local qx, qy = (other - 1) % g.w, math.floor((other - 1) / g.w)
                local step, walled = math.max(1, math.abs(qx - x), math.abs(qy - y)), false
                if j.corridor and not j.corridor[other] then walled = true end
                if j.avoid then
                    if j.seen[other] == nil then j.seen[other] = j.avoid(qx, qy) end
                    if j.seen[other] then
                        if j.wall then walled = true else step = step * R.AVOID end
                    end
                end
                if j.shared and j.shared[other] then step = step * 0.25 end
                local next_cost = cost + step
                -- the estimate never overstates a hex distance, so a node past j.max cannot lead to a road within it
                local estimate = math.max(math.abs(qx - j.dest[1]), math.abs(qy - j.dest[2]))
                if j.shared then estimate = estimate * 0.25 end
                -- no math.huge here: it is not safe to assume in the game's Lua (2026-10-21 handoff)
                if not walled and (not j.max or next_cost + estimate <= j.max)
                    and (not j.costs[other] or next_cost < j.costs[other]) then
                    j.costs[other], j.prev[other] = next_cost, id
                    R.push(j.open, { next_cost + estimate, other, next_cost })
                end
            end
        end
    end
    return false
end

-- Paths are worked out again once per turn (R.epoch), since wars and attitudes move; the old line stays up
-- until the new one is ready. ponytail: re-paths every shown route each turn; skip unchanged hostility if it shows.
function R.path(from, to)
    local key = from .. '>' .. to
    if R.queued[key] == R.epoch or not R.grid then return R.cache[key] or nil end
    R.queued[key] = R.epoch
    local a, b = cm:get_region(from), cm:get_region(to)
    if not a or not b or a:is_null_interface() or b:is_null_interface() then return R.cache[key] or nil end
    local avoid = R.avoider(a, b)
    a, b = a:settlement(), b:settlement()
    if a:is_null_interface() or b:is_null_interface() then return R.cache[key] or nil end
    local j = R.start(R.grid, {a:logical_position_x(), a:logical_position_y()},
                               {b:logical_position_x(), b:logical_position_y()}, avoid)
    j.key = key
    R.queue[#R.queue + 1] = j
    return R.cache[key] or nil
end

-- (x, y) -> is that hex enemy or aggressive land to the owners of regions a and b; one verdict per owner.
function R.avoider(a, b)
    local parties = {}
    for _, region in ipairs({a, b}) do
        local owner = region:owning_faction()
        if not owner:is_null_interface() then parties[#parties + 1] = owner end
    end
    local model, verdicts = cm:model(), {}
    return function(x, y)
        local region = model:get_region_at_logical_position(x, y)
        if region:is_null_interface() then return false end
        local owner = region:owning_faction()
        if owner:is_null_interface() then return false end
        local name = owner:name()
        if verdicts[name] == nil then verdicts[name] = R.hostile(owner, parties) end
        return verdicts[name]
    end
end

-- TRADE REACH: is there a road between two settlements that stays off land hostile to either owner and is
-- no longer than max hexes (nil: any length)? Returns ok, why ('far' or 'enemy') and the road. Synchronous,
-- for the economy at a turn start; enemy land is a wall here, where R.path only charges for it.
function R.reach(from, to, max)
    local g = R.grids[cm:model():campaign_name_key()]
    if not g then return true end   -- a map with no grid has nothing to judge by, so trade is never stopped
    local a, b = from:settlement(), to:settlement()
    local first, last = {a:logical_position_x(), a:logical_position_y()}, {b:logical_position_x(), b:logical_position_y()}
    if max and math.max(math.abs(first[1] - last[1]), math.abs(first[2] - last[2])) > max then return false, 'far' end
    local function run(avoid)
        local j = R.start(g, first, last, avoid)
        j.wall, j.max = true, max
        local done, path
        repeat done, path = R.advance(j, 100000) until done
        return path
    end
    local path = run(R.avoider(from, to))
    if path then return true, nil, path end
    -- no safe road: the enemy is to blame when a road through their land would have been short enough
    return false, run(nil) and 'enemy' or 'far'
end

-- Computed by the synchronized dispatch, then saved on the cargo; never use the UI's path cache here.
function R.journey(from, to)
    local g = R.grids[cm:model():campaign_name_key()]
    if not g then return nil end
    local a, b = from:settlement(), to:settlement()
    local j = R.start(g, {a:logical_position_x(), a:logical_position_y()},
        {b:logical_position_x(), b:logical_position_y()}, R.avoider(from, to))
    local done, path
    repeat done, path = R.advance(j, 100000) until done
    return path
end

function R.pump()
    local j = R.queue[1]
    if not j then return end
    local done, path = R.advance(j, 1000)
    if done then
        R.cache[j.key] = path or false
        table.remove(R.queue, 1)
        R.dirty = true
        core:trigger_event('DerpyMRTerrainRoutesUpdated')
    end
end

function R.colour(key)
    local n = 0
    for i = 1, string.len(key) do n = (n + string.byte(key, i)) % 4 end
    return n
end

-- THE PLAYER'S CHOICE (MCT, 2026-10-22): line size and colour set, in build_mr_terrain_routes.SIZES and
-- COLOUR_SETS order (its selftest compares them). A scene exists for every size, colour and direction. Not
-- frozen into the save: it moves no trade, so a new choice shows at the next redraw.
R.SIZES = { 'small', 'normal', 'large' }
R.SETS = { 'default', 'bright', 'pale', 'colourblind' }
function R.style()
    local F = DERPY_MR_FLOWS
    local function pick(list, key, fallback)
        for i, k in ipairs(list) do if k == key then return i - 1 end end
        return fallback
    end
    local mct = F and F.mct or function(_) return nil end
    return pick(R.SIZES, mct('route_size'), 0), pick(R.SETS, mct('route_colours'), 0)
end

-- An owner's colour in the chosen set, as an index into the palette (the Vault Map's templates share it).
function R.ink(key, set)
    if not set then set = select(2, R.style()) end
    return set * 4 + R.colour(key)
end

function R.shown(kind)
    local F=DERPY_MR_FLOWS
    return not F or not F.mct or F.mct('route_'..kind)~=false
end

-- Decorative traffic advertises permitted goods; it does not dispatch or debit stock.
function R.goods(seller,buyer)
    local F,goods=DERPY_MR_FLOWS,{}
    for _,g in ipairs(DERPY_MR_FLOWS_GOODS or {}) do
        if not F.stopped(seller,'export',g.stem) and not F.stopped(buyer,'import',g.stem) then
            goods[#goods+1]=g.stem
        end
    end
    return goods
end

function R.vehicle(fkey,sea)
    if not fkey then return nil end
    local profile=R.vehicle_profiles[fkey]
    if not profile then
        local faction=cm:get_faction(fkey)
        if not faction or faction:is_null_interface() then return nil end
        profile=R.vehicles[faction:culture()] or R.vehicles['*']
        R.vehicle_profiles[fkey]=profile
    end
    return profile and profile[sea and 'sea' or 'land']
end

function R.carried(goods,seller,buyer,plans)
    local F,stocked=DERPY_MR_FLOWS,{}
    if not plans[seller] then plans[seller]=F.trade(cm:get_faction(seller),true) end
    local allowed={}
    for _,stem in ipairs(plans[seller][buyer] or {}) do allowed[stem]=true end
    for _,stem in ipairs(goods) do
        if allowed[stem] then stocked[#stocked+1]=stem end
    end
    return stocked
end

-- Rounded corners run from the incoming edge midpoint through this tile to the outgoing midpoint.
function R.corner(path,i,reverse)
    local p=path[i]
    local a=path[i+(reverse and 1 or -1)] or path[i+(reverse and -1 or 1)]
    local b=path[i+(reverse and -1 or 1)] or a
    if not a or not b then return nil end
    for _,q in ipairs({a,b}) do
        if math.max(math.abs(q[1]-p[1]),math.abs(q[2]-p[2]))>1 then return nil end
    end
    local ax,ay=cm:log_to_dis(a[1],a[2])
    local px,py=cm:log_to_dis(p[1],p[2])
    local bx,by=cm:log_to_dis(b[1],b[2])
    local angle=math.atan2((px-ax)*(by-py)-(py-ay)*(bx-px),(px-ax)*(bx-px)+(py-ay)*(by-py))
    return p,b,angle,ax,ay,px,py,bx,by
end

function R.sample(path,i)
    local p,b,angle,ax,ay,px,py,bx,by=R.corner(path,i)
    if p and i>1 and i<#path then return (ax+px*6+bx)/8,(ay+py*6+by)/8 end
    return cm:log_to_dis(path[i][1],path[i][2])
end

-- Native decals ignore facing: each tangent and signed corner offset has a baked scene.
R.ANGLES = 12
function R.turn(angle)
    return math.floor(math.abs(angle)/math.pi*3+0.5)*(angle<0 and -1 or 1)
end
function R.dash(path, i, ink, size)
    local a, b = path[math.max(1, i - 1)], path[math.min(#path, i + 1)]
    local ax, ay = cm:log_to_dis(a[1], a[2])
    local bx, by = cm:log_to_dis(b[1], b[2])
    local full = math.floor(math.atan2(by - ay, bx - ax) / math.pi * R.ANGLES + 0.5) % (R.ANGLES*2)
    local bend=0
    if i>1 and i<#path then
        local p,q,angle=R.corner(path,i)
        if p then bend=R.turn(angle); if full>=R.ANGLES then bend=-bend end end
    end
    local key='derpy_mr_route_dash_' .. size .. '_' .. ink .. '_' .. (full%R.ANGLES)
    if bend~=0 and math.abs(bend)<3 then key=key..'_b'..(bend+2) end
    return key
end

function R.hide_icon(id)
    cm:remove_scripted_composite_scene(id..'_a')
    cm:remove_scripted_composite_scene(id..'_b')
end

function R.clear()
    for id in pairs(R.scenes) do cm:remove_scripted_composite_scene(id) end
    for id in pairs(R.cart_scenes) do cm:remove_scripted_composite_scene(id) end
    for id in pairs(R.icon_scenes) do R.hide_icon(id) end
    R.scenes = {}
    R.traffic, R.cart_scenes, R.icon_scenes = {}, {}, {}
    R.traffic_clock = 0
end

-- Every cart moves one hex a second, so a waiting cart leaves only if it would pass each hex it shares with a
-- moving cart at least R.GAP seconds apart; an exactly opposing corridor has its own lane. Reserving the whole
-- remaining road let one cart at a time through a hub every route shares (author, 2026-10-23).
R.GAP = 4
function R.can_depart(trip,traffic)
    if not trip.cells then
        trip.cells={}
        for i,p in ipairs(trip.path) do trip.cells[p[1]..':'..p[2]]=i end
    end
    local function same(a,b) return a==b or (a and b and a[1]==b[1] and a[2]==b[2]) end
    for _,other in ipairs(traffic) do
        if other~=trip and other.active then
            local direction=other.reverse and -1 or 1
            local now=other.distance+1
            local first=math.max(1,math.min(#other.path,now-direction*3))
            local last=other.reverse and 1 or #other.path
            for i=first,last,direction do
                local p=other.path[i]
                local j=trip.cells[p[1]..':'..p[2]]
                if j then
                    local mine=trip.reverse and -1 or 1
                    local bend
                    if j>1 and j<#trip.path then local _,_,angle=R.corner(trip.path,j,trip.reverse);bend=angle end
                    local opposing=same(trip.path[j-mine],other.path[i+direction])
                        and same(trip.path[j+mine],other.path[i-direction])
                        and not (bend and math.abs(bend)>math.pi/2)
                    local ours=trip.reverse and #trip.path-j or j-1
                    if not opposing and math.abs(ours-(i-now)*direction)<R.GAP then return false end
                end
            end
        end
    end
    return true
end

function R.animate()
    local camera = R.camera
    if not camera then return end
    R.traffic_clock=(R.traffic_clock or 0)+1
    while true do
        local next_trip
        for _,trip in ipairs(R.traffic) do
            local g=trip.goods
            -- A one-way route starts its next load from the source instead of driving home empty.
            if not trip.active and g and #g[trip.reverse and 2 or 1]==0 and #g[trip.reverse and 1 or 2]>0 then
                trip.reverse=not trip.reverse
                trip.distance=trip.reverse and #trip.path-1 or 0
            end
            if not trip.active and R.traffic_clock-(trip.last_departure or -60)>=60 and R.can_depart(trip,R.traffic)
                and (not next_trip or (trip.last_departure or 0)<(next_trip.last_departure or 0)) then next_trip=trip end
        end
        if next_trip then
            next_trip.active,next_trip.age,next_trip.steps=true,0,0
            next_trip.last_departure=R.traffic_clock
            local goods=next_trip.goods and next_trip.goods[next_trip.reverse and 2 or 1]
            next_trip.departures=(next_trip.departures or 0)+1
            next_trip.stem=goods and goods[(next_trip.departures-1)%math.max(1,#goods)+1]
            if next_trip.factions and (next_trip.stem or not next_trip.vehicle_faction) then
                next_trip.vehicle_faction=next_trip.factions[next_trip.reverse and 2 or 1]
            end
        else break end
    end
    local faction = cm:get_faction(cm:get_local_faction_name(true))
    local radius = math.max(35, camera[3]*4)
    local model = cm:model()
    for slot = 1, R.CART_LIMIT do
        local id, trip = 'derpy_mr_traffic_'..slot, R.traffic[slot]
        local wanted, x,y,fx,fy,scene,curve,sea
        if trip and trip.active then
            local i
            i=trip.distance+1
            local p,b,angle=R.corner(trip.path,i,trip.reverse)
            if p then
                x,y,fx,fy=p[1],p[2],b[1],b[2]
                curve=R.turn(angle)%6
                if trip.steps==0 then curve=7
                elseif i==1 or i==#trip.path then curve=6 end
                scene='derpy_mr_route_cart_curve_'..curve
            end
            if x then
                local p = trip.path[i]
                local region = model:get_region_at_logical_position(p[1],p[2])
                sea=region:is_null_interface()
                if sea then scene='derpy_mr_route_boat_curve_'..curve end
                local vehicle=R.vehicle(trip.vehicle_faction,sea)
                if vehicle then scene='derpy_mr_route_vehicle_'..vehicle..'_'..curve end
                local dx,dy = cm:log_to_dis(x,y)
                if (dx-camera[1])*(dx-camera[1])+(dy-camera[2])*(dy-camera[2]) <= radius*radius then
                    wanted = trip.key .. ':' .. tostring(trip.path) .. ':' .. i .. ':' .. tostring(trip.reverse == true)..':'..tostring(sea)..':'..scene
                end
            end
        end
        if R.cart_scenes[id] ~= wanted then
            if R.cart_scenes[id] then cm:remove_scripted_composite_scene(id); R.cart_scenes[id] = nil end
            if wanted and cm:add_scripted_composite_scene_to_logical_position(id,scene,
                x,y,fx,fy,false,false,false,faction) then R.cart_scenes[id] = wanted end
        end
        local icon_id=id..'_icon'
        local icon=wanted and trip.stem and R.shown('icons') and wanted..':'..trip.stem or nil
        local current=R.icon_scenes[icon_id]
        if current and current.old and R.traffic_clock>=current.retire then
            cm:remove_scripted_composite_scene(icon_id..'_'..current.old)
            current.old=nil
        end
        if not icon or (current and current.key~=icon and trip.age~=0) then
            if current then R.hide_icon(icon_id);R.icon_scenes[icon_id]=nil end
        elseif not current or current.key~=icon then
            if trip.age==0 then
                local bank=current and current.bank=='a' and 'b' or 'a'
                -- Keep the previous sprite at the join for 100 ms while the new emitter acquires its first frame.
                if cm:add_scripted_composite_scene_to_logical_position(icon_id..'_'..bank,
                    (sea and 'derpy_mr_sea_icon_' or 'derpy_mr_icon_')..trip.stem..'_'..curve,x,y,fx,fy,false,false,false,faction) then
                    R.icon_scenes[icon_id]={key=icon,bank=bank,old=current and current.bank,retire=R.traffic_clock+1}
                else
                    R.hide_icon(icon_id);R.icon_scenes[icon_id]=nil
                end
            end
        end
        if trip and trip.active then
            -- The scene rounds this corner for one second; keep it alive for the whole curve.
            trip.age = (trip.age or 0) + 1
            if trip.age == 10 then
                trip.age = 0
                if trip.steps>0 and (trip.distance==0 or trip.distance==#trip.path-1) then
                    trip.active,trip.reverse=false,not trip.reverse
                else
                    trip.distance=trip.distance+(trip.reverse and -1 or 1)
                    trip.steps=trip.steps+1
                end
            end
        end
    end
end

function R.links(faction)
    local links, cargo, seen, owned, plans = {}, {}, {}, {}, {}
    local regions = faction:region_list()
    for i = 0, regions:num_items() - 1 do owned[regions:item_at(i):name()] = true end
    local function add(owner, from, to, road, goods)
        local key = from < to and (from .. '>' .. to) or (to .. '>' .. from)
        if from == to then return end
        local link=seen[key]
        if not link then
            link={owner=owner,from=from,to=to,key=key,path=road,
                  own=owned[from]==true or owned[to]==true,goods={{},{}}}
            seen[key]=link
            links[#links+1]=link
        end
        for direction,stems in ipairs(goods or {}) do
            local target=link.goods[from==link.from and direction or 3-direction]
            for _,stem in ipairs(stems) do
                local found=false
                for _,existing in ipairs(target) do if existing==stem then found=true;break end end
                if not found then target[#target+1]=stem end
            end
        end
    end
    local F = DERPY_MR_FLOWS
    if not F then return links, cargo end
    local known, visible = { [faction:name()] = faction }, {}
    local met = faction:factions_met()
    for i = 0, met:num_items() - 1 do
        local f = met:item_at(i)
        if not f:is_null_interface() and not f:is_dead() then known[f:name()] = f end
    end
    for _, regions in ipairs({faction:region_list(), faction:get_foreign_visible_regions_for_player()}) do
        for i = 0, regions:num_items() - 1 do visible[regions:item_at(i):name()] = true end
    end
    for _, s in ipairs(R.shown('shipments') and F.ships() or {}) do
        if s.f == faction:name() or s.sender == faction:name() or s.recipient == faction:name()
            or (known[s.f] and visible[s.from] and visible[s.to]) then
            add(s.f, s.from, s.to, s.road, {{s.stem},{}})
            cargo[#cargo + 1] = s
        end
    end
    for _, o in ipairs(R.shown('contracts') and F.routes(faction) or {}) do
        if o.enabled and F.route_status(faction, o, 'show') then add(faction:name(), o.from, o.to,nil,{{o.stem},{}}) end
    end
    local ordered = {}
    for key in pairs(known) do ordered[#ordered + 1] = key end
    table.sort(ordered)
    for _, key in ipairs(R.shown('agreements') and ordered or {}) do
        local owner = known[key]
        local home, partners = F.capital(owner), owner:factions_trading_with()
        if home and type(partners) ~= 'boolean' then
            for i = 0, partners:num_items() - 1 do
                local partner = partners:item_at(i)
                if known[partner:name()] then
                    local dest = F.capital(partner)
                    if dest and (key == faction:name() or partner:name() == faction:name()
                        or (visible[home:name()] and visible[dest:name()])) then
                        local colour_owner = key == faction:name() and partner:name() or key
                        -- An agreement whose trade is cut off draws no line; one that runs draws its own road.
                        -- One new reach per refresh, so a fresh turn or a load never stalls a frame for long.
                        local open, _, road = true, nil, nil
                        if F.reach then
                            open, _, road = F.reach(home, dest, 'peek')
                            if open == nil and R.budget > 0 then
                                R.budget = R.budget - 1
                                open, _, road = F.reach(home, dest, 'show')
                            elseif open == nil then
                                R.dirty = true
                            end
                        end
                        if open then
                            local goods={R.goods(key,partner:name()),R.goods(partner:name(),key)}
                            if #goods[1]>0 or #goods[2]>0 then
                                add(colour_owner, home:name(), dest:name(), road,
                                    {R.carried(goods[1],key,partner:name(),plans),R.carried(goods[2],partner:name(),key,plans)})
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(links, function(a,b)
        if a.own ~= b.own then return a.own end
        return a.key < b.key
    end)
    return R.network(links), cargo
end

-- A display-only search within six tiles of the real road prefers the existing network.
-- Native grid edges and hostile-land walls still apply; saved cargo journeys never change.
-- Keep the corridor connected: isolated rings round nearby trunks left shallow forks running beside them.
function R.bundle(path, shared, g, avoid)
    if #path < 2 or not next(shared) then return path end
    local j = R.start(g,path[1],path[#path],avoid)
    j.corridor, j.shared, j.wall = {}, shared, true
    for _,p in ipairs(path) do
        for dx=-6,6 do for dy=-6,6 do
            local id=R.index(g,p[1]+dx,p[2]+dy)
            if id then j.corridor[id]=true end
        end end
    end
    -- ponytail: bounded synchronous display search; queue it if crowded networks stall a refresh.
    local done, bundled=R.advance(j,12000)
    if done and bundled and #bundled <= #path+6 then return bundled end
    return path
end

function R.network(links)
    if not R.grid then return links end
    local cached, same = R.network_cache, true
    if not cached or cached.epoch~=R.epoch or #cached.raw~=#links then same=false end
    for i,link in ipairs(links) do
        link.path=link.path or R.path(link.from,link.to)
        local old=cached and cached.raw[i]
        if not old or old.path~=link.path or old.key~=link.key or old.owner~=link.owner or old.own~=link.own then same=false end
    end
    if same then
        for i,link in ipairs(links) do cached.links[i].goods=link.goods end
        return cached.links
    end
    local shared, roads = {}, {}
    for _,link in ipairs(links) do
        local road={}
        for k,v in pairs(link) do road[k]=v end
        if link.path then
            local avoid
            if next(shared) then avoid=R.avoider(cm:get_region(link.from),cm:get_region(link.to)) end
            road.path=R.bundle(link.path,shared,R.grid,avoid)
            for _,p in ipairs(road.path) do shared[R.index(R.grid,p[1],p[2])]=true end
        end
        roads[#roads+1]=road
    end
    R.network_cache={epoch=R.epoch,raw=links,links=roads}
    return roads
end

-- Merge shared edges, not crossings. Earlier links (owned first, then key) supply the trunk colour.
function R.unshared(path, seen)
    local visible = {}
    if #path == 1 then visible[1] = true end
    for i = 1, #path - 1 do
        local a = path[i][1] .. ':' .. path[i][2]
        local b = path[i+1][1] .. ':' .. path[i+1][2]
        local key = a < b and (a .. '>' .. b) or (b .. '>' .. a)
        if not seen[key] then visible[i], visible[i+1] = true, true end
        seen[key] = true
    end
    return visible
end

function R.refresh()
    if not R.grid then return end
    local faction = cm:get_faction(cm:get_local_faction_name(true))
    if not faction or faction:is_null_interface() then return end
    local wanted, count = {}, 0
    local cx, cy, zoom = cm:get_camera_position()
    R.camera = {cx, cy, zoom}
    local radius = math.max(35, zoom * 4)
    R.budget = 1
    local size, set = R.style()
    local links, cargo = R.links(faction)
    local old_traffic, traffic, shared, routes = {}, {}, {}, {}
    for _, t in ipairs(R.traffic) do old_traffic[t.key] = t end
    for _, s in ipairs(cargo) do
        if count < 512 then
            count = count + 1
            wanted['derpy_mr_road_' .. count] = { x = s.x, y = s.y, scene = 'derpy_mr_route_cargo_' .. size }
        end
    end
    for _, link in ipairs(links) do
        local path = link.path or R.path(link.from, link.to)
        if path then
            local visible = R.unshared(path, shared)
            local closest, best
            if R.shown('carts') and #path > 1
                and (not link.goods or #link.goods[1]>0 or #link.goods[2]>0) then
                for i,p in ipairs(path) do
                    local dx,dy = cm:log_to_dis(p[1],p[2])
                    local d = (dx-cx)*(dx-cx)+(dy-cy)*(dy-cy)
                    if d <= radius*radius and (not best or d < best) then closest,best = i,d end
                end
                if closest then
                    local goods=link.goods
                    local origins
                    if link.from and link.to then
                        origins={cm:get_region(link.from):owning_faction():name(),cm:get_region(link.to):owning_faction():name()}
                    end
                    if goods then
                        local st=cm:get_region(link.from):settlement()
                        local first,last=path[1],path[#path]
                        local x,y=st:logical_position_x(),st:logical_position_y()
                        if (first[1]-x)^2+(first[2]-y)^2>(last[1]-x)^2+(last[2]-y)^2 then
                            goods={goods[2],goods[1]}
                            if origins then origins={origins[2],origins[1]} end
                        end
                    end
                    routes[#routes+1]={key=link.key,path=path,goods=goods,origins=origins,
                        directions=goods and #goods[1]>0 and #goods[2]>0 and 2 or 1}
                end
            end
            -- ponytail: render at most 512 nearby decals; prioritise selected routes if crowded maps reach the cap.
            for i = 1, #path, 2 do
                if count >= 512 then break end
                local p = path[i]
                local dx, dy = cm:log_to_dis(p[1], p[2])
                if visible[i] and (dx-cx)*(dx-cx) + (dy-cy)*(dy-cy) <= radius * radius then
                    local id = 'derpy_mr_road_' .. (count + 1)
                    wanted[id] = { x = p[1], y = p[2], scene = R.dash(path, i, R.ink(link.owner, set), size) }
                    count = count + 1
                end
            end
        end
    end
    -- Every route in view gets its cart before any route gets a second (author, 2026-10-23: many partners
    -- showed four two-way roads and nothing on the rest).
    for direction=1,2 do
        for _,route in ipairs(routes) do
            if #traffic>=R.CART_LIMIT then break end
            if direction<=route.directions then
                local path,goods=route.path,route.goods
                local key=route.key..(direction==2 and ':return' or '')
                local prior=old_traffic[key]
                local trip=prior and prior.path==path and prior or {key=key,path=path,
                    distance=direction==2 and #path-1 or 0,reverse=direction==2}
                trip.goods=goods
                trip.factions=route.origins or trip.factions
                if trip.stem and goods then
                    local allowed=false
                    for _,stem in ipairs(goods[trip.reverse and 2 or 1]) do if stem==trip.stem then allowed=true end end
                    if not allowed then trip.stem=nil end
                end
                traffic[#traffic+1]=trip
            end
        end
    end
    R.traffic = traffic
    -- Keep a scene's identity while panning so unchanged dashes do not restart their emitters.
    local by_point, aligned, used, pending = {}, {}, {}, {}
    local function point_key(p) return p.x .. ':' .. p.y .. ':' .. p.scene end
    for id, p in pairs(R.scenes) do by_point[point_key(p)] = id end
    for _, p in pairs(wanted) do
        local id = by_point[point_key(p)]
        if id and not used[id] then aligned[id], used[id] = p, true
        else pending[#pending + 1] = p end
    end
    local slot = 1
    for _, p in ipairs(pending) do
        while used['derpy_mr_road_' .. slot] do slot = slot + 1 end
        local id = 'derpy_mr_road_' .. slot
        aligned[id], used[id] = p, true
    end
    wanted = aligned
    for id, old in pairs(R.scenes) do
        local new = wanted[id]
        if not new or new.x ~= old.x or new.y ~= old.y or new.scene ~= old.scene then
            cm:remove_scripted_composite_scene(id)
            R.scenes[id] = nil
        end
    end
    for id, p in pairs(wanted) do
        if not R.scenes[id] then
            local ok = cm:add_scripted_composite_scene_to_logical_position(id, p.scene,
                p.x, p.y, p.x, p.y + 1, false, false, false, faction)
            if ok then R.scenes[id] = p end
        end
    end
end

function R.tick()
    local ok, err = pcall(function()
        R.pump()
        R.ticks = (R.ticks or 0) + 1
        local x, y, zoom = cm:get_camera_position()
        local camera = R.camera
        local moved = camera and ((x-camera[1])*(x-camera[1]) + (y-camera[2])*(y-camera[2]) > 16
                                or math.abs(zoom-camera[3]) > 2)
        if R.dirty or moved or R.ticks % 25 == 1 then R.dirty = false; R.refresh() end
        R.animate()
    end)
    if not ok and not R.failed then R.failed = true; pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end
end

function R.init()
    if R.started then return end
    R.started = true
    -- Scenes survive saves; a fixed namespace removes old links before rebuilding current ones.
    for i = 1, 512 do cm:remove_scripted_composite_scene('derpy_mr_road_' .. i) end
    for i = 1, R.CART_LIMIT do
        cm:remove_scripted_composite_scene('derpy_mr_traffic_' .. i)
        cm:remove_scripted_composite_scene('derpy_mr_traffic_' .. i..'_icon')
        R.hide_icon('derpy_mr_traffic_'..i..'_icon')
    end
    if cm:is_multiplayer() then return end
    R.grid = R.grids[cm:model():campaign_name_key()]
    if not R.grid then return end
    R.refresh()
    cm:repeat_real_callback(R.tick, 100, 'derpy_mr_terrain_routes')
    core:add_listener('derpy_mr_terrain_routes_turn', 'FactionTurnStart',
        function(context) return context:faction():name() == cm:get_local_faction_name(true) end,
        function() R.epoch = R.epoch + 1; R.dirty = true end, true)
end

core:add_listener('derpy_mr_terrain_routes_init', 'ScriptEventFirstTickAfterWorldCreated', true,
    function() local ok, err = pcall(R.init); if not ok then pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end end, true)
cm:add_first_tick_callback(function() local ok, err = pcall(R.init); if not ok then pcall(out, '[derpy_mr_routes] ' .. tostring(err)) end end)
