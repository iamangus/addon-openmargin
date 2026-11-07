local addonName, ns = ...

local function call(method, ...)
	if type(method) ~= "function" then return nil end
	local ok, value = pcall(method, ...)
	if ok then return value end
	return nil
end

function ns.After(delay, fn)
	if _G.C_Timer and type(_G.C_Timer.After) == "function" then
		_G.C_Timer.After(delay, fn)
	else
		fn()
	end
end

function ns.GetCurrentProfessionInfo()
	local page = _G.ProfessionsFrame and _G.ProfessionsFrame.CraftingPage
	if page and page.professionInfo then
		return page.professionInfo
	end
	if _G.C_TradeSkillUI then
		local info = call(_G.C_TradeSkillUI.GetChildProfessionInfo)
		if info and info.professionID and info.professionID > 0 then
			return info
		end
		info = call(_G.C_TradeSkillUI.GetBaseProfessionInfo)
		if info and info.professionID and info.professionID > 0 then
			return info
		end
	end
	return nil
end

local function isExternalCrafting()
	if not _G.C_TradeSkillUI then return true end
	if call(_G.C_TradeSkillUI.IsTradeSkillGuild) then return true end
	if call(_G.C_TradeSkillUI.IsTradeSkillGuildMember) then return true end
	if call(_G.C_TradeSkillUI.IsNPCCrafting) then return true end
	if _G.IsTradeSkillLinked and call(_G.IsTradeSkillLinked) then return true end
	return false
end

local function saveFilters()
	if _G.Professions and type(_G.Professions.GetCurrentFilterSet) == "function" then
		local ok, filters = pcall(_G.Professions.GetCurrentFilterSet)
		if ok then return filters end
	end
	local filters = {
		textFilter = call(_G.C_TradeSkillUI.GetRecipeItemNameFilter),
		showLearned = call(_G.C_TradeSkillUI.GetShowLearned),
		showUnlearned = call(_G.C_TradeSkillUI.GetShowUnlearned),
		showOnlyMakeable = call(_G.C_TradeSkillUI.GetOnlyShowMakeableRecipes),
		showOnlySkillUps = call(_G.C_TradeSkillUI.GetOnlyShowSkillUpRecipes),
		showOnlyFirstCraft = call(_G.C_TradeSkillUI.GetOnlyShowFirstCraftRecipes),
		sourceTypeFilter = call(_G.C_TradeSkillUI.GetSourceTypeFilter),
	}
	filters.invTypeFilters = {}
	local slotCount = call(_G.C_TradeSkillUI.GetAllFilterableInventorySlotsCount) or 0
	for index = 1, slotCount do
		filters.invTypeFilters[index] = call(_G.C_TradeSkillUI.IsInventorySlotFiltered, index)
	end
	return filters
end

local function clearFilters()
	if not _G.C_TradeSkillUI then return end
	call(_G.C_TradeSkillUI.SetShowLearned, true)
	call(_G.C_TradeSkillUI.SetShowUnlearned, true)
	call(_G.C_TradeSkillUI.SetOnlyShowMakeableRecipes, false)
	call(_G.C_TradeSkillUI.SetOnlyShowSkillUpRecipes, false)
	call(_G.C_TradeSkillUI.SetOnlyShowFirstCraftRecipes, false)
	call(_G.C_TradeSkillUI.ClearInventorySlotFilter)
	call(_G.C_TradeSkillUI.ClearRecipeSourceTypeFilter)
	call(_G.C_TradeSkillUI.ClearRecipeCategoryFilter)
	call(_G.C_TradeSkillUI.SetRecipeItemNameFilter, nil)
	call(_G.C_TradeSkillUI.SetRecipeItemLevelFilter, 0, 0)
end

local function restoreFilters(filters)
	if not filters or not _G.C_TradeSkillUI then return end
	if _G.Professions and type(_G.Professions.ApplyfilterSet) == "function" then
		local ok = pcall(_G.Professions.ApplyfilterSet, filters)
		if ok then return end
	end

	call(_G.C_TradeSkillUI.SetShowLearned, filters.showLearned)
	call(_G.C_TradeSkillUI.SetShowUnlearned, filters.showUnlearned)
	call(_G.C_TradeSkillUI.SetOnlyShowMakeableRecipes, filters.showOnlyMakeable)
	call(_G.C_TradeSkillUI.SetOnlyShowSkillUpRecipes, filters.showOnlySkillUps)
	call(_G.C_TradeSkillUI.SetOnlyShowFirstCraftRecipes, filters.showOnlyFirstCraft)
	call(_G.C_TradeSkillUI.SetRecipeItemNameFilter, filters.textFilter or "")
	if filters.sourceTypeFilter ~= nil then
		call(_G.C_TradeSkillUI.SetSourceTypeFilter, filters.sourceTypeFilter)
	end
	if filters.invTypeFilters then
		for index = 1, #filters.invTypeFilters do
			call(_G.C_TradeSkillUI.SetInventorySlotFilter, index, not filters.invTypeFilters[index])
		end
	end
end

function ns.GetAllRecipeIDs()
	if not _G.C_TradeSkillUI then return {} end

	local filters = saveFilters()
	clearFilters()
	local ids = call(_G.C_TradeSkillUI.GetFilteredRecipeIDs)
	restoreFilters(filters)
	if type(ids) ~= "table" then return {} end

	-- The profession API may reuse its result table; take a stable copy before
	-- restoring the user's filters.
	local copy = {}
	for index = 1, #ids do
		if type(ids[index]) == "number" then
			copy[#copy + 1] = ids[index]
		end
	end
	return copy
end

local function isBasicRequired(slot)
	if not slot then return false end
	if slot.required == false then return false end
	if _G.Enum and _G.Enum.CraftingReagentType and slot.reagentType then
		return slot.reagentType == _G.Enum.CraftingReagentType.Basic
	end
	return slot.reagentType == nil or slot.reagentType == 1
end

function ns.ScheduleCapture(force)
	if ns.captureScheduled then return end
	ns.captureScheduled = true
	ns.After(0.25, function()
		ns.captureScheduled = false
		local ok, err = pcall(ns.CaptureCurrentProfession, force)
		if not ok then
			ns.capturing = false
			ns.captureQueue = nil
			ns.captureInfo = nil
			ns.ReportError(err)
		end
	end)
end

function ns.BuildRecipeRecord(recipeID, recipeInfo, schematic, professionID, professionName)
	local record = {
		id = recipeID,
		name = (schematic and schematic.name) or (recipeInfo and recipeInfo.name),
		professionID = professionID,
		professionName = professionName,
		categoryID = recipeInfo and recipeInfo.categoryID,
		outputItemID = schematic and schematic.outputItemID,
		outputMin = (schematic and schematic.quantityMin) or 1,
		outputMax = (schematic and schematic.quantityMax) or (schematic and schematic.quantityMin) or 1,
		recipeType = schematic and schematic.recipeType,
		reagents = {},
		schemaLoaded = schematic ~= nil,
		updatedAt = time(),
	}

	if not schematic then
		return record
	end

	local slots = schematic.reagentSlotSchematics or {}
	for slotIndex = 1, #slots do
		local slot = slots[slotIndex]
		if isBasicRequired(slot) then
			local itemIDs = {}
			local reagents = slot.reagents or {}
			for reagentIndex = 1, #reagents do
				local reagent = reagents[reagentIndex]
				if reagent.itemID and reagent.itemID > 0 then
					itemIDs[#itemIDs + 1] = reagent.itemID
				end
			end
			if #itemIDs > 0 then
				record.reagents[#record.reagents + 1] = {
					itemIDs = itemIDs,
					qty = slot.quantityRequired or 1,
					slotIndex = slot.slotIndex or slotIndex,
				}
			end
		end
	end

	return record
end

function ns.EnsureRecipe(recipeID)
	if not recipeID then return nil end
	local existing = ns.db and ns.db.recipes and ns.db.recipes[recipeID]
	if existing and existing.schemaLoaded then
		return existing
	end
	if _G.InCombatLockdown and _G.InCombatLockdown() then
		return existing
	end
	ns.ensureFailed = ns.ensureFailed or {}
	if ns.ensureFailed[recipeID] then
		return existing
	end

	ns.ensuring = ns.ensuring or {}
	if ns.ensuring[recipeID] then return existing end
	ns.ensuring[recipeID] = true

	local recipeInfo = call(_G.C_TradeSkillUI.GetRecipeInfo, recipeID)
	local schematic = call(_G.C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not recipeInfo and not schematic then
		ns.ensuring[recipeID] = nil
		return existing
	end

	local professionInfo = ns.GetCurrentProfessionInfo()
	local record = ns.BuildRecipeRecord(
		recipeID,
		recipeInfo,
		schematic,
		professionInfo and professionInfo.professionID or (existing and existing.professionID),
		professionInfo and professionInfo.professionName or (existing and existing.professionName)
	)

	ns.db.recipes[recipeID] = record
	if recipeInfo and recipeInfo.learned and ns.charKey then
		ns.db.known[ns.charKey] = ns.db.known[ns.charKey] or {}
		ns.db.known[ns.charKey][recipeID] = true
	end

	ns.ensuring[recipeID] = nil
	if record.schemaLoaded then
		ns.ensureFailed[recipeID] = nil
		ns.AddRecipeToIndex(record)
	else
		ns.ensureFailed[recipeID] = true
	end
	return record
end

function ns.CaptureCurrentProfession(force)
	if ns.capturing then
		if force then ns.pendingForceCapture = true end
		return
	end
	if not _G.C_TradeSkillUI then return end
	if _G.InCombatLockdown and _G.InCombatLockdown() then return end
	if not _G.C_TradeSkillUI.IsTradeSkillReady or not call(_G.C_TradeSkillUI.IsTradeSkillReady) then
		return
	end
	if isExternalCrafting() then return end

	local info = ns.GetCurrentProfessionInfo()
	if not info or not info.professionID or info.professionID <= 0 then return end

	local professionID = info.professionID
	local now = time()
	ns.capturedThisSession = ns.capturedThisSession or {}
	if not force and ns.capturedThisSession[professionID] then
		return
	end
	if not force and ns.capturedAt and ns.capturedAt[professionID] and (now - ns.capturedAt[professionID]) < 30 then
		return
	end

	local ids = ns.GetAllRecipeIDs()
	if #ids == 0 then return end

	ns.capturing = true
	ns.ensureFailed = {}
	ns.captureQueue = ids
	ns.captureIndex = 1
	ns.captureInfo = {
		professionID = professionID,
		professionName = info.professionName or info.parentProfessionName or "Profession",
	}
	ns.captureChanged = 0
	ns.ProcessCaptureQueue()
end

function ns.ProcessCaptureQueue()
	local ok, err = pcall(ns.ProcessCaptureQueueStep)
	if not ok then
		ns.capturing = false
		ns.captureQueue = nil
		ns.captureInfo = nil
		ns.ReportError(err)
	end
end

function ns.ProcessCaptureQueueStep()
	if not ns.capturing or not ns.captureQueue then return end

	local queue = ns.captureQueue
	local info = ns.captureInfo
	local processed = 0

	while ns.captureIndex <= #queue and processed < 12 do
		local recipeID = queue[ns.captureIndex]
		ns.captureIndex = ns.captureIndex + 1
		processed = processed + 1

		local recipeInfo = call(_G.C_TradeSkillUI.GetRecipeInfo, recipeID)
		local schematic = call(_G.C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if recipeInfo then
			local record = ns.BuildRecipeRecord(recipeID, recipeInfo, schematic, info.professionID, info.professionName)
			ns.db.recipes[recipeID] = record
			ns.captureChanged = ns.captureChanged + 1

			if recipeInfo.learned and ns.charKey then
				ns.db.known[ns.charKey] = ns.db.known[ns.charKey] or {}
				ns.db.known[ns.charKey][recipeID] = true
			end
		end
	end

	if ns.captureIndex <= #queue then
		ns.After(0, ns.ProcessCaptureQueue)
		return
	end

	ns.capturing = false
	ns.captureQueue = nil
	ns.captureInfo = nil
	ns.capturedAt = ns.capturedAt or {}
	ns.capturedAt[info.professionID] = time()
	ns.capturedThisSession = ns.capturedThisSession or {}
	ns.capturedThisSession[info.professionID] = true
	ns.db.meta.lastCaptureAt = time()
	ns.db.meta.lastCaptureProfession = info.professionName

	ns.RebuildRecipeIndex()
	ns.InvalidatePrices()
	if ns.RefreshAll then ns.RefreshAll() end

	if ns.pendingForceCapture then
		ns.pendingForceCapture = nil
		ns.ScheduleCapture(true)
	end
end

local function addUnique(list, value)
	for index = 1, #list do
		if list[index] == value then return end
	end
	list[#list + 1] = value
end

function ns.AddRecipeToIndex(recipe)
	if not recipe or not recipe.id then return end
	local recipeID = recipe.id

	ns.byOutput = ns.byOutput or {}
	ns.byName = ns.byName or {}
	ns.byTrainer = ns.byTrainer or {}
	ns.trackedItems = ns.trackedItems or {}
	ns.indexedRecipeIDs = ns.indexedRecipeIDs or {}

	if not ns.indexedRecipeIDs[recipeID] then
		ns.indexedRecipeIDs[recipeID] = true
		ns.recipeCount = (ns.recipeCount or 0) + 1
	end

	if recipe.outputItemID and recipe.outputItemID > 0 then
		ns.byOutput[recipe.outputItemID] = ns.byOutput[recipe.outputItemID] or {}
		addUnique(ns.byOutput[recipe.outputItemID], recipeID)
		ns.trackedItems[recipe.outputItemID] = true
	end

	local nameKey = ns.Normalize(recipe.name)
	if nameKey ~= "" then
		ns.byName[nameKey] = ns.byName[nameKey] or {}
		addUnique(ns.byName[nameKey], recipeID)

		local professionKey = ns.Normalize(recipe.professionName)
		if professionKey ~= "" then
			local key = professionKey .. "|" .. nameKey
			if not ns.byTrainer[key] then
				ns.byTrainer[key] = recipeID
			end
		end
	end

	local reagents = recipe.reagents or {}
	for index = 1, #reagents do
		local itemIDs = reagents[index].itemIDs or {}
		for itemIndex = 1, #itemIDs do
			ns.trackedItems[itemIDs[itemIndex]] = true
		end
	end

	if ns.econCache then
		ns.econCache[recipeID] = nil
	end
end

function ns.RebuildRecipeIndex()
	ns.byOutput = {}
	ns.byName = {}
	ns.byTrainer = {}
	ns.trackedItems = {}
	ns.indexedRecipeIDs = {}
	ns.recipeCount = 0
	if ns.ClearEconCache then ns.ClearEconCache() end

	local recipes = ns.db and ns.db.recipes or {}
	for recipeID, recipe in pairs(recipes) do
		if type(recipe) == "table" then
			recipe.id = recipe.id or recipeID
			ns.AddRecipeToIndex(recipe)
		end
	end
end

function ns.FindTrainerRecipe(professionName, serviceName)
	if not serviceName then return nil end
	local nameKey = ns.Normalize(serviceName)
	if nameKey == "" then return nil end

	local professionKey = ns.Normalize(professionName)
	if professionKey ~= "" and ns.byTrainer then
		local recipeID = ns.byTrainer[professionKey .. "|" .. nameKey]
		if recipeID then return recipeID end
	end

	local candidates = ns.byName and ns.byName[nameKey]
	if candidates then
		for index = 1, #candidates do
			local recipe = ns.GetRecipe(candidates[index])
			if recipe and recipe.outputItemID then
				return candidates[index]
			end
		end
		return candidates[1]
	end

	return nil
end

function ns.IsTrackedItem(itemID)
	return ns.trackedItems and ns.trackedItems[itemID] == true
end

function ns.GetKnownRecipeCount()
	if not ns.db or not ns.charKey then return 0 end
	local known = ns.db.known and ns.db.known[ns.charKey]
	if not known then return 0 end
	local count = 0
	for _ in pairs(known) do count = count + 1 end
	return count
end

function ns.ResetRecipeData()
	if not ns.db then return end
	ns.db.recipes = {}
	ns.db.known = {}
	ns.db.meta.lastCaptureAt = nil
	ns.db.meta.lastCaptureProfession = nil
	ns.capturedAt = {}
	ns.ensureFailed = {}
	ns.RebuildRecipeIndex()
	ns.InvalidatePrices()
end
