local addonName, ns = ...

local floor, abs, max, min = math.floor, math.abs, math.max, math.min

function ns.Print(msg)
	local text = "|cff33ff99OpenMargin|r: " .. tostring(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage(text)
	else
		print(text)
	end
end

function ns.Trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function ns.Normalize(text)
	text = tostring(text or ""):lower()
	text = text:gsub("%s+", " ")
	return ns.Trim(text)
end

function ns.Clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

-- Compact money for recipe tags and the breakdown panel.
-- signed adds a leading + for positive values.
function ns.FormatMoney(copper, signed)
	copper = tonumber(copper)
	if not copper then return "?" end

	local negative = copper < 0
	local value = abs(copper)
	local text

	if value >= 10000 then
		local gold = value / 10000
		if gold >= 100 then
			text = string.format("%dgold", floor(gold + 0.5))
		elseif gold >= 10 then
			text = string.format("%.1fgold", gold)
		else
			text = string.format("%.2fgold", gold)
		end
	elseif value >= 100 then
		text = string.format("%dsilver", floor(value / 100 + 0.5))
	else
		text = string.format("%dcopper", floor(value + 0.5))
	end

	text = text:gsub("gold", "g"):gsub("silver", "s"):gsub("copper", "c")

	if negative then
		return "-" .. text
	elseif signed and value > 0 then
		return "+" .. text
	end
	return text
end

-- Longer money for tooltips.
function ns.FormatMoneyFull(copper)
	copper = tonumber(copper)
	if not copper then return "?" end

	local negative = copper < 0
	local value = abs(floor(copper + 0.5))
	if _G.GetMoneyString then
		-- GetMoneyString mishandles negative values on some clients, so format
		-- the absolute amount and add the sign ourselves.
		local ok, text = pcall(_G.GetMoneyString, value)
		if ok and text then return (negative and "-" or "") .. text end
	end

	local gold = floor(value / 10000)
	local silver = floor((value % 10000) / 100)
	local copperPart = value % 100
	local parts = {}
	if gold > 0 then parts[#parts + 1] = gold .. "g" end
	if silver > 0 or (gold > 0 and copperPart > 0) then parts[#parts + 1] = silver .. "s" end
	if copperPart > 0 or #parts == 0 then parts[#parts + 1] = copperPart .. "c" end
	return (negative and "-" or "") .. table.concat(parts, " ")
end

-- value is a fraction: 0.27 -> +27%
function ns.FormatPercent(value, signed)
	value = tonumber(value)
	if not value then return "?" end
	local rounded = floor(abs(value) * 100 + 0.5)
	if value < 0 then
		return "-" .. rounded .. "%"
	elseif signed and rounded > 0 then
		return "+" .. rounded .. "%"
	end
	return rounded .. "%"
end

function ns.FormatAge(seconds)
	seconds = tonumber(seconds)
	if not seconds or seconds < 0 then return nil end
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return floor(seconds / 60) .. "m ago" end
	if seconds < 86400 then return floor(seconds / 3600) .. "h ago" end
	return floor(seconds / 86400) .. "d ago"
end

function ns.GetAuctionatorAPI()
	local auctionator = _G.Auctionator
	local api = auctionator and auctionator.API and auctionator.API.v1
	if api and type(api.GetAuctionPriceByItemID) == "function" then
		return api
	end
	return nil
end

function ns.IsAddonLoaded(name)
	if _G.C_AddOns and type(_G.C_AddOns.IsAddOnLoaded) == "function" then
		local ok, _, loaded = pcall(_G.C_AddOns.IsAddOnLoaded, name)
		if ok then return loaded == true end
	end
	if type(_G.IsAddOnLoaded) == "function" then
		local ok, loaded = pcall(_G.IsAddOnLoaded, name)
		return ok and loaded == true
	end
	return false
end

function ns.GetItemInfo(itemID)
	if not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) or itemID <= 0 then return nil end
	local info = {}
	if _G.C_Item and type(_G.C_Item.GetItemInfo) == "function" then
		local ok, name, link, quality, itemLevel, minLevel, itemType, itemSubType, stackCount, equipLoc, texture, sellPrice, classID, subclassID = pcall(_G.C_Item.GetItemInfo, itemID)
		if ok then
			info.name = name
			info.link = link
			info.quality = quality
			info.itemLevel = itemLevel
			info.itemType = itemType
			info.itemSubType = itemSubType
			info.texture = texture
			info.sellPrice = sellPrice
			info.classID = classID
			info.subclassID = subclassID
		end
	end
	if not info.name and type(_G.GetItemInfo) == "function" then
		local ok, name, link, quality, itemLevel, minLevel, itemType, itemSubType, stackCount, equipLoc, texture, sellPrice, classID, subclassID = pcall(_G.GetItemInfo, itemID)
		if ok then
			info.name = name
			info.link = link
			info.quality = quality
			info.itemLevel = itemLevel
			info.itemType = itemType
			info.itemSubType = itemSubType
			info.texture = texture
			info.sellPrice = sellPrice
			info.classID = classID
			info.subclassID = subclassID
		end
	end
	if not info.name and _G.C_Item and type(_G.C_Item.RequestLoadItemDataByID) == "function" then
		pcall(_G.C_Item.RequestLoadItemDataByID, itemID)
	end
	return info
end

-- Fast class lookup for auction results that are not fully cached yet.
function ns.GetItemClassID(itemID)
	if not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) or itemID <= 0 then return nil end
	if _G.C_Item and type(_G.C_Item.GetItemInfoInstant) == "function" then
		local ok, _, _, _, _, _, classID = pcall(_G.C_Item.GetItemInfoInstant, itemID)
		if ok and classID then return classID end
	end
	if type(_G.GetItemInfoInstant) == "function" then
		local ok, _, _, _, _, _, classID = pcall(_G.GetItemInfoInstant, itemID)
		if ok and classID then return classID end
	end
	local info = ns.GetItemInfo(itemID)
	return info and info.classID
end

function ns.GetItemName(itemID)
	local info = ns.GetItemInfo(itemID)
	if info and info.name and not (_G.issecretvalue and _G.issecretvalue(info.name)) then
		return info.name
	end
	return "item:" .. tostring(itemID or "?")
end

-- What a vendor pays you for the item (vendor sell value).
function ns.GetVendorSellPrice(itemID)
	if not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) or itemID <= 0 then return nil end
	local info = ns.GetItemInfo(itemID)
	local raw = info and info.sellPrice
	if _G.issecretvalue and _G.issecretvalue(raw) then return nil end
	local price = tonumber(raw)
	if price and price > 0 then return price end
	return nil
end

-- Backwards-compatible name: this is the vendor sell value, not the buy cost.
function ns.GetVendorPrice(itemID)
	return ns.GetVendorSellPrice(itemID)
end

-- What a vendor charges for the item. Blizzard does not expose this for
-- arbitrary items; we cache it from merchant visits.
function ns.GetVendorBuyPrice(itemID)
	if not itemID or not ns.db or not ns.charKey then return nil end
	local byCharacter = ns.db.vendorBuy
	local cache = byCharacter and byCharacter[ns.charKey]
	local price = cache and tonumber(cache[itemID])
	if price and price > 0 then return price end
	return nil
end

function ns.SetVendorBuyPrice(itemID, price)
	if not itemID or not price or not ns.db or not ns.charKey then return end
	price = tonumber(price)
	if not price or price <= 0 then return end
	ns.db.vendorBuy = ns.db.vendorBuy or {}
	local cache = ns.db.vendorBuy[ns.charKey]
	if type(cache) ~= "table" then
		cache = {}
		ns.db.vendorBuy[ns.charKey] = cache
	end
	cache[itemID] = math.floor(price + 0.5)
end

function ns.GetItemIDFromLink(link)
	if type(link) ~= "string" then return nil end
	local id = link:match("item:(%d+)")
	return id and tonumber(id) or nil
end

function ns.SafeCall(fn, ...)
	if type(fn) ~= "function" then return false end
	local ok, err = pcall(fn, ...)
	if not ok then
		ns.ReportError(err)
	end
	return ok
end

local reportedErrors = {}
function ns.ReportError(err)
	local text = tostring(err or "unknown error")
	if reportedErrors[text] then return end
	reportedErrors[text] = true
	ns.Print("Lua error: " .. text)
end

function ns.Round(value, places)
	local mult = 10 ^ (places or 0)
	return floor(value * mult + 0.5) / mult
end

function ns.CopyTable(source)
	local result = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			result[key] = ns.CopyTable(value)
		else
			result[key] = value
		end
	end
	return result
end
