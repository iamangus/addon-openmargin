local addonName, ns = ...

local function getSettings(ctx)
	return (ctx and ctx.settings) or (ns.db and ns.db.settings) or {}
end

function ns.NewCostContext(opts)
	opts = opts or {}
	return {
		price = opts.price or ns.GetPrice,
		vendor = opts.vendor or ns.GetVendorPrice,
		recipes = opts.recipes,
		byOutput = opts.byOutput,
		known = opts.known,
		settings = opts.settings,
		memo = {},
		visiting = {},
		depth = 0,
		maxDepth = opts.maxDepth or 3,
	}
end

function ns.GetRecipe(recipeID, ctx)
	if not recipeID then return nil end
	if ctx and ctx.recipes then return ctx.recipes[recipeID] end
	return ns.db and ns.db.recipes and ns.db.recipes[recipeID]
end

function ns.GetRecipesForOutput(itemID, ctx)
	if not itemID then return nil end
	if ctx and ctx.byOutput then return ctx.byOutput[itemID] end
	return ns.byOutput and ns.byOutput[itemID]
end

function ns.IsRecipeKnown(recipeID, ctx)
	if ctx and ctx.known then return ctx.known(recipeID) == true end
	if not ns.db or not ns.charKey then return false end
	local known = ns.db.known and ns.db.known[ns.charKey]
	return known and known[recipeID] == true or false
end

-- Average output per craft. Most vanilla recipes are 1, but some produce
-- multiple items and a few have a range.
function ns.GetOutputQuantity(recipe)
	if not recipe then return 1 end
	local low = tonumber(recipe.outputMin) or 1
	local high = tonumber(recipe.outputMax) or low
	if low < 1 then low = 1 end
	if high < low then high = low end
	return (low + high) / 2
end

function ns.GetCraftCost(recipeID, ctx)
	ctx = ctx or ns.NewCostContext()
	if ctx.memo[recipeID] ~= nil then
		return ctx.memo[recipeID]
	end
	if ctx.visiting[recipeID] then
		return nil
	end
	if (ctx.depth or 0) >= (ctx.maxDepth or 3) then
		return nil
	end

	local recipe = ns.GetRecipe(recipeID, ctx)
	if not recipe then return nil end

	ctx.visiting[recipeID] = true
	ctx.depth = (ctx.depth or 0) + 1

	local total = 0
	local complete = true
	local details = {}
	local reagents = recipe.reagents or {}

	for index = 1, #reagents do
		local slot = reagents[index]
		if not slot.optional and (slot.qty or 0) > 0 then
			local bestUnit, bestSource, bestItemID
			local options = slot.itemIDs or {}
			for optionIndex = 1, #options do
				local itemID = options[optionIndex]
				local unit, source = ns.GetReagentUnitPrice(itemID, ctx)
				if unit and (not bestUnit or unit < bestUnit) then
					bestUnit, bestSource, bestItemID = unit, source, itemID
				end
			end

			if bestUnit then
				local line = slot.qty * bestUnit
				total = total + line
				details[#details + 1] = {
					itemID = bestItemID,
					qty = slot.qty,
					unit = bestUnit,
					line = line,
					source = bestSource,
				}
			else
				complete = false
				details[#details + 1] = {
					itemID = options[1],
					qty = slot.qty,
					unit = nil,
					line = nil,
					source = "unpriced",
				}
			end
		end
	end

	ctx.depth = ctx.depth - 1
	ctx.visiting[recipeID] = nil

	local result = {
		cost = total,
		complete = complete and #details > 0,
		details = details,
		recipeID = recipeID,
	}
	ctx.memo[recipeID] = result
	return result
end

function ns.GetCraftReagentUnit(itemID, ctx)
	local recipes = ns.GetRecipesForOutput(itemID, ctx)
	if not recipes then return nil end

	local bestUnit, bestRecipeID
	for index = 1, #recipes do
		local recipeID = recipes[index]
		local recipe = ns.GetRecipe(recipeID, ctx)
		if recipe and ns.IsRecipeKnown(recipeID, ctx) and not (ctx.visiting and ctx.visiting[recipeID]) then
			local craft = ns.GetCraftCost(recipeID, ctx)
			if craft and craft.complete and craft.cost > 0 then
				local perUnit = craft.cost / ns.GetOutputQuantity(recipe)
				if not bestUnit or perUnit < bestUnit then
					bestUnit = perUnit
					bestRecipeID = recipeID
				end
			end
		end
	end

	return bestUnit, bestRecipeID
end

-- Effective unit price for a reagent.
-- Order: cheapest of Auctionator price, vendor purchase price, and own craft
-- cost. A nil or non-positive price is treated as unavailable.
function ns.GetReagentUnitPrice(itemID, ctx)
	ctx = ctx or ns.NewCostContext()
	local settings = getSettings(ctx)

	local market = ctx.price and ctx.price(itemID) or nil
	local vendor = ctx.vendor and ctx.vendor(itemID) or nil
	local best, source

	if market and market > 0 then
		best, source = market, "auction"
	end
	if vendor and vendor > 0 and (not best or vendor < best) then
		best, source = vendor, "vendor"
	end

	if settings.craftReagents ~= false then
		local craftUnit = ns.GetCraftReagentUnit(itemID, ctx)
		if craftUnit and craftUnit > 0 and (not best or craftUnit < best) then
			best, source = craftUnit, "craft"
		end
	end

	return best, source
end

function ns.GetVendorCost(recipe, ctx)
	ctx = ctx or ns.NewCostContext()
	local total = 0
	local complete = true
	local details = {}
	local reagents = recipe and recipe.reagents or {}

	for index = 1, #reagents do
		local slot = reagents[index]
		if not slot.optional and (slot.qty or 0) > 0 then
			local bestVendor
			local options = slot.itemIDs or {}
			for optionIndex = 1, #options do
				local vendor = ctx.vendor and ctx.vendor(options[optionIndex]) or nil
				if vendor and vendor > 0 and (not bestVendor or vendor < bestVendor) then
					bestVendor = vendor
				end
			end
			if bestVendor then
				total = total + slot.qty * bestVendor
				details[#details + 1] = {
					qty = slot.qty,
					unit = bestVendor,
					line = slot.qty * bestVendor,
				}
			else
				-- Scan-free vendor flip treats non-vendor reagents as free.
				details[#details + 1] = {
					qty = slot.qty,
					unit = nil,
					line = 0,
				}
			end
		end
	end

	return total, details
end

function ns.GetEconomics(recipeID, ctx)
	ctx = ctx or ns.NewCostContext()
	local recipe = ns.GetRecipe(recipeID, ctx)
	if not recipe then
		return nil
	end

	local settings = getSettings(ctx)
	local costInfo = ns.GetCraftCost(recipeID, ctx)
	local outputQty = ns.GetOutputQuantity(recipe)
	local outputItemID = recipe.outputItemID

	local saleUnit = outputItemID and ctx.price and ctx.price(outputItemID) or nil
	local sale = saleUnit and saleUnit > 0 and saleUnit * outputQty or nil

	local cutPercent = tonumber(settings.ahCut) or 5
	cutPercent = ns.Clamp(cutPercent, 0, 25)
	local cut = cutPercent / 100

	local net, marginSale, marginCost
	if costInfo and costInfo.complete and sale then
		net = sale * (1 - cut) - costInfo.cost
		if sale > 0 then marginSale = net / sale end
		if costInfo.cost > 0 then marginCost = net / costInfo.cost end
	end

	local vendorUnit = outputItemID and ctx.vendor and ctx.vendor(outputItemID) or nil
	local vendorSale = vendorUnit and vendorUnit > 0 and vendorUnit * outputQty or nil
	local vendorCost = ns.GetVendorCost(recipe, ctx)
	local vendorNet = vendorSale and (vendorSale - vendorCost) or nil
	local vendorMarginSale = (vendorSale and vendorSale > 0 and vendorNet) and (vendorNet / vendorSale) or nil
	local vendorMarginCost = (vendorCost > 0 and vendorNet) and (vendorNet / vendorCost) or nil

	-- The original addon's vendor figure uses the same full craft cost as the
	-- AH calculation. We keep it available for the tooltip, but the tag/panel
	-- use the explicitly requested scan-free vendor flip.
	local vendorNetFull = (vendorSale and costInfo and costInfo.complete) and (vendorSale - costInfo.cost) or nil

	return {
		recipeID = recipeID,
		recipe = recipe,
		cost = costInfo and costInfo.cost,
		costComplete = costInfo and costInfo.complete or false,
		details = costInfo and costInfo.details or {},
		sale = sale,
		saleUnit = saleUnit,
		outputQty = outputQty,
		ahCutPercent = cutPercent,
		ahCut = sale and sale * cut or nil,
		net = net,
		margin = marginSale,
		marginSale = marginSale,
		marginCost = marginCost,
		vendorSale = vendorSale,
		vendorCost = vendorCost,
		vendorNet = vendorNet,
		vendorNetFull = vendorNetFull,
		vendorMargin = vendorMarginSale,
		vendorMarginSale = vendorMarginSale,
		vendorMarginCost = vendorMarginCost,
	}
end

ns.econCache = {}

function ns.ClearEconCache()
	ns.econCache = {}
end

function ns.GetCachedEconomics(recipeID)
	if not ns.db or not recipeID then return ns.GetEconomics(recipeID) end
	local settings = ns.db.settings
	local epoch = ns.priceEpoch or 1
	local entry = ns.econCache[recipeID]
	if entry
		and entry.epoch == epoch
		and entry.craftReagents == settings.craftReagents
		and entry.ahCut == settings.ahCut then
		return entry.econ
	end

	local econ = ns.GetEconomics(recipeID)
	ns.econCache[recipeID] = {
		epoch = ns.priceEpoch or epoch,
		craftReagents = settings.craftReagents,
		ahCut = settings.ahCut,
		econ = econ,
	}
	return econ
end

function ns.GetVendorMetric(econ, settings)
	settings = settings or (ns.db and ns.db.settings) or {}
	if not econ then return nil, nil end
	if settings.vendorBasis == "full" then
		local value = econ.vendorNetFull
		local percent = (value and econ.cost and econ.cost > 0) and (value / econ.cost) or nil
		return value, percent
	end
	return econ.vendorNet, econ.vendorMarginSale
end

function ns.GetMetric(econ, settings)
	settings = settings or (ns.db and ns.db.settings) or {}
	if not econ then return nil, nil end
	if settings.net == "vendor" then
		return ns.GetVendorMetric(econ, settings)
	end
	if settings.marginBasis == "cost" then
		return econ.net, econ.marginCost
	end
	return econ.net, econ.marginSale
end

function ns.GetSortValue(recipeID, ctx)
	local econ = ns.GetEconomics(recipeID, ctx)
	local value = ns.GetMetric(econ)
	return value
end

function ns.GetRecipeName(recipeID)
	local recipe = ns.GetRecipe(recipeID)
	return recipe and recipe.name or ("recipe:" .. tostring(recipeID))
end

function ns.GetTag(econ)
	local settings = (ns.db and ns.db.settings) or {}
	local value, percent = ns.GetMetric(econ, settings)

	if not value then
		return "—", 0.55, 0.55, 0.55
	end

	local r, g, b
	if value > 0 then
		r, g, b = 0.25, 1.0, 0.25
	elseif value < 0 then
		r, g, b = 1.0, 0.30, 0.30
	else
		r, g, b = 0.80, 0.80, 0.80
	end

	local mode = settings.tag or "profit"
	if mode == "margin" then
		if not percent then
			return "—", 0.55, 0.55, 0.55
		end
		return ns.FormatPercent(percent, true), r, g, b
	elseif mode == "both" then
		if not percent then
			return ns.FormatMoney(value, true), r, g, b
		end
		return ns.FormatMoney(value, true) .. " " .. ns.FormatPercent(percent, true), r, g, b
	end

	return ns.FormatMoney(value, true), r, g, b
end

function ns.GetDataset()
	return {
		recipes = {
			[1] = {
				id = 1,
				name = "Test Bag",
				outputItemID = 100,
				outputMin = 1,
				outputMax = 1,
				reagents = {
					{ itemIDs = { 200 }, qty = 2 },
					{ itemIDs = { 201 }, qty = 1 },
				},
			},
			[2] = {
				id = 2,
				name = "Test Cloth",
				outputItemID = 200,
				outputMin = 1,
				outputMax = 1,
				reagents = {
					{ itemIDs = { 300 }, qty = 4 },
				},
			},
			[3] = {
				id = 3,
				name = "Test Ore",
				outputItemID = 300,
				outputMin = 1,
				outputMax = 1,
				reagents = {
					{ itemIDs = { 400 }, qty = 1 },
				},
			},
			[4] = {
				id = 4,
				name = "Cycle A",
				outputItemID = 500,
				outputMin = 1,
				outputMax = 1,
				reagents = { { itemIDs = { 501 }, qty = 1 } },
			},
			[5] = {
				id = 5,
				name = "Cycle B",
				outputItemID = 501,
				outputMin = 1,
				outputMax = 1,
				reagents = { { itemIDs = { 500 }, qty = 1 } },
			},
		},
		prices = {
			[100] = 20000,
			[200] = 2500,
			[201] = 1000,
			[300] = 500,
			[400] = 100,
			[500] = 1000,
			[501] = 1000,
		},
		vendors = {
			[100] = 4000,
			[201] = 120,
			[400] = 200,
		},
	}
end

function ns.RunSelfTest()
	local dataset = ns.GetDataset()
	local byOutput = {}
	for id, recipe in pairs(dataset.recipes) do
		if recipe.outputItemID then
			byOutput[recipe.outputItemID] = byOutput[recipe.outputItemID] or {}
			table.insert(byOutput[recipe.outputItemID], id)
		end
	end

	local ctx = ns.NewCostContext({
		recipes = dataset.recipes,
		byOutput = byOutput,
		price = function(itemID) return dataset.prices[itemID] end,
		vendor = function(itemID) return dataset.vendors[itemID] end,
		known = function() return true end,
		settings = { ahCut = 5, craftReagents = true },
	})

	local results = {}
	local function check(name, actual, expected)
		local ok = actual == expected
		results[#results + 1] = string.format("%s %s (%s)", ok and "PASS" or "FAIL", name, tostring(actual))
		return ok
	end

	local cost = ns.GetCraftCost(1, ctx)
	-- Test Bag: 2 x Test Cloth (crafted from 4 x Test Ore) + thread.
	-- Cloth craft cost = 4 x 100 = 400; 2 cloth = 800; thread vendor = 120;
	-- total 920.
	check("craft chain cost", cost and cost.cost, 920)
	check("craft chain complete", cost and cost.complete, true)

	local econ = ns.GetEconomics(1, ctx)
	-- Sale 20000, cut 5% = 1000, net = 19000 - 920 = 18080.
	check("net profit", econ and econ.net, 18080)
	check("margin sale", econ and ns.Round(econ.marginSale * 100, 3), 90.4)
	check("vendor net scan-free", econ and econ.vendorNet, 3880)
	check("vendor net full cost", econ and econ.vendorNetFull, 3080)

	-- A cycle must terminate and fall back to the market price.
	local cycleEcon = ns.GetEconomics(4, ctx)
	check("cycle terminates", cycleEcon ~= nil, true)

	check("compact gold", ns.FormatMoney(124000, true), "+12.4g")
	check("compact silver", ns.FormatMoney(-3500, true), "-35s")
	check("margin format", ns.FormatPercent(0.27, true), "+27%")

	local failures = 0
	for _, line in ipairs(results) do
		if line:find("^FAIL") then failures = failures + 1 end
	end
	if failures == 0 then
		return "Self-test passed (" .. #results .. " checks)."
	end
	return "Self-test failed (" .. failures .. " of " .. #results .. "):\n" .. table.concat(results, "\n")
end
