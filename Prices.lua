local addonName, ns = ...

local API_CALLER = "OpenMargin"
local CACHE_SECONDS = 30

ns.priceCache = {}
ns.priceEpoch = 1
ns.auctionatorReady = false

function ns.InvalidatePrices()
	ns.priceCache = {}
	ns.priceEpoch = (ns.priceEpoch or 1) + 1
	ns.sortContext = nil
	if ns.ClearEconCache then ns.ClearEconCache() end
end

function ns.CheckAuctionator(silent)
	local api = ns.GetAuctionatorAPI()
	ns.auctionatorReady = api ~= nil
	if not api and not silent and not ns.warnedAuctionator then
		ns.warnedAuctionator = true
		ns.Print("Auctionator is not loaded. OpenMargin reads Auctionator prices; install and enable Auctionator.")
	end
	if api and ns.warnedAuctionator then
		ns.Print("Auctionator detected. Prices are available.")
		ns.warnedAuctionator = false
		ns.InvalidatePrices()
		if ns.RefreshAll then ns.RefreshAll() end
	end
	return ns.auctionatorReady
end

function ns.GetAuctionatorPrice(itemID)
	local api = ns.GetAuctionatorAPI()
	if not api or not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) or itemID <= 0 then return nil end

	local ok, price = pcall(api.GetAuctionPriceByItemID, API_CALLER, itemID)
	if ok and type(price) == "number" and not (_G.issecretvalue and _G.issecretvalue(price)) and price > 0 then
		return price
	end
	return nil
end

-- Auctionator's public price API does not document an age call. The original
-- addon uses it opportunistically when present. Its age is normally expressed
-- in days; some builds may return seconds or an epoch timestamp.
function ns.GetAuctionatorAge(itemID)
	local api = ns.GetAuctionatorAPI()
	local getAge = api and api.GetAuctionAge
	if type(getAge) ~= "function" or not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) then return nil end

	local ok, age = pcall(getAge, API_CALLER, itemID)
	if not ok or type(age) ~= "number" or (_G.issecretvalue and _G.issecretvalue(age)) or age < 0 then return nil end

	if age > 1000000000 then
		age = time() - age
	else
		-- Auctionator's age is expressed in days.
		age = age * 86400
	end

	if age < 0 then age = 0 end
	return age
end

function ns.GetPrice(itemID, ctx)
	if ctx and ctx.price then
		return ctx.price(itemID)
	end
	if not itemID or (_G.issecretvalue and _G.issecretvalue(itemID)) or itemID <= 0 then return nil end

	local now = GetTime()
	local cached = ns.priceCache[itemID]
	if cached and (now - cached.at) < CACHE_SECONDS then
		return cached.price, cached.age
	end

	local price = ns.GetAuctionatorPrice(itemID)
	local age = price and ns.GetAuctionatorAge(itemID) or nil
	local previousPrice = cached and cached.price
	if previousPrice ~= price then
		ns.priceEpoch = (ns.priceEpoch or 1) + 1
		if ns.ClearEconCache then ns.ClearEconCache() end
	end

	ns.priceCache[itemID] = {
		price = price,
		age = age,
		at = now,
	}

	return price, age
end

function ns.GetPriceInfo(itemID)
	local price, age = ns.GetPrice(itemID)
	return {
		itemID = itemID,
		price = price,
		age = age,
		source = price and "Auctionator" or nil,
	}
end

function ns.GetSourceLabel(itemID)
	local price, age = ns.GetPrice(itemID)
	if not price then
		return nil
	end
	if age then
		return "Auctionator, " .. (ns.FormatAge(age) or "age unknown")
	end
	return "Auctionator"
end

function ns.GetCacheCount()
	local count = 0
	for _, entry in pairs(ns.priceCache) do
		if entry.price then count = count + 1 end
	end
	return count
end
