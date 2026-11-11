local addonName, ns = ...

-- Crafting Paths: survey every recipe the account can see and rank the
-- profitable ones. A path is a craft whose reagents are bought, vendored, or
-- crafted through other recipes. Recipes learned by any character count, and
-- recipes that are not learned yet are shown with their skill gap or unlock
-- cost.

local RECIPE_CLASS_ID = 9
local ROW_HEIGHT = 44
local VISIBLE_ROWS = 8
local SURVEY_BATCH = 25
local EXIT_AH = "ah"
local EXIT_VENDOR = "vendor"
local EXIT_DE = "de"

local SORT_PRICE = {
	{ sortOrder = _G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false },
}

local EXIT_LABELS = {
	[EXIT_AH] = "AH",
	[EXIT_VENDOR] = "Vendor",
	[EXIT_DE] = "DE",
}

local EXIT_TEXTURES = {
	[EXIT_AH] = { 0.25, 0.85, 0.45 },
	[EXIT_VENDOR] = { 0.95, 0.8, 0.25 },
	[EXIT_DE] = { 0.75, 0.55, 1 },
}

local SOURCE_LABELS = {
	auction = "AH",
	vendor = "vendor",
	craft = "craft",
	unpriced = "no price",
}

local function log(fmt, ...)
	if ns.BuyLog then ns.BuyLog(fmt, ...) end
end

local function safeClick(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok and ns.ReportError then ns.ReportError(err) end
	end
end

local function hasValue(value)
	return type(value) == "number" and value == value and value > 0
end

-- ---------------------------------------------------------------------------
-- Account catalog
-- ---------------------------------------------------------------------------

function ns.InvalidateAccountKnown()
	ns.accountKnownSet = nil
	ns.accountKnownChars = nil
	ns.accountKnownProfessions = nil
end

local function ensureAccountKnown()
	if ns.accountKnownSet then return end
	local set, chars = {}, {}
	local known = ns.db and ns.db.known or {}
	for charKey, recipes in pairs(known) do
		if type(recipes) == "table" then
			for recipeID, value in pairs(recipes) do
				if value then
					set[recipeID] = true
					local list = chars[recipeID]
					if not list then
						list = {}
						chars[recipeID] = list
					end
					list[#list + 1] = charKey
				end
			end
		end
	end
	local professions = {}
	for recipeID in pairs(set) do
		local record = ns.db and ns.db.recipes and ns.db.recipes[recipeID]
		if record and record.professionID then
			professions[record.professionID] = true
		end
	end
	ns.accountKnownSet = set
	ns.accountKnownChars = chars
	ns.accountKnownProfessions = professions
end

function ns.IsAccountKnown(recipeID)
	if not recipeID then return false end
	local record = ns.db and ns.db.recipes and ns.db.recipes[recipeID]
	if record and record.synthetic then return true end
	ensureAccountKnown()
	return ns.accountKnownSet[recipeID] == true
end

function ns.GetRecipeCharacters(recipeID)
	if not recipeID then return {} end
	ensureAccountKnown()
	return ns.accountKnownChars[recipeID] or {}
end

function ns.GetCharacterName(charKey)
	local characters = ns.db and ns.db.characters
	local record = characters and characters[charKey]
	if type(record) == "table" and record.name then return record.name end
	local name = tostring(charKey or "?"):match("([^-]+)$")
	return name or tostring(charKey or "?")
end

function ns.AccountHasProfession(professionID)
	if not professionID then return false end
	if ns.GetBestProfessionCharacter(professionID) then return true end
	ensureAccountKnown()
	return ns.accountKnownProfessions and ns.accountKnownProfessions[professionID] == true or false
end

function ns.GetBestProfessionCharacter(professionID)
	if not professionID then return nil end
	local characters = ns.db and ns.db.characters or {}
	local best
	for charKey, character in pairs(characters) do
		local profession = type(character) == "table" and character.professions and character.professions[professionID]
		if profession then
			local skill = tonumber(profession.skill) or 0
			if not best or skill > best.skill then
				best = {
					charKey = charKey,
					name = ns.GetCharacterName(charKey),
					skill = skill,
					profession = profession,
				}
			end
		end
	end
	return best
end

function ns.GetCatalogStats()
	local characters = ns.db and ns.db.characters or {}
	local charCount = 0
	local professions = {}
	for charKey, character in pairs(characters) do
		if type(character) == "table" then
			charCount = charCount + 1
			for professionID, profession in pairs(character.professions or {}) do
				local name = profession.name or tostring(professionID)
				professions[name] = true
			end
		end
	end
	local professionCount = 0
	for _ in pairs(professions) do professionCount = professionCount + 1 end

	local recipeItems = 0
	for _ in pairs(ns.db and ns.db.recipeItems or {}) do recipeItems = recipeItems + 1 end

	local recipes = 0
	for _, record in pairs(ns.db and ns.db.recipes or {}) do
		if type(record) == "table" and not record.synthetic then
			recipes = recipes + 1
		end
	end

	return {
		characters = charCount,
		professions = professionCount,
		recipes = recipes,
		recipeItems = recipeItems,
	}
end

-- ---------------------------------------------------------------------------
-- Smelting fallback
-- ---------------------------------------------------------------------------

-- Gathering professions do not always expose smelting recipes through the
-- profession API. These conversions are injected as synthetic Mining recipes
-- only when the client has not captured a matching recipe, so ore -> bar
-- chains still work.
local SMELTING = {
	{ name = "Smelt Copper", profession = "Mining", professionID = 186, output = 2840, outputQty = 1, reagents = { { 2770, 1 } } },
	{ name = "Smelt Tin", profession = "Mining", professionID = 186, output = 3576, outputQty = 1, reagents = { { 2771, 1 } } },
	{ name = "Smelt Bronze", profession = "Mining", professionID = 186, output = 2841, outputQty = 2, reagents = { { 2840, 1 }, { 3576, 1 } } },
	{ name = "Smelt Silver", profession = "Mining", professionID = 186, output = 2842, outputQty = 1, reagents = { { 2775, 1 } } },
	{ name = "Smelt Iron", profession = "Mining", professionID = 186, output = 3575, outputQty = 1, reagents = { { 2772, 1 } } },
	{ name = "Smelt Gold", profession = "Mining", professionID = 186, output = 3577, outputQty = 1, reagents = { { 2776, 1 } } },
	{ name = "Smelt Steel", profession = "Mining", professionID = 186, output = 3859, outputQty = 1, reagents = { { 3575, 1 }, { 3857, 1 } } },
	{ name = "Smelt Mithril", profession = "Mining", professionID = 186, output = 3860, outputQty = 1, reagents = { { 3858, 1 } } },
	{ name = "Smelt Truesilver", profession = "Mining", professionID = 186, output = 6037, outputQty = 1, reagents = { { 7911, 1 } } },
	{ name = "Smelt Thorium", profession = "Mining", professionID = 186, output = 12359, outputQty = 1, reagents = { { 10620, 1 } } },
	{ name = "Smelt Arcanite", profession = "Mining", professionID = 186, output = 12360, outputQty = 1, reagents = { { 12359, 1 }, { 12363, 1 } } },
}

local function hasMatchingRecipe(output, reagents)
	local recipes = ns.byOutput and ns.byOutput[output]
	if not recipes then return false end
	for index = 1, #recipes do
		local recipe = ns.db.recipes[recipes[index]]
		if recipe then
			local slots = recipe.reagents or {}
			local matched = 0
			for slotIndex = 1, #slots do
				local slot = slots[slotIndex]
				for optionIndex = 1, #(slot.itemIDs or {}) do
					for wantedIndex = 1, #reagents do
						if slot.itemIDs[optionIndex] == reagents[wantedIndex][1] then
							matched = matched + 1
							break
						end
					end
				end
			end
			if matched == #reagents then return true end
		end
	end
	return false
end

function ns.EnsureSmeltingFallback()
	if not ns.db or not ns.db.recipes then return end

	for index = 1, #SMELTING do
		local conversion = SMELTING[index]
		if not hasMatchingRecipe(conversion.output, conversion.reagents) then
			local recipeID = -1000 - index
			local reagents = {}
			for reagentIndex = 1, #conversion.reagents do
				local reagent = conversion.reagents[reagentIndex]
				reagents[#reagents + 1] = { itemIDs = { reagent[1] }, qty = reagent[2] }
			end
			local record = {
				id = recipeID,
				name = conversion.name,
				professionID = conversion.professionID,
				professionName = conversion.profession,
				outputItemID = conversion.output,
				outputMin = conversion.outputQty,
				outputMax = conversion.outputQty,
				reagents = reagents,
				schemaLoaded = true,
				synthetic = true,
			}
			ns.db.recipes[recipeID] = record
			ns.AddRecipeToIndex(record)
		end
	end
end

local function sameReagents(lhs, rhs)
	local left = lhs.reagents or {}
	local right = rhs.reagents or {}
	if #left ~= #right then return false end
	for index = 1, #left do
		local leftIDs = left[index].itemIDs or {}
		local rightIDs = right[index].itemIDs or {}
		local found = false
		for leftIndex = 1, #leftIDs do
			for rightIndex = 1, #rightIDs do
				if leftIDs[leftIndex] == rightIDs[rightIndex] then found = true break end
			end
			if found then break end
		end
		if not found then return false end
	end
	return true
end

-- Called from RebuildRecipeIndex so a captured smelting recipe replaces the
-- fallback instead of duplicating it.
function ns.PruneSyntheticRecipes()
	if not ns.db or not ns.db.recipes then return end
	local real = {}
	for recipeID, record in pairs(ns.db.recipes) do
		if type(record) == "table" and record.outputItemID and not record.synthetic then
			local list = real[record.outputItemID]
			if not list then
				list = {}
				real[record.outputItemID] = list
			end
			list[#list + 1] = record
		end
	end
	for recipeID, record in pairs(ns.db.recipes) do
		if type(record) == "table" and record.synthetic then
			local list = real[record.outputItemID]
			if list then
				for index = 1, #list do
					if sameReagents(record, list[index]) then
						ns.db.recipes[recipeID] = nil
						break
					end
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Costs and paths
-- ---------------------------------------------------------------------------

function ns.BuildAccountContext(craftReagents)
	if ns.EnsureSmeltingFallback then ns.EnsureSmeltingFallback() end
	local settings = {}
	local base = ns.db and ns.db.settings or {}
	for key, value in pairs(base) do settings[key] = value end
	settings.craftReagents = craftReagents == true

	return ns.NewCostContext({
		price = ns.GetPrice,
		vendor = ns.GetVendorBuyPrice,
		vendorSell = ns.GetVendorSellPrice,
		recipes = ns.db and ns.db.recipes,
		byOutput = ns.byOutput,
		known = function(recipeID) return ns.IsAccountKnown(recipeID) end,
		settings = settings,
		maxDepth = 6,
	})
end

-- Build the chosen reagent tree for one recipe. Each reagent is the cheapest
-- of Auction House, vendor or another craft, matching the survey numbers.
function ns.BuildCraftPath(recipeID, ctx, depth)
	ctx = ctx or ns.BuildAccountContext(true)
	depth = depth or 0
	if not recipeID or depth > (ctx.maxDepth or 6) then return nil end
	ctx.visiting = ctx.visiting or {}
	if ctx.visiting[recipeID] then return nil end

	local recipe = ns.GetRecipe(recipeID, ctx)
	if not recipe then return nil end

	ctx.visiting[recipeID] = true
	local path = {
		recipeID = recipeID,
		name = recipe.name or ns.GetItemName(recipe.outputItemID),
		professionName = recipe.professionName,
		characters = ns.GetRecipeCharacters(recipeID),
		outputItemID = recipe.outputItemID,
		outputQty = ns.GetOutputQuantity(recipe),
		reagents = {},
		cost = 0,
		complete = true,
	}

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

			local line = {
				itemID = bestItemID,
				qty = slot.qty,
				unit = bestUnit,
				source = bestSource,
			}
			if bestUnit then
				line.line = slot.qty * bestUnit
				path.cost = path.cost + line.line
				if bestSource == "craft" then
					local _, craftRecipeID = ns.GetCraftReagentUnit(bestItemID, ctx)
					line.recipeID = craftRecipeID
					if craftRecipeID then
						line.path = ns.BuildCraftPath(craftRecipeID, ctx, depth + 1)
					end
				end
			else
				path.complete = false
				line.source = "unpriced"
			end
			path.reagents[#path.reagents + 1] = line
		end
	end

	ctx.visiting[recipeID] = nil
	return path
end

function ns.ParseRequiredSkillText(text, professionName)
	if type(text) ~= "string" or text == "" then return nil end
	local lower = text:lower()
	local profession = professionName and tostring(professionName):lower() or nil
	if profession and profession ~= "" then
		if not lower:find(profession, 1, true) then return nil end
	elseif not lower:find("requires", 1, true) then
		return nil
	end
	local number = text:match("%((%d+)%)") or text:match("(%d+)")
	number = tonumber(number)
	if number and number > 0 and number <= 1000 then return number end
	return nil
end

function ns.GetTooltipRequiredSkill(data, professionName)
	if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	for index = 1, #data.lines do
		local line = data.lines[index]
		if type(line) == "table" then
			local skill = ns.ParseRequiredSkillText(line.leftText, professionName)
				or ns.ParseRequiredSkillText(line.rightText, professionName)
			if skill then return skill end
		end
	end
	return nil
end

-- The required skill is not in TradeSkillRecipeInfo. Recipe items carry it in
-- their tooltip ("Requires Enchanting (75)"), and so does the recipe spell.
function ns.GetItemRequiredSkill(itemID, professionName)
	if not itemID or itemID <= 0 then return nil end
	local api = _G.C_TooltipInfo
	if not api or type(api.GetItemByID) ~= "function" then return nil end
	ns.GetItemInfo(itemID)
	local ok, data = pcall(api.GetItemByID, itemID)
	if not ok then return nil end
	return ns.GetTooltipRequiredSkill(data, professionName)
end

function ns.GetSpellRequiredSkill(recipeID, professionName)
	if not recipeID then return nil end
	local api = _G.C_TooltipInfo
	if not api or type(api.GetSpellByID) ~= "function" then return nil end
	local ok, data = pcall(api.GetSpellByID, recipeID)
	if not ok then return nil end
	return ns.GetTooltipRequiredSkill(data, professionName)
end

function ns.GetPathRequiredSkill(recipeID, record)
	if not record then return nil end

	local trainer = ns.db and ns.db.trainerSkillReq and ns.db.trainerSkillReq[recipeID]
	if trainer and tonumber(trainer.skill) and tonumber(trainer.skill) > 0 then
		return tonumber(trainer.skill), trainer.name or record.professionName
	end

	local skill = tonumber(record.requiredSkill)
	if skill and skill > 0 then
		return skill, record.requiredSkillName or record.professionName
	end

	local item = ns.db and ns.db.recipeItems and ns.db.recipeItems[recipeID]
	if item and item.itemID then
		skill = ns.GetItemRequiredSkill(item.itemID, record.professionName)
		if skill then
			record.requiredSkill = skill
			record.requiredSkillName = record.professionName
			return skill, record.professionName
		end
	end

	-- Building spell tooltips is comparatively expensive. Cache both success
	-- and failure so a survey does not rebuild them for every refresh.
	if not (record.requiredSkillMissingAt and (time() - record.requiredSkillMissingAt) < 86400) then
		skill = ns.GetSpellRequiredSkill(recipeID, record.professionName)
		if skill then
			record.requiredSkill = skill
			record.requiredSkillName = record.professionName
			return skill, record.professionName
		end
		record.requiredSkillMissingAt = time()
	end

	skill = ns.ParseRequiredSkillText(record.disabledReason, record.professionName)
	if skill then return skill, record.professionName end
	local requirements = record.requirements
	if requirements then
		for index = 1, #requirements do
			skill = ns.ParseRequiredSkillText(requirements[index].name, record.professionName)
			if skill then return skill, record.professionName end
		end
	end
	return nil
end

function ns.GetPathSourceLabel(recipeID, record)
	if ns.db then
		if ns.db.trainerSkillReq and ns.db.trainerSkillReq[recipeID] then return "Trainer" end
		if ns.db.trainerCosts and ns.db.trainerCosts[recipeID] then return "Trainer" end
		if (ns.db.recipeItems and ns.db.recipeItems[recipeID]) or (record and record.recipeItemID) then
			return "Recipe item"
		end
	end
	if record and record.sourceText and record.sourceText ~= "" then
		return tostring(record.sourceText)
	end
	return nil
end

function ns.GetPathAvailability(recipeID, record)
	local characters = ns.GetRecipeCharacters(recipeID)
	if #characters > 0 then
		local names = {}
		for index = 1, #characters do
			names[#names + 1] = ns.GetCharacterName(characters[index])
		end
		return "ready", table.concat(names, ", ")
	end

	local best = ns.GetBestProfessionCharacter(record and record.professionID)
	if not best then
		-- Older captures can exist before the character registry was added.
		-- A learned recipe in that profession proves the account has it.
		if record and record.professionID and ns.accountKnownProfessions and ns.accountKnownProfessions[record.professionID] then
			return "obtain", "Not learned"
		end
		return "missing", "No character has " .. tostring(record and record.professionName or "this profession")
	end

	local requiredSkill, requiredName = ns.GetPathRequiredSkill(recipeID, record)
	if requiredSkill and best and (tonumber(best.skill) or 0) < requiredSkill then
		return "skill", string.format("Requires %s %d · current %d",
			tostring(requiredName or record.professionName or "skill"),
			requiredSkill,
			tonumber(best.skill) or 0)
	end

	local unmet = {}
	local requirements = record and record.requirements
	if requirements then
		for index = 1, #requirements do
			local requirement = requirements[index]
			if requirement and requirement.met == false then
				unmet[#unmet + 1] = requirement.name ~= "" and requirement.name or "requirement"
			end
		end
	end
	local trainerRequirement = ns.db and ns.db.trainerSkillReq and ns.db.trainerSkillReq[recipeID]
	if trainerRequirement and tonumber(trainerRequirement.skill) and best.skill < trainerRequirement.skill then
		return "skill", string.format("Requires %s %d · current %d",
			tostring(trainerRequirement.name or record.professionName or "skill"),
			trainerRequirement.skill,
			best.skill)
	end
	if #unmet > 0 then
		return "skill", table.concat(unmet, ", ") .. " · skill " .. tostring(best.skill or 0)
	end

	return "obtain", "Not learned"
end

function ns.GetPathUnlockCost(recipeID, record)
	local item = ns.db and ns.db.recipeItems and ns.db.recipeItems[recipeID]
	local best

	if item and item.itemID then
		local live = tonumber(item.price)
		if live and item.seenAt and (time() - item.seenAt) > 7 * 86400 then live = nil end
		if hasValue(live) then best = live end
		local auction = ns.GetPrice(item.itemID)
		if hasValue(auction) and (not best or auction < best) then best = auction end
		local vendor = ns.GetVendorBuyPrice(item.itemID)
		if hasValue(vendor) and (not best or vendor < best) then best = vendor end
	end

	if best then return best, "Recipe" end

	local trainer = ns.db and ns.db.trainerCosts and ns.db.trainerCosts[recipeID]
	trainer = tonumber(trainer)
	if hasValue(trainer) then return trainer, "Training" end

	return nil
end

function ns.GetPathCandidateRecipeIDs()
	if ns.EnsureSmeltingFallback then ns.EnsureSmeltingFallback() end
	local ids = {}
	local recipes = ns.db and ns.db.recipes or {}
	for recipeID, record in pairs(recipes) do
		if type(record) == "table"
			and not record.synthetic
			and record.outputItemID
			and record.reagents
			and #record.reagents > 0 then
			ids[#ids + 1] = recipeID
		end
	end
	table.sort(ids)
	return ids
end

function ns.EvaluateRecipePath(recipeID, ctxBest, ctxBuy)
	local record = ns.GetRecipe(recipeID)
	if not record or not record.outputItemID or record.synthetic then return nil end
	if not record.reagents or #record.reagents == 0 then return nil end

	local econ = ns.GetEconomics(recipeID, ctxBest)
	if not econ or not econ.cost or not econ.costComplete or econ.cost <= 0 then return nil end

	local exits = {}
	local function addExit(kind, profit, value)
		if hasValue(profit) and hasValue(value) then
			exits[#exits + 1] = { kind = kind, profit = profit, value = value }
		end
	end
	addExit(EXIT_AH, econ.net, econ.sale)
	addExit(EXIT_VENDOR, econ.vendorNetFull, econ.vendorSale)

	local deValue = ns.GetDisenchantValue(record.outputItemID)
	if hasValue(deValue) then
		local value = deValue * (econ.outputQty or 1)
		addExit(EXIT_DE, value - econ.cost, value)
	end
	if #exits == 0 then return nil end

	table.sort(exits, function(lhs, rhs) return lhs.profit > rhs.profit end)
	-- Vendor is a second-class exit: prefer AH or disenchant when either is
	-- profitable, and keep vendor as the fallback or an alternative.
	local best = exits[1]
	for index = 1, #exits do
		if exits[index].kind ~= EXIT_VENDOR then
			best = exits[index]
			break
		end
	end

	local buy = ns.GetEconomics(recipeID, ctxBuy)
	local buyCost = buy and buy.costComplete and buy.cost or nil
	local saving = (hasValue(buyCost) and econ.cost < buyCost) and (buyCost - econ.cost) or 0

	local availability, availabilityText = ns.GetPathAvailability(recipeID, record)
	local mine = ns.AccountHasProfession(record.professionID) or #ns.GetRecipeCharacters(recipeID) > 0
	local requiredSkill, requiredName = ns.GetPathRequiredSkill(recipeID, record)
	local sourceLabel = ns.GetPathSourceLabel(recipeID, record)
	local bestCharacter = ns.GetBestProfessionCharacter(record.professionID)
	local unlockCost, unlockLabel = ns.GetPathUnlockCost(recipeID, record)
	local payback
	if unlockCost and best.profit > 0 then
		payback = math.ceil(unlockCost / best.profit)
	end

	return {
		recipeID = recipeID,
		itemID = record.outputItemID,
		name = record.name or ns.GetItemName(record.outputItemID),
		mine = mine,
		professionID = record.professionID,
		requiredSkill = requiredSkill,
		requiredSkillName = requiredName,
		currentSkill = bestCharacter and tonumber(bestCharacter.skill) or nil,
		sourceLabel = sourceLabel,
		professionName = record.professionName,
		outputQty = econ.outputQty,
		cost = econ.cost,
		buyCost = buyCost,
		saving = saving,
		exit = best.kind,
		exitValue = best.value,
		profit = best.profit,
		margin = hasValue(best.value) and (best.profit / best.value) or nil,
		roi = econ.cost > 0 and (best.profit / econ.cost) or nil,
		tier = best.kind == EXIT_VENDOR and 2 or 1,
		availability = availability,
		availabilityText = availabilityText,
		unlockCost = unlockCost,
		unlockLabel = unlockLabel,
		payback = payback,
		alternatives = exits,
	}
end

local function sortValue(row, mode)
	if mode == "margin" then return row.margin or -math.huge end
	if mode == "roi" then return row.roi or -math.huge end
	return row.profit or 0
end

function ns.SortPathRows(rows)
	local mode = ns.paths and ns.paths.sort or "profit"
	table.sort(rows, function(lhs, rhs)
		if lhs.tier ~= rhs.tier then return lhs.tier < rhs.tier end
		local left, right = sortValue(lhs, mode), sortValue(rhs, mode)
		if left ~= right then return left > right end
		return (lhs.profit or 0) > (rhs.profit or 0)
	end)
	return rows
end

function ns.ComputePathSurvey()
	local ids = ns.GetPathCandidateRecipeIDs()
	local ctxBest = ns.BuildAccountContext(true)
	local ctxBuy = ns.BuildAccountContext(false)
	local rows = {}
	for index = 1, #ids do
		local ok, row = pcall(ns.EvaluateRecipePath, ids[index], ctxBest, ctxBuy)
		if ok and row then rows[#rows + 1] = row end
	end
	ns.SortPathRows(rows)
	return rows
end

-- ---------------------------------------------------------------------------
-- Recipe item discovery
-- ---------------------------------------------------------------------------

local RECIPE_ITEM_PREFIXES = {
	"Recipe", "Pattern", "Plans", "Formula", "Schematic", "Design", "Technique",
}

function ns.GetRecipeNameFromItem(itemID)
	local name = ns.GetItemName(itemID)
	if type(name) ~= "string" then return nil end
	for index = 1, #RECIPE_ITEM_PREFIXES do
		local stripped = name:gsub("^" .. RECIPE_ITEM_PREFIXES[index] .. ":%s*", "", 1)
		if stripped ~= name then
			stripped = ns.Trim(stripped)
			if stripped ~= "" then return stripped end
		end
	end
	return nil
end

local function itemSpell(itemID)
	local info = ns.GetItemInfo(itemID)
	local link = info and info.link
	local spellName, spellID

	local function try(call, argument)
		if type(call) ~= "function" then return false end
		local ok, name, id = pcall(call, argument)
		id = tonumber(id)
		if ok and id and id > 0 then
			spellName, spellID = name, id
			return true
		end
		return false
	end

	if _G.C_Item and type(_G.C_Item.GetItemSpell) == "function" then
		try(_G.C_Item.GetItemSpell, itemID)
		if not spellID and link then try(_G.C_Item.GetItemSpell, link) end
		if not spellID and _G.ItemLocation and _G.ItemLocation.CreateFromItemID then
			local location = _G.ItemLocation.CreateFromItemID(itemID)
			if location then try(_G.C_Item.GetItemSpell, location) end
		end
		if not spellID then try(_G.C_Item.GetItemSpell, { itemID = itemID }) end
		if not spellID then
			try(_G.C_Item.GetItemSpell, { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0, itemContext = 0 })
		end
	end
	if not spellID and type(_G.GetItemSpell) == "function" then
		if link then try(_G.GetItemSpell, link) end
		if not spellID then try(_G.GetItemSpell, itemID) end
	end
	return spellName, spellID
end

function ns.GetItemSpellID(itemID)
	if not itemID or itemID <= 0 then return nil end
	local _, spellID = itemSpell(itemID)
	return spellID
end

function ns.GetRecipeSchematicFor(recipeID)
	if not recipeID or not _G.C_TradeSkillUI then return nil end
	local getter = _G.C_TradeSkillUI.GetRecipeSchematic
	if type(getter) ~= "function" then return nil end
	local unpackFn = _G.unpack or (_G.table and _G.table.unpack)
	local arguments = {
		{ recipeID, false },
		{ recipeID },
		{ recipeID, 1 },
	}
	for index = 1, #arguments do
		local ok, schematic = pcall(getter, unpackFn(arguments[index]))
		if ok and type(schematic) == "table"
			and (schematic.outputItemID or schematic.reagentSlotSchematics) then
			return schematic
		end
	end
	return nil
end

-- Build a recipe record straight from a recipe item. This deliberately does
-- not depend on the profession window ever being opened.
function ns.ResolveItemRecipe(itemID)
	if not itemID or itemID <= 0 then return nil end
	local spellID = ns.GetItemSpellID(itemID)
	if not spellID then
		if ns.BuyLog then ns.BuyLog("resolve item=%s no spell", tostring(itemID)) end
		return nil
	end

	local record = ns.db and ns.db.recipes and ns.db.recipes[spellID]
	if record and record.outputItemID and record.reagents and #record.reagents > 0 then
		return record, spellID
	end

	local candidates = { spellID }
	if _G.C_TradeSkillUI and type(_G.C_TradeSkillUI.GetRecipeInfo) == "function" then
		local ok, info = pcall(_G.C_TradeSkillUI.GetRecipeInfo, spellID)
		if ok and type(info) == "table" and tonumber(info.recipeID) and tonumber(info.recipeID) > 0
			and tonumber(info.recipeID) ~= spellID then
			candidates[#candidates + 1] = tonumber(info.recipeID)
		end
	end

	for index = 1, #candidates do
		local recipeID = candidates[index]
		local schematic = ns.GetRecipeSchematicFor(recipeID)
		if schematic then
			local professionID, professionName
			if _G.C_TradeSkillUI and type(_G.C_TradeSkillUI.GetProfessionInfoByRecipeID) == "function" then
				local ok, info = pcall(_G.C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID)
				if ok and type(info) == "table" then
					professionID = info.professionID
					professionName = info.professionName
				end
			end
			local built = ns.BuildRecipeRecord(recipeID, nil, schematic, professionID, professionName)
			ns.db.recipes[recipeID] = built
			ns.AddRecipeToIndex(built)
			if ns.MarkPathSurveyDirty then ns.MarkPathSurveyDirty() end
			if ns.BuyLog then
				ns.BuyLog("resolve item=%s recipe=%s reagents=%d", tostring(itemID), tostring(recipeID), #built.reagents)
			end
			return built, recipeID
		end
	end

	if ns.BuyLog then ns.BuyLog("resolve item=%s recipe=%s no schematic", tostring(itemID), tostring(spellID)) end
	return nil
end

-- Cost with every reagent bought on the Auction House: no vendor fallback and
-- no intermediate crafts.
function ns.GetAHCraftCost(recipeID, record)
	if not recipeID and record then recipeID = record.id end
	if not recipeID or not ns.db then return nil end
	local settings = {}
	for key, value in pairs(ns.db.settings or {}) do settings[key] = value end
	settings.craftReagents = false
	local ctx = ns.NewCostContext({
		price = ns.GetPrice,
		vendor = function() return nil end,
		vendorSell = ns.GetVendorSellPrice,
		recipes = ns.db.recipes,
		byOutput = ns.byOutput,
		known = function() return false end,
		settings = settings,
		maxDepth = 1,
	})
	return ns.GetCraftCost(recipeID, ctx)
end

function ns.GetRecipeSpellForItem(itemID)
	if not itemID or itemID <= 0 then return nil end

	local spellName, spellID = itemSpell(itemID)
	if not spellID or spellID <= 0 then return nil end

	local professionInfo
	if _G.C_TradeSkillUI and type(_G.C_TradeSkillUI.GetProfessionInfoByRecipeID) == "function" then
		local infoOk, info = pcall(_G.C_TradeSkillUI.GetProfessionInfoByRecipeID, spellID)
		if infoOk and type(info) == "table" and (info.professionID or info.professionName) then
			professionInfo = info
		end
	end

	local schematic
	if _G.C_TradeSkillUI and type(_G.C_TradeSkillUI.GetRecipeSchematic) == "function" then
		local schemaOk, value = pcall(_G.C_TradeSkillUI.GetRecipeSchematic, spellID, false)
		if schemaOk and type(value) == "table" and (value.outputItemID or value.reagentSlotSchematics) then
			schematic = value
		end
	end

	if not professionInfo and not schematic then return nil end
	return spellID, professionInfo, schematic, spellName
end

function ns.GetRecipeIDForRecipeItem(itemID)
	if not itemID or itemID <= 0 then return nil end
	ns.recipeItemLookup = ns.recipeItemLookup or {}
	local cached = ns.recipeItemLookup[itemID]
	if cached ~= nil then return cached or nil end

	local classID = ns.GetItemClassID(itemID)
	if classID and classID ~= RECIPE_CLASS_ID then
		-- Fall back to the usual recipe item name prefixes for clients that
		-- report an unexpected class. Localized names still pass the spell
		-- check below when the class is correct.
		local name = ns.GetItemName(itemID)
		local looksLikeRecipe = type(name) == "string" and (
			name:find("^Recipe:") or name:find("^Plans:") or name:find("^Pattern:")
			or name:find("^Formula:") or name:find("^Schematic:") or name:find("^Design:")
			or name:find("^Technique:")
		)
		if not looksLikeRecipe then
			ns.recipeItemLookup[itemID] = false
			return nil
		end
	end

	-- The class can be nil while a bag/vendor item is still loading. The spell
	-- lookup is cheap, so try it rather than giving up on the tooltip.
	local recipeID = ns.GetRecipeSpellForItem(itemID)
	if ns.BuyLog and ns.IsBuyLogEnabled and ns.IsBuyLogEnabled() then
		ns.BuyLog("recipe item lookup item=%s class=%s spell=%s name=%s",
			tostring(itemID), tostring(classID), tostring(recipeID), tostring(ns.GetRecipeNameFromItem(itemID)))
	end
	if recipeID and not (ns.db and ns.db.recipes and ns.db.recipes[recipeID]) then
		local name = ns.GetRecipeNameFromItem(itemID)
		local byName = name and ns.FindTrainerRecipe and ns.FindTrainerRecipe(nil, name)
		if byName then recipeID = byName end
	end
	if not recipeID then
		local name = ns.GetRecipeNameFromItem(itemID)
		if name and ns.FindTrainerRecipe then
			recipeID = ns.FindTrainerRecipe(nil, name)
		end
	end
	if not recipeID and not classID then return nil end
	ns.recipeItemLookup[itemID] = recipeID or false
	return recipeID or nil
end

function ns.LearnRecipeItem(itemID, minPrice)
	if not itemID or itemID <= 0 then return false end
	local spellID, professionInfo, schematic, spellName = ns.GetRecipeSpellForItem(itemID)
	if not spellID then return false end

	local existing = ns.db.recipeItems[spellID] or {}
	local price = tonumber(minPrice)
	if not hasValue(price) then
		price = ns.GetPrice(itemID) or existing.price
	end

	local info = ns.GetItemInfo(itemID)
	ns.db.recipeItems[spellID] = {
		itemID = itemID,
		name = existing.name or (info and info.name) or spellName or ("item:" .. tostring(itemID)),
		price = price or existing.price,
		vendorPrice = ns.GetVendorBuyPrice(itemID) or existing.vendorPrice,
		seenAt = time(),
	}

	local record = ns.db.recipes[spellID]
	if not record and schematic then
		record = ns.BuildRecipeRecord(
			spellID,
			nil,
			schematic,
			professionInfo and professionInfo.professionID,
			professionInfo and professionInfo.professionName
		)
		ns.db.recipes[spellID] = record
		ns.AddRecipeToIndex(record)
	end
	if record then
		record.recipeItemID = itemID
		record.requiredSkillMissingAt = nil
	end
	ns.recipeItemLookup = ns.recipeItemLookup or {}
	ns.recipeItemLookup[itemID] = spellID
	return true
end

local function browseApi()
	local api = _G.C_AuctionHouse
	if api and type(api.SendBrowseQuery) == "function" and type(api.GetBrowseResults) == "function" then
		return api
	end
	return nil
end

function ns.StartRecipeItemScan()
	local api = browseApi()
	if not api then
		ns.SetPathsStatus("Auction House browse API unavailable.", 8)
		return
	end
	if not _G.AuctionHouseFrame or not _G.AuctionHouseFrame:IsShown() then
		ns.SetPathsStatus("Open the Auction House to scan recipe items.", 8)
		return
	end

	ns.paths.scanToken = (ns.paths.scanToken or 0) + 1
	local token = ns.paths.scanToken
	ns.paths.scan = {
		token = token,
		seen = {},
		requests = 0,
		found = 0,
		processed = 0,
		filtered = true,
	}

	local query = {
		searchString = "",
		filters = {},
		itemClassFilters = { { classID = RECIPE_CLASS_ID } },
		sorts = SORT_PRICE,
	}
	local ok = pcall(api.SendBrowseQuery, query)
	if not ok then
		query.itemClassFilters = {}
		ok = pcall(api.SendBrowseQuery, query)
	end
	if not ok then
		ns.paths.scan = nil
		ns.SetPathsStatus("Recipe item scan failed.", 8)
		return
	end

	ns.SetPathsStatus("Scanning recipe items...", 0)
	ns.After(1, function() ns.ProcessRecipeItemScan(token) end)
end

function ns.ProcessRecipeItemScan(token)
	local scan = ns.paths.scan
	if not scan or scan.token ~= token then return end

	local api = browseApi()
	if not api then
		ns.paths.scan = nil
		return
	end

	local ok, results = pcall(api.GetBrowseResults)
	if not ok or type(results) ~= "table" then results = {} end

	-- The browse summary can need a moment. If the class-filtered query comes
	-- back empty, retry once with the full summary and filter in Lua.
	if #results == 0 and (scan.emptyTries or 0) < 3 then
		scan.emptyTries = (scan.emptyTries or 0) + 1
		if scan.filtered then
			scan.filtered = false
			pcall(api.SendBrowseQuery, { searchString = "", filters = {}, itemClassFilters = {}, sorts = SORT_PRICE })
		end
		ns.After(1, function() ns.ProcessRecipeItemScan(token) end)
		return
	end

	local budget = 0
	for index = 1, #results do
		local result = results[index]
		local itemKey = result.itemKey
		local itemID = itemKey and tonumber(itemKey.itemID)
		if itemID and itemID > 0 and not scan.seen[itemID] then
			scan.seen[itemID] = true
			scan.processed = scan.processed + 1
			budget = budget + 1
			if budget >= 400 then break end

			local classID = ns.GetItemClassID(itemID)
			if classID == nil or classID == RECIPE_CLASS_ID then
				local minPrice = tonumber(result.minPrice)
				if ns.LearnRecipeItem(itemID, minPrice) then
					scan.found = scan.found + 1
				end
			end
		end
	end

	ns.SetPathsStatus(string.format("Scanning recipe items... %d checked, %d found", scan.processed, scan.found), 0)

	local full = true
	if type(api.HasFullBrowseResults) == "function" then
		local fullOk, value = pcall(api.HasFullBrowseResults)
		if fullOk then full = value == true end
	end

	if not full and scan.requests < 20 then
		scan.requests = scan.requests + 1
		if type(api.RequestMoreBrowseResults) == "function" then
			pcall(api.RequestMoreBrowseResults)
		end
		ns.After(0.7, function() ns.ProcessRecipeItemScan(token) end)
		return
	end

	ns.paths.scan = nil
	ns.db.meta.lastRecipeScan = time()
	ns.RebuildRecipeIndex()
	ns.InvalidateAccountKnown()
	if ns.MarkPathSurveyDirty then ns.MarkPathSurveyDirty() end
	ns.SetPathsStatus(string.format("Recipe items found: %d.", scan.found), 10)
	ns.RefreshPathsFrame()
end

function ns.ScanOwnedRecipeItems()
	local now = time()
	if ns.paths.bagScanAt and (now - ns.paths.bagScanAt) < 60 then return end
	ns.paths.bagScanAt = now

	local numSlots = _G.C_Container and _G.C_Container.GetContainerNumSlots or _G.GetContainerNumSlots
	local getItem = _G.C_Container and _G.C_Container.GetContainerItemID or _G.GetContainerItemID
	if type(numSlots) ~= "function" or type(getItem) ~= "function" then return end

	local found = 0
	local lastBag = _G.NUM_BAG_SLOTS or 4
	for bag = 0, lastBag do
		local slotsOk, slots = pcall(numSlots, bag)
		slots = tonumber(slots)
		if slotsOk and slots and slots > 0 then
			for slot = 1, slots do
				local itemOk, itemID = pcall(getItem, bag, slot)
				itemID = tonumber(itemID)
				if itemOk and itemID and itemID > 0 and ns.GetItemClassID(itemID) == RECIPE_CLASS_ID then
					if ns.LearnRecipeItem(itemID, nil) then
						found = found + 1
					end
				end
			end
		end
	end

	if found > 0 then
		ns.RebuildRecipeIndex()
		if ns.MarkPathSurveyDirty then ns.MarkPathSurveyDirty() end
	end
end

-- ---------------------------------------------------------------------------
-- Survey state
-- ---------------------------------------------------------------------------

function ns.MarkPathSurveyDirty()
	ns.paths = ns.paths or {}
	ns.paths.dirty = true
end

function ns.InvalidatePathSurvey()
	ns.paths = ns.paths or {}
	ns.paths.dirty = true
	ns.paths.survey = nil
	ns.paths.rows = nil
end

function ns.GetPathTabCounts()
	local mine, all = 0, 0
	local rows = ns.paths and ns.paths.rows or {}
	for index = 1, #rows do
		all = all + 1
		if rows[index].mine == true then mine = mine + 1 end
	end
	return mine, all
end

function ns.GetPathRows()
	if not ns.paths then return {} end
	local rows = ns.paths.rows or {}
	local availability = ns.paths.availability or "all"
	local includeVendor = ns.paths.exitMode == "all"
	local tab = ns.paths.tab or "mine"
	local list = {}
	for index = 1, #rows do
		local row = rows[index]
		local keep = true
		if tab == "mine" and row.mine ~= true then keep = false end
		if availability ~= "all" and row.availability ~= availability then keep = false end
		if not includeVendor and row.exit == EXIT_VENDOR then keep = false end
		if keep then list[#list + 1] = row end
	end
	ns.SortPathRows(list)
	return list
end

function ns.SetPathsStatus(text, seconds)
	if not ns.paths then ns.paths = {} end
	ns.paths.status = text
	ns.paths.statusUntil = seconds and seconds > 0 and (time() + seconds) or nil
	ns.UpdatePathsHeader()
end

function ns.GetPathsStatus()
	if not ns.paths or not ns.paths.status then return nil end
	if ns.paths.statusUntil and time() > ns.paths.statusUntil then
		ns.paths.status = nil
		ns.paths.statusUntil = nil
		return nil
	end
	return ns.paths.status
end

function ns.StartPathSurvey()
	local ids = ns.GetPathCandidateRecipeIDs()
	ns.paths.token = (ns.paths.token or 0) + 1
	ns.paths.survey = {
		token = ns.paths.token,
		ids = ids,
		index = 1,
		total = #ids,
		rows = {},
		ctxBest = ns.BuildAccountContext(true),
		ctxBuy = ns.BuildAccountContext(false),
	}
	ns.paths.dirty = false
	ns.UpdatePathsHeader()
	ns.RunPathSurveyStep(ns.paths.token)
end

function ns.RunPathSurveyStep(token)
	local survey = ns.paths and ns.paths.survey
	if not survey or survey.token ~= token then return end

	local budget = 0
	while survey.index <= survey.total and budget < SURVEY_BATCH do
		local recipeID = survey.ids[survey.index]
		survey.index = survey.index + 1
		budget = budget + 1

		local ok, row = pcall(ns.EvaluateRecipePath, recipeID, survey.ctxBest, survey.ctxBuy)
		if ok and row then survey.rows[#survey.rows + 1] = row end
	end

	if survey.index <= survey.total then
		ns.UpdatePathsHeader()
		ns.After(0, function() ns.RunPathSurveyStep(token) end)
		return
	end

	ns.paths.survey = nil
	ns.SortPathRows(survey.rows)
	ns.paths.rows = survey.rows
	ns.paths.dirty = false
	ns.paths.lastSurveyAt = time()
	log("paths survey recipes=%d profitable=%d", #survey.ids, #survey.rows)
	ns.RefreshPathsFrame()
end

-- ---------------------------------------------------------------------------
-- UI helpers
-- ---------------------------------------------------------------------------

local function profitColor(value)
	if not value then return 0.7, 0.7, 0.7 end
	if value > 0 then return 0.25, 1, 0.45 end
	if value < 0 then return 1, 0.35, 0.35 end
	return 0.7, 0.7, 0.7
end

local function availabilityLabel(row)
	if row.availability == "ready" then
		return "Known", 0.25, 1, 0.45
	elseif row.availability == "obtain" then
		if row.unlockCost and row.payback then
			return string.format("%s %s · %d craft%s",
				row.unlockLabel or "Recipe",
				ns.FormatMoney(row.unlockCost),
				row.payback,
				row.payback == 1 and "" or "s"), 0.4, 0.8, 1
		end
		return "Not learned", 0.4, 0.8, 1
	elseif row.availability == "skill" then
		return "Skill gap", 1, 0.65, 0.2
	end
	return "No profession", 0.65, 0.65, 0.65
end

local function exitColor(exit)
	local color = EXIT_TEXTURES[exit]
	if color then return color[1], color[2], color[3] end
	return 0.8, 0.8, 0.8
end

local function createPathRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:EnableMouse(true)
	row:RegisterForClicks("LeftButtonUp")

	local background = row:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(1, 1, 1, 0.03)
	row.background = background

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.08)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(18, 18)
	row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -6)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 32, -6)
	row.name:SetWidth(250)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)

	row.exit = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.exit:SetPoint("TOPLEFT", row, "TOPLEFT", 290, -7)
	row.exit:SetWidth(54)
	row.exit:SetJustifyH("LEFT")

	row.state = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.state:SetPoint("TOPLEFT", row, "TOPLEFT", 344, -7)
	row.state:SetWidth(210)
	row.state:SetJustifyH("LEFT")

	row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.profit:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -6)
	row.profit:SetWidth(120)
	row.profit:SetJustifyH("RIGHT")

	row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.detail:SetPoint("TOPLEFT", row, "TOPLEFT", 32, -25)
	row.detail:SetWidth(540)
	row.detail:SetJustifyH("LEFT")
	row.detail:SetWordWrap(false)
	row.detail:SetTextColor(0.7, 0.7, 0.7)

	row.margin = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	row.margin:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, 8)
	row.margin:SetWidth(120)
	row.margin:SetJustifyH("RIGHT")
	row.margin:SetTextColor(0.7, 0.7, 0.7)

	row:SetScript("OnClick", safeClick(function(self)
		if self.data then ns.SelectPathRow(self.data) end
	end))

	return row
end

local function updatePathRow(row, data)
	local info = ns.GetItemInfo(data.itemID)
	row.icon:SetTexture(info and info.texture or nil)
	row.name:SetText(data.name)
	row.exit:SetText(EXIT_LABELS[data.exit] or data.exit)
	row.exit:SetTextColor(exitColor(data.exit))

	local label, r, g, b = availabilityLabel(data)
	row.state:SetText(label)
	row.state:SetTextColor(r, g, b)

	local pr, pg, pb = profitColor(data.profit)
	row.profit:SetText(ns.FormatMoney(data.profit, true))
	row.profit:SetTextColor(pr, pg, pb)
	row.margin:SetText(string.format("%s  ·  %s", ns.FormatPercent(data.margin, true), ns.FormatMoney(data.cost)))

	local parts = { tostring(data.professionName or "?") }
	if data.sourceLabel then parts[#parts + 1] = data.sourceLabel end
	if data.requiredSkill then
		if data.currentSkill then
			parts[#parts + 1] = string.format("req %d (you %d)", data.requiredSkill, data.currentSkill)
		else
			parts[#parts + 1] = string.format("req %d", data.requiredSkill)
		end
	end
	if data.saving and data.saving > 0 then
		parts[#parts + 1] = "chain saves " .. ns.FormatMoney(data.saving)
	else
		parts[#parts + 1] = "buy materials"
	end
	if data.availabilityText and data.availabilityText ~= "" and data.availability ~= "ready" then
		parts[#parts + 1] = data.availabilityText
	end
	row.detail:SetText(table.concat(parts, " · "))

	if ns.paths.selected and ns.paths.selected.recipeID == data.recipeID then
		row.background:SetColorTexture(0.2, 0.8, 0.5, 0.14)
	else
		row.background:SetColorTexture(1, 1, 1, 0.03)
	end
end

local function appendPathLines(lines, path, depth, quantity, scale)
	if not path then return end
	scale = scale or 1

	if depth > 0 and quantity and path.outputQty and path.outputQty > 0 then
		-- Quantity needed by the parent divided by what one craft produces.
		scale = scale * (quantity / path.outputQty)
	end

	local indent = string.rep("  ", depth)
	local text = indent
	if depth == 0 then
		text = text .. "|cffffd200" .. tostring(path.name or "?") .. "|r"
	else
		text = text .. tostring(path.name or "?")
		if quantity and quantity > 1 then
			text = text .. " ×" .. tostring(quantity)
		end
	end
	if path.professionName then
		text = text .. "  " .. tostring(path.professionName) .. " · craft"
	end
	if path.characters and #path.characters > 0 then
		local names = {}
		for index = 1, #path.characters do
			names[#names + 1] = ns.GetCharacterName(path.characters[index])
		end
		text = text .. "  (" .. table.concat(names, ", ") .. ")"
	end
	if path.cost then
		text = text .. "  " .. ns.FormatMoney(path.cost * scale)
	end
	lines[#lines + 1] = text

	local reagents = path.reagents or {}
	for index = 1, #reagents do
		local line = reagents[index]
		if line.path then
			appendPathLines(lines, line.path, depth + 1, line.qty, scale)
		else
			local itemName = ns.GetItemName(line.itemID)
			local source = SOURCE_LABELS[line.source] or tostring(line.source or "?")
			local lineText = string.rep("  ", depth + 1)
				.. itemName
				.. " ×" .. tostring(line.qty)
				.. "  " .. source
			if line.line then
				lineText = lineText .. "  " .. ns.FormatMoney(line.line * scale)
			end
			lines[#lines + 1] = lineText
		end
	end
end

function ns.RefreshPathDetails()
	local frame = ns.pathsFrame
	if not frame or not ns.pathsDetailText then return end
	local data = ns.paths and ns.paths.selected
	if not data then
		ns.pathsDetailText:SetText("Select a path to see its crafting steps.")
		return
	end

	local lines = {}
	lines[#lines + 1] = string.format("|cffffd200%s|r  %s · profit %s · margin %s",
		data.name,
		EXIT_LABELS[data.exit] or data.exit,
		ns.FormatMoney(data.profit, true),
		ns.FormatPercent(data.margin, true))
	lines[#lines + 1] = string.format("Cost %s · buy materials %s · %s",
		ns.FormatMoney(data.cost),
		data.buyCost and ns.FormatMoney(data.buyCost) or "?",
		(data.saving or 0) > 0 and ("chain saves " .. ns.FormatMoney(data.saving)) or "no cheaper chain")
	local requirementBits = {}
	if data.sourceLabel then requirementBits[#requirementBits + 1] = "Source: " .. data.sourceLabel end
	if data.requiredSkill then
		requirementBits[#requirementBits + 1] = string.format("Requires %s %d",
			tostring(data.requiredSkillName or data.professionName or "skill"), data.requiredSkill)
		if data.currentSkill then
			requirementBits[#requirementBits + 1] = string.format("you %d", data.currentSkill)
		end
	end
	if not data.requiredSkill and data.availability ~= "ready" then
		requirementBits[#requirementBits + 1] = "level not captured yet (open the trainer once)"
	end
	if #requirementBits > 0 then
		lines[#lines + 1] = table.concat(requirementBits, " · ")
	end
	if data.unlockCost then
		local payback = data.payback and string.format(" · pays back in %d craft%s", data.payback, data.payback == 1 and "" or "s") or ""
		lines[#lines + 1] = string.format("Unlock: %s %s%s", data.unlockLabel or "Recipe", ns.FormatMoney(data.unlockCost), payback)
	end
	if data.availability and data.availability ~= "ready" then
		lines[#lines + 1] = string.format("Status: %s · %s", data.availability, data.availabilityText or "")
	end
	local alternatives = {}
	for index = 1, #(data.alternatives or {}) do
		local alternative = data.alternatives[index]
		if alternative.kind ~= data.exit then
			alternatives[#alternatives + 1] = string.format("%s %s",
				EXIT_LABELS[alternative.kind] or alternative.kind,
				ns.FormatMoney(alternative.profit, true))
		end
	end
	if #alternatives > 0 then
		lines[#lines + 1] = "Other exits: " .. table.concat(alternatives, " · ")
	end
	lines[#lines + 1] = ""

	local ctx = ns.BuildAccountContext(true)
	local path = ns.BuildCraftPath(data.recipeID, ctx)
	if path then
		appendPathLines(lines, path, 0)
	else
		lines[#lines + 1] = "Craft path unavailable (missing recipe data)."
	end

	local characters = ns.GetRecipeCharacters(data.recipeID)
	if #characters > 0 then
		local names = {}
		for index = 1, #characters do
			names[#names + 1] = ns.GetCharacterName(characters[index])
		end
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Known by: " .. table.concat(names, ", ")
	end

	if #lines > 17 then
		for index = #lines, 18, -1 do lines[index] = nil end
		lines[#lines + 1] = "…"
	end
	ns.pathsDetailText:SetText(table.concat(lines, "\n"))
end

function ns.UpdatePathsHeader()
	local frame = ns.pathsFrame
	if not frame or not ns.pathsStatus then return end
	local status = ns.GetPathsStatus()
	if status then
		ns.pathsStatus:SetText(status)
		return
	end

	local stats = ns.GetCatalogStats()
	local survey = ns.paths and ns.paths.survey
	if survey then
		ns.pathsStatus:SetText(string.format("Surveying %d / %d recipes...", math.max(0, survey.index - 1), survey.total))
		return
	end
	if stats.recipes == 0 then
		ns.pathsStatus:SetText("No recipes captured yet. Open each profession once on each character, then come back.")
		return
	end
	if ns.paths and ns.paths.rows and #ns.paths.rows == 0 then
		ns.pathsStatus:SetText("No profitable paths found. Check that Auctionator has scanned prices, then press Refresh.")
		return
	end

	if ns.paths and ns.paths.visibleRows and #ns.paths.visibleRows == 0 then
		ns.pathsStatus:SetText("No paths in this view. Try another tab or the availability filter.")
		return
	end

	local scanText = "recipe scan never"
	if ns.db and ns.db.meta and ns.db.meta.lastRecipeScan then
		scanText = "recipe scan " .. (ns.FormatAge(time() - ns.db.meta.lastRecipeScan) or "unknown")
	end
	local tabName = ns.paths and ns.paths.tab == "global" and "All professions" or "My recipes"
	local shown = ns.paths and ns.paths.visibleRows and #ns.paths.visibleRows or 0
	local hint = ""
	local mineCount, allCount = ns.GetPathTabCounts()
	if ns.paths and ns.paths.tab == "global" and allCount == mineCount then
		hint = " · no recipes outside your professions yet; scan recipe items in the AH"
	end
	ns.pathsStatus:SetText(string.format("%s · %d shown · %d characters · %d professions · %d recipes · %d recipe items · %s%s",
		tabName, shown, stats.characters, stats.professions, stats.recipes, stats.recipeItems, scanText, hint))
end

function ns.RenderPathRows(offset)
	local frame = ns.pathsFrame
	if not frame or not ns.pathsScroll or not ns.pathsContent then return end

	local scrollWidth = ns.pathsScroll:GetWidth()
	if not scrollWidth or scrollWidth <= 100 then
		scrollWidth = (frame:GetWidth() or 780) - 48
	end
	ns.pathsContent:SetWidth(math.max(1, scrollWidth - 26))

	local rows = ns.paths.visibleRows or {}
	ns.pathsContent:SetHeight(math.max(#rows * ROW_HEIGHT, 1))

	offset = tonumber(offset) or tonumber(ns.pathsScroll:GetVerticalScroll()) or 0
	local first = math.floor(offset / ROW_HEIGHT) + 1
	if first < 1 then first = 1 end

	local pool = ns.paths.rowPool or {}
	ns.paths.rowPool = pool

	for slot = 1, VISIBLE_ROWS do
		local index = first + slot - 1
		local data = rows[index]
		local row = pool[slot]
		if not row then
			row = createPathRow(ns.pathsContent)
			pool[slot] = row
		end
		if data then
			row.data = data
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", ns.pathsContent, "TOPLEFT", 0, -((index - 1) * ROW_HEIGHT))
			row:SetPoint("TOPRIGHT", ns.pathsContent, "TOPRIGHT", 0, -((index - 1) * ROW_HEIGHT))
			row:Show()
			updatePathRow(row, data)
		else
			row:Hide()
		end
	end
end

function ns.SelectPathRow(data)
	ns.paths.selected = data
	ns.RefreshPathDetails()
	ns.RenderPathRows()
end

local function cycleButton(parent, x, width, text, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -100)
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	return button
end

local function styleTab(button, selected)
	if not button then return end
	if button.selectedGlow then
		button.selectedGlow:SetShown(selected)
	end
	local font
	if type(button.GetFontString) == "function" then font = button:GetFontString() end
	if font then
		if selected then
			font:SetTextColor(0.25, 1, 0.55)
		else
			font:SetTextColor(0.85, 0.85, 0.85)
		end
	end
	button:SetAlpha(selected and 1 or 0.7)
end

function ns.RefreshPathsButtons()
	local paths = ns.paths or {}
	local tab = paths.tab or "mine"
	styleTab(ns.pathsTabMine, tab == "mine")
	styleTab(ns.pathsTabGlobal, tab == "global")
	local mineCount, allCount = ns.GetPathTabCounts()
	if ns.pathsTabMine then
		ns.pathsTabMine:SetText(string.format("My recipes (%d)", mineCount))
	end
	if ns.pathsTabGlobal then
		ns.pathsTabGlobal:SetText(string.format("All professions (%d)", allCount))
	end
	local availability = paths.availability or "all"
	local labels = {
		all = "Availability: All",
		ready = "Availability: Known",
		obtain = "Availability: Not learned",
		skill = "Availability: Skill gap",
	}
	if ns.pathsAvailabilityButton then
		ns.pathsAvailabilityButton:SetText(labels[availability] or labels.all)
	end
	if ns.pathsExitButton then
		ns.pathsExitButton:SetText(paths.exitMode == "ahde" and "Exit: AH + DE" or "Exit: All")
	end
	local sortLabels = { profit = "Sort: Profit", margin = "Sort: Margin", roi = "Sort: ROI" }
	if ns.pathsSortButton then
		ns.pathsSortButton:SetText(sortLabels[paths.sort or "profit"] or sortLabels.profit)
	end
end

function ns.CreatePathsFrame()
	if ns.pathsFrame then return ns.pathsFrame end

	ns.paths = ns.paths or {}
	ns.paths.rowPool = {}
	ns.paths.availability = ns.paths.availability or "all"
	ns.paths.exitMode = ns.paths.exitMode or "all"
	ns.paths.sort = ns.paths.sort or "profit"
	ns.paths.tab = ns.paths.tab or "mine"

	local frame = CreateFrame("Frame", "OpenMarginPathsFrame", _G.UIParent, "InsetFrameTemplate")
	frame:SetSize(780, 640)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(200)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:Hide()
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	ns.pathsFrame = frame
	local background = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	background:SetAllPoints()
	background:SetColorTexture(0.06, 0.06, 0.06, 0.96)
	if _G.UISpecialFrames then
		table.insert(_G.UISpecialFrames, "OpenMarginPathsFrame")
	end

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -12)
	title:SetText("Crafting Paths")
	ns.pathsTitle = title

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

	ns.pathsTabMine = nil
	ns.pathsTabGlobal = nil

	local status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -70)
	status:SetWidth(740)
	status:SetJustifyH("LEFT")
	status:SetTextColor(0.75, 0.75, 0.75)
	ns.pathsStatus = status

	local function setPathTab(tab)
		ns.paths.tab = tab
		ns.paths.visibleRows = ns.GetPathRows()
		if ns.pathsScroll then ns.pathsScroll:SetVerticalScroll(0) end
		ns.RefreshPathsButtons()
		ns.UpdatePathsHeader()
		ns.RenderPathRows(0)
		local mineCount, allCount = ns.GetPathTabCounts()
		log("paths tab=%s mine=%d all=%d", tostring(tab), mineCount, allCount)
		if tab == "global" and allCount == mineCount and ns.Print then
			ns.Print("Crafting Paths: no recipes outside your professions yet. Open the Auction House and click Scan recipe items.")
		end
	end

	local function tabButton(x, width, text, tab)
		local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		button:SetSize(width, 22)
		button:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -40)
		button:SetText(text)
		button.tab = tab
		local glow = button:CreateTexture(nil, "BACKGROUND")
		glow:SetAllPoints()
		glow:SetColorTexture(0.2, 0.8, 0.5, 0.22)
		glow:Hide()
		button.selectedGlow = glow
		button:SetScript("OnClick", safeClick(function() setPathTab(tab) end))
		return button
	end

	ns.pathsTabMine = tabButton(16, 120, "My recipes", "mine")
	ns.pathsTabGlobal = tabButton(142, 150, "All professions", "global")

	ns.pathsAvailabilityButton = cycleButton(frame, 16, 170, "Availability: All", safeClick(function()
		local order = { "all", "ready", "obtain", "skill" }
		local current = ns.paths.availability or "all"
		local nextIndex = 1
		for index = 1, #order do
			if order[index] == current then
				nextIndex = index % #order + 1
				break
			end
		end
		ns.paths.availability = order[nextIndex]
		ns.RefreshPathsButtons()
		ns.paths.visibleRows = ns.GetPathRows()
		if ns.pathsScroll then ns.pathsScroll:SetVerticalScroll(0) end
		ns.RenderPathRows(0)
	end))

	ns.pathsExitButton = cycleButton(frame, 192, 120, "Exit: AH + DE", safeClick(function()
		ns.paths.exitMode = ns.paths.exitMode == "ahde" and "all" or "ahde"
		ns.RefreshPathsButtons()
		ns.paths.visibleRows = ns.GetPathRows()
		if ns.pathsScroll then ns.pathsScroll:SetVerticalScroll(0) end
		ns.RenderPathRows(0)
	end))

	ns.pathsSortButton = cycleButton(frame, 318, 110, "Sort: Profit", safeClick(function()
		local order = { "profit", "margin", "roi" }
		local current = ns.paths.sort or "profit"
		local nextIndex = 1
		for index = 1, #order do
			if order[index] == current then
				nextIndex = index % #order + 1
				break
			end
		end
		ns.paths.sort = order[nextIndex]
		ns.RefreshPathsButtons()
		ns.paths.visibleRows = ns.GetPathRows()
		if ns.pathsScroll then ns.pathsScroll:SetVerticalScroll(0) end
		ns.RenderPathRows(0)
	end))

	local scan = cycleButton(frame, 434, 130, "Scan recipe items", safeClick(function()
		ns.StartRecipeItemScan()
	end))
	ns.pathsScanButton = scan

	local refresh = cycleButton(frame, 570, 80, "Refresh", safeClick(function()
		if ns.InvalidatePathSurvey then ns.InvalidatePathSurvey() end
		ns.RefreshPathsFrame()
	end))
	ns.pathsRefreshButton = refresh

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -128)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 190)
	scroll:SetScript("OnVerticalScroll", function(_, offset)
		ns.RenderPathRows(offset)
	end)
	ns.pathsScroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)
	ns.pathsContent = content
	scroll:SetScript("OnSizeChanged", function(self, width)
		width = width or self:GetWidth()
		if width and width > 100 then
			content:SetWidth(math.max(1, width - 26))
			ns.RenderPathRows()
		end
	end)

	local detail = CreateFrame("Frame", nil, frame)
	detail:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -6)
	detail:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
	local detailBackground = detail:CreateTexture(nil, "BACKGROUND")
	detailBackground:SetAllPoints()
	detailBackground:SetColorTexture(0, 0, 0, 0.25)
	ns.pathsDetail = detail

	local detailText = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	detailText:SetPoint("TOPLEFT", detail, "TOPLEFT", 10, -8)
	detailText:SetPoint("TOPRIGHT", detail, "TOPRIGHT", -10, -8)
	detailText:SetJustifyH("LEFT")
	detailText:SetText("Select a path to see its crafting steps.")
	ns.pathsDetailText = detailText

	frame:SetScript("OnShow", function()
		ns.ScanOwnedRecipeItems()
		ns.RefreshPathsButtons()
		ns.RefreshPathsFrame()
	end)
	frame:SetScript("OnHide", function()
		ns.paths.selected = nil
	end)

	ns.RefreshPathsButtons()
	return frame
end

function ns.RefreshPathsFrame()
	local frame = ns.pathsFrame
	if not frame or not frame:IsShown() then return end

	ns.UpdatePathsHeader()
	ns.RefreshPathsButtons()

	if ns.paths.survey then
		return
	end
	if ns.paths.dirty or not ns.paths.rows then
		ns.StartPathSurvey()
		return
	end

	ns.paths.visibleRows = ns.GetPathRows()
	ns.UpdatePathsHeader()
	ns.RenderPathRows(ns.pathsScroll and ns.pathsScroll:GetVerticalScroll() or 0)
	ns.RefreshPathDetails()
end

function ns.OpenPaths()
	local frame = ns.CreatePathsFrame()
	if not frame then return end
	frame:Show()
	frame:Raise()
end
