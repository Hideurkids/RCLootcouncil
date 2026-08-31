local lib, oldMinor = LibStub:NewLibrary("LibArmorToken-1.0", 1)
if not lib then return end

local items

-- API

function lib:ItemIsToken(itemid)
    if items[itemid] then
        return true
    end
end

do
    local t = {}
    local wipe = _G.wipe or (_G.table and _G.table.wipe) or function(tbl) for k in pairs(tbl) do tbl[k] = nil end return tbl end -- Lua 5.0: no Blizzard wipe() global
    function lib:IterateClassesForToken(itemid)
        if not items[itemid] then
            return ipairs({})
        end
        wipe(t)
        for cl in pairs(items[itemid]) do
            table.insert(t, cl)
        end
        return ipairs(t)
    end
end

function lib:IterateItemsForTokenAndClass(itemid, class)
    if not (items[itemid] and items[itemid][class]) then
        return ipairs({})
    end
    return ipairs(items[itemid][class])
end

function lib:FindTokenForItemByClass(itemid, class)
    for tokenid in pairs(items) do 
        if items[tokenid][class] then 
            for _, id in ipairs(items[tokenid][class]) do 
                if id == itemid then 
                    return tokenid 
                end
            end
        end
    end
    return nil
end
-- DATA
items = {} -- stripped: WotLK/Cata tier-token item IDs, no vanilla equivalent (see plan M8)
-- END DATA
