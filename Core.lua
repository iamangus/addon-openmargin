local addonName, ns = ...

ns.defaults = {
	schema = 1,
	settings = {
		tag = "profit",
		net = "ah",
		marginBasis = "sale",
		vendorBasis = "scanfree",
		sort = false,
		craftReagents = true,
		trainer = true,
		tooltips = true,
		panel = true,
		ahCut = 5,
		buyDebug = false,
	},
	recipes = {},
	known = {},
	meta = {},
	buyOrders = {},
}

local function applyDefaults(target, source)
	for key, value in pairs(source) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then target[key] = {} end
			applyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end

function ns.InitDB()
	ns.db = _G.OpenMarginDB
	if type(ns.db) ~= "table" then
		ns.db = {}
		_G.OpenMarginDB = ns.db
		ns.svFresh = true
	end

	applyDefaults(ns.db, ns.defaults)

	local settings = ns.db.settings
	if settings.tag ~= "profit" and settings.tag ~= "margin" and settings.tag ~= "both" then
		settings.tag = "profit"
	end
	if settings.net ~= "ah" and settings.net ~= "vendor" then
		settings.net = "ah"
	end
	if settings.marginBasis ~= "sale" and settings.marginBasis ~= "cost" then
		settings.marginBasis = "sale"
	end
	if settings.vendorBasis ~= "scanfree" and settings.vendorBasis ~= "full" then
		settings.vendorBasis = "scanfree"
	end
	settings.ahCut = ns.Clamp(tonumber(settings.ahCut) or 5, 0, 25)
	settings.sort = settings.sort == true
	settings.craftReagents = settings.craftReagents ~= false
	settings.trainer = settings.trainer ~= false
	settings.tooltips = settings.tooltips ~= false
	settings.panel = settings.panel ~= false
	settings.buyDebug = settings.buyDebug == true

	if type(ns.db.recipes) ~= "table" then ns.db.recipes = {} end
	if type(ns.db.known) ~= "table" then ns.db.known = {} end
	if type(ns.db.meta) ~= "table" then ns.db.meta = {} end
	if type(ns.db.buyOrders) ~= "table" then ns.db.buyOrders = {} end
	if ns.InitBuyOrders then ns.InitBuyOrders() end
	if ns.LoadBuyLog then ns.LoadBuyLog() end

	ns.RebuildRecipeIndex()
	if ns.SetCharacterKey then ns.SetCharacterKey() end
end

function ns.SetCharacterKey()
	local guid = nil
	if type(_G.UnitGUID) == "function" then
		local ok, value = pcall(_G.UnitGUID, "player")
		if ok then guid = value end
	end
	if not guid then
		local realm = type(_G.GetRealmName) == "function" and _G.GetRealmName() or "realm"
		local name = type(_G.UnitName) == "function" and _G.UnitName("player") or "player"
		guid = tostring(realm) .. "-" .. tostring(name)
	end
	ns.charKey = guid
end

function ns.OnSettingChanged()
	ns.sortContext = nil
	if ns.ClearEconCache then ns.ClearEconCache() end
	if ns.RefreshAll then ns.RefreshAll() end
end

function ns.ToggleSetting(key)
	if not ns.db or not ns.db.settings then return end
	ns.db.settings[key] = not ns.db.settings[key]
	ns.OnSettingChanged()
end

function ns.CycleTag()
	local order = { "profit", "margin", "both" }
	local current = ns.db.settings.tag or "profit"
	local nextIndex = 1
	for index = 1, #order do
		if order[index] == current then
			nextIndex = index % #order + 1
			break
		end
	end
	ns.db.settings.tag = order[nextIndex]
	ns.OnSettingChanged()
	return ns.db.settings.tag
end

function ns.CycleNet()
	ns.db.settings.net = ns.db.settings.net == "vendor" and "ah" or "vendor"
	ns.OnSettingChanged()
	return ns.db.settings.net
end

function ns.SetAHcut(value)
	value = tonumber(value)
	if not value then return false end
	ns.db.settings.ahCut = ns.Clamp(value, 0, 25)
	ns.OnSettingChanged()
	return true
end

function ns.ResetSettings()
	if not ns.db then return end
	ns.db.settings = ns.CopyTable(ns.defaults.settings)
	ns.sortContext = nil
	ns.OnSettingChanged()
end

function ns.ResetAll()
	if not ns.db then return end
	for key in pairs(ns.db) do ns.db[key] = nil end
	local fresh = ns.CopyTable(ns.defaults)
	for key, value in pairs(fresh) do ns.db[key] = value end
	ns.capturedAt = {}
	ns.capturedThisSession = {}
	ns.ensureFailed = {}
	ns.sortContext = nil
	if ns.ClearBuyRuntime then ns.ClearBuyRuntime() end
	if ns.ClearBuyLog then ns.ClearBuyLog() end
	ns.RebuildRecipeIndex()
	ns.InvalidatePrices()
	if ns.RefreshAll then ns.RefreshAll() end
	if ns.RefreshOptions then ns.RefreshOptions() end
end

function ns.GetStatusLines()
	local api = ns.GetAuctionatorAPI()
	local build = "unknown"
	if type(_G.GetBuildInfo) == "function" then
		local ok, version, buildNumber, _, interface = pcall(_G.GetBuildInfo)
		if ok then
			build = tostring(version) .. " (" .. tostring(buildNumber) .. ", interface " .. tostring(interface) .. ")"
		end
	end

	local lastCapture = ns.db and ns.db.meta and ns.db.meta.lastCaptureAt
	local captureText = lastCapture and (ns.FormatAge(time() - lastCapture) or "unknown") or "never"
	local lines = {
		"Build: " .. build,
		"Auctionator API: " .. (api and "available" or "NOT AVAILABLE"),
		"Tag mode: " .. tostring(ns.db.settings.tag) .. ", net mode: " .. tostring(ns.db.settings.net)
			.. ", margin: " .. tostring(ns.db.settings.marginBasis)
			.. ", vendor: " .. tostring(ns.db.settings.vendorBasis),
		"Sort by profit: " .. (ns.db.settings.sort and "on" or "off"),
		"Recipes stored: " .. tostring(ns.recipeCount or 0),
		"Known for this character: " .. tostring(ns.GetKnownRecipeCount()),
		"Buy orders: " .. tostring(ns.db and ns.db.buyOrders and #ns.db.buyOrders or 0),
		"Buy debug: " .. ((ns.IsBuyLogEnabled and ns.IsBuyLogEnabled()) and "on" or "off"),
		"Price cache: " .. tostring(ns.GetCacheCount()),
		"Last profession capture: " .. captureText,
		"Hooks: profession=" .. tostring(ns.profHooks and ns.profHooks.recipeList == true)
			.. ", trainer=" .. tostring(ns.trainerHooks and ns.trainerHooks.service == true)
			.. ", tooltip=" .. tostring(ns.tooltipHooked == true),
	}
	if ns.svFresh then
		lines[#lines + 1] = "SavedVariables were empty at load. On a first install this is normal; if not, restart the client once."
	end
	return lines
end

function ns.RefreshAll()
	local ok, err = pcall(function()
		if ns.RefreshProfessionList then ns.RefreshProfessionList() end
		if ns.RefreshBreakdown then ns.RefreshBreakdown() end
		if ns.RefreshTrainer then ns.RefreshTrainer() end
		if ns.RefreshBuyFrame then ns.RefreshBuyFrame() end
		if ns.RefreshOptions then ns.RefreshOptions() end
	end)
	if not ok then ns.ReportError(err) end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(ns.OnEvent, event, ...)
	if not ok then
		ns.ReportError(err)
	end
end)

local events = {
	"ADDON_LOADED",
	"PLAYER_LOGIN",
	"PLAYER_ENTERING_WORLD",
	"TRADE_SKILL_SHOW",
	"TRADE_SKILL_UPDATE",
	"NEW_RECIPE_LEARNED",
	"TRAINER_SHOW",
	"TRAINER_UPDATE",
	"TRAINER_CLOSED",
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"AUCTION_ITEM_LIST_UPDATE",
	"GET_ITEM_INFO_RECEIVED",
}

for index = 1, #events do
	pcall(frame.RegisterEvent, frame, events[index])
end

function ns.OnEvent(event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name == addonName then
			ns.InitDB()
			if ns.CreateOptions then ns.CreateOptions() end
			if ns.CheckAuctionator then ns.CheckAuctionator(true) end
		elseif name == "Auctionator" then
			if ns.CheckAuctionator then ns.CheckAuctionator(false) end
			ns.InvalidatePrices()
			if ns.RefreshAll then ns.RefreshAll() end
		elseif name == "Blizzard_ProfessionsTemplates" or name == "Blizzard_Professions" then
			if ns.InstallProfessionHooks then ns.InstallProfessionHooks() end
		elseif name == "Blizzard_TrainerUI" then
			if ns.InstallTrainerHooks then ns.InstallTrainerHooks() end
		end

	elseif event == "PLAYER_LOGIN" then
		if not ns.db then ns.InitDB() end
		ns.SetCharacterKey()
		ns.RebuildRecipeIndex()
		if ns.CheckAuctionator then ns.CheckAuctionator(false) end
		if ns.InstallSort then ns.InstallSort() end
		if ns.InstallProfessionHooks then ns.InstallProfessionHooks() end
		if ns.InstallTrainerHooks then ns.InstallTrainerHooks() end
		if ns.InstallTooltipHook then ns.InstallTooltipHook() end
		if ns.RegisterOptionsPanel then ns.RegisterOptionsPanel() end
		if ns.RefreshAll then ns.RefreshAll() end

	elseif event == "PLAYER_ENTERING_WORLD" then
		ns.InvalidatePrices()
		if ns.RefreshAll then ns.RefreshAll() end

	elseif event == "TRADE_SKILL_SHOW" then
		if ns.ScheduleCapture then ns.ScheduleCapture(false) end
		if ns.RefreshBreakdown then ns.RefreshBreakdown() end

	elseif event == "TRADE_SKILL_UPDATE" then
		if ns.RefreshVisibleRecipeTags then ns.RefreshVisibleRecipeTags() end

	elseif event == "NEW_RECIPE_LEARNED" then
		if ns.ScheduleCapture then ns.ScheduleCapture(true) end

	elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
		if ns.RefreshTrainer then ns.RefreshTrainer() end

	elseif event == "TRAINER_CLOSED" then
		if ns.RefreshTrainer then ns.RefreshTrainer() end

	elseif event == "AUCTION_HOUSE_SHOW" or event == "AUCTION_HOUSE_CLOSED" then
		if event == "AUCTION_HOUSE_SHOW" and ns.RegisterAuctionatorPriceUpdates then
			ns.RegisterAuctionatorPriceUpdates()
		end
		ns.InvalidatePrices()
		if ns.RefreshAll then ns.RefreshAll() end

	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		-- Older Auctionator builds have no price-update callback. A scan also
		-- fires this event for every page, so use it as a fallback signal.
		if not ns.dbUpdateRegistered and ns.NoteAuctionatorPricesChanged then
			ns.NoteAuctionatorPricesChanged()
		end

	elseif event == "GET_ITEM_INFO_RECEIVED" then
		if not ns.itemInfoPending and ns.After then
			ns.itemInfoPending = true
			ns.After(1, function()
				ns.itemInfoPending = false
				local ok, err = pcall(function()
					if ns.ClearEconCache then ns.ClearEconCache() end
					if ns.RefreshBreakdown then ns.RefreshBreakdown() end
					if ns.UpdateTrainerSummary then ns.UpdateTrainerSummary() end
				end)
				if not ok then ns.ReportError(err) end
			end)
		end
	end
end
