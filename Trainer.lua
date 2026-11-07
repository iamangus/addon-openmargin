local addonName, ns = ...

local function safeHookGlobal(name, fn)
	if type(_G[name]) ~= "function" then return false end
	local ok = pcall(hooksecurefunc, name, fn)
	return ok
end

local function call(method, ...)
	if type(method) ~= "function" then return nil end
	local ok, value = pcall(method, ...)
	if ok then return value end
	return nil
end

-- Retail and Forever expose the trainer service's spell id through the
-- tooltip API. The spell id is also the recipe id, which lets us price
-- recipes the character has not learned yet.
function ns.GetTrainerServiceSpellID(skillIndex)
	local api = _G.C_TooltipInfo
	if not api or type(api.GetTrainerService) ~= "function" then return nil end

	local data = call(api.GetTrainerService, skillIndex)
	if type(data) ~= "table" then return nil end

	local spellType = _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Spell
	if spellType and data.type and data.type ~= spellType then return nil end

	local id = data.id
	if _G.issecretvalue and _G.issecretvalue(id) then return nil end
	id = tonumber(id)
	if id and id > 0 then return id end
	return nil
end

local function findTrainerRecipe(skillIndex, serviceName, professionName)
	local spellID = ns.GetTrainerServiceSpellID(skillIndex)
	if spellID and _G.C_TradeSkillUI then
		local schematic = call(_G.C_TradeSkillUI.GetRecipeSchematic, spellID, false)
		if schematic then
			local record = ns.EnsureRecipe(spellID, professionName)
			if record and record.schemaLoaded then
				return spellID
			end
		end
	end
	return ns.FindTrainerRecipe(professionName, serviceName)
end

local function ensureTrainerTag(button)
	local tag = button.OpenMarginTag
	if not tag then
		tag = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		tag:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -6, 4)
		tag:SetWidth(84)
		tag:SetJustifyH("RIGHT")
		tag:SetWordWrap(false)
		button.OpenMarginTag = tag
	end
	return tag
end

-- Material cost, Auction House sale and vendor sale, kept on one compact line
-- below the recipe name and to the left of the profit tag.
local function ensureTrainerDetail(button)
	local detail = button.OpenMarginDetail
	if not detail then
		detail = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		detail:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 44, 2)
		detail:SetWidth(162)
		detail:SetJustifyH("LEFT")
		detail:SetWordWrap(false)
		detail:SetTextColor(0.75, 0.75, 0.75)
		button.OpenMarginDetail = detail
	end
	return detail
end

local function hideTrainerInfo(button)
	if button.OpenMarginTag then button.OpenMarginTag:Hide() end
	if button.OpenMarginDetail then button.OpenMarginDetail:Hide() end
end

local function detailMoney(value, uncertain)
	if not value then return "—" end
	return (uncertain and "~" or "") .. ns.FormatMoney(value)
end

local function updateTrainerInfo(button, econ)
	if not econ then
		hideTrainerInfo(button)
		return
	end

	local tag = ensureTrainerTag(button)
	local text, r, g, b = ns.GetTag(econ)
	tag:SetText(text)
	tag:SetTextColor(r, g, b)
	tag:Show()

	local detail = ensureTrainerDetail(button)
	local cost = detailMoney(econ.cost, not econ.costComplete)
	detail:SetFormattedText("Mat %s AH %s Vendor %s",
		cost,
		detailMoney(econ.sale),
		detailMoney(econ.vendorSale))
	detail:Show()
end

function ns.OnTrainerServiceButton(button, elementData)
	if not button or not ns.db then return end

	if not ns.db.settings.trainer or not _G.IsTradeskillTrainer or not _G.IsTradeskillTrainer() then
		hideTrainerInfo(button)
		button.OpenMarginRecipeID = nil
		return
	end

	elementData = elementData and (elementData.data or elementData)
	local skillIndex = elementData and elementData.skillIndex
	if not skillIndex then
		hideTrainerInfo(button)
		return
	end

	local serviceName = _G.GetTrainerServiceInfo and _G.GetTrainerServiceInfo(skillIndex)
	local professionName = _G.GetTrainerServiceSkillLine and _G.GetTrainerServiceSkillLine(skillIndex)
	if not serviceName or not professionName then
		hideTrainerInfo(button)
		return
	end

	if not button.OpenMarginTooltipHooked then
		button.OpenMarginTooltipHooked = true
		button:HookScript("OnEnter", function(self)
			ns.ShowTrainerTooltip(self)
		end)
	end

	local recipeID = findTrainerRecipe(skillIndex, serviceName, professionName)
	if not recipeID then
		hideTrainerInfo(button)
		button.OpenMarginRecipeID = nil
		return
	end

	ns.EnsureRecipe(recipeID, professionName)
	local econ = ns.GetCachedEconomics(recipeID)
	if not econ then
		hideTrainerInfo(button)
		return
	end

	updateTrainerInfo(button, econ)

	local moneyCost = _G.GetTrainerServiceCost and _G.GetTrainerServiceCost(skillIndex)
	local payback
	if moneyCost and moneyCost > 0 and econ.net and econ.net > 0 then
		payback = math.ceil(moneyCost / econ.net)
	end

	button.OpenMarginRecipeID = recipeID
	button.OpenMarginTrainingCost = moneyCost
	button.OpenMarginPayback = payback
end

function ns.TryTrainerSpellID(button)
	local tooltip = _G.GameTooltip
	if not tooltip or type(tooltip.GetSpell) ~= "function" then return end

	local results = { pcall(tooltip.GetSpell, tooltip) }
	if not results[1] then return end

	for index = 2, #results do
		local value = results[index]
		if type(value) == "number" and ns.db.recipes[value] then
			if button.OpenMarginRecipeID ~= value then
				button.OpenMarginRecipeID = value
				local econ = ns.GetCachedEconomics(value)
				updateTrainerInfo(button, econ)
			end
			return
		end
	end
end

function ns.ShowTrainerTooltip(button)
	if not button then return end
	local tooltip = _G.GameTooltip
	if not tooltip or not tooltip:IsShown() then return end

	ns.TryTrainerSpellID(button)

	if not button.OpenMarginRecipeID then return end
	local econ = ns.GetCachedEconomics(button.OpenMarginRecipeID)
	if not econ then return end

	tooltip:AddLine(" ")
	tooltip:AddLine("OpenMargin", 0.2, 1, 0.6)
	tooltip:AddDoubleLine("Craft cost", econ.costComplete and ns.FormatMoneyFull(econ.cost) or "partial", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("AH sell", econ.sale and ns.FormatMoneyFull(econ.sale) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("AH net", econ.net and ns.FormatMoney(econ.net, true) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("Vendor sell", econ.vendorSale and ns.FormatMoneyFull(econ.vendorSale) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	tooltip:AddDoubleLine("Vendor net (vendor mats)", econ.vendorNet and ns.FormatMoney(econ.vendorNet, true) or "—", 0.8, 0.8, 0.8, 1, 1, 1)
	local fullText = econ.vendorNetFull and ns.FormatMoney(econ.vendorNetFull, true)
		or (econ.vendorSale and not econ.costComplete and "partial" or "—")
	tooltip:AddDoubleLine("Vendor after full cost", fullText, 0.8, 0.8, 0.8, 1, 1, 1)

	if button.OpenMarginTrainingCost then
		tooltip:AddDoubleLine("Training cost", ns.FormatMoneyFull(button.OpenMarginTrainingCost), 0.8, 0.8, 0.8, 1, 1, 1)
	end

	if button.OpenMarginPayback then
		tooltip:AddLine(string.format("Pays back training in %d craft%s.", button.OpenMarginPayback, button.OpenMarginPayback == 1 and "" or "s"), 0.2, 1, 0.6)
	elseif econ.net and econ.net <= 0 then
		tooltip:AddLine("This recipe does not pay back its training cost at current prices.", 1, 0.5, 0.5, true)
	end

	tooltip:Show()
end

function ns.UpdateTrainerSummary()
	local frame = _G.ClassTrainerFrame
	if not frame or not ns.db then return end

	local summary = frame.OpenMarginSummary
	if not summary then
		summary = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		summary:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 160, 10)
		summary:SetWidth(120)
		summary:SetHeight(30)
		summary:SetJustifyH("LEFT")
		summary:SetJustifyV("MIDDLE")
		frame.OpenMarginSummary = summary
	end

	if not ns.db.settings.trainer or not frame:IsShown() or not _G.IsTradeskillTrainer or not _G.IsTradeskillTrainer() then
		summary:Hide()
		return
	end

	local total, mapped, profitable, paybackCount = 0, 0, 0, 0
	local numServices = _G.GetNumTrainerServices and _G.GetNumTrainerServices() or 0
	for skillIndex = 1, numServices do
		total = total + 1
		local serviceName = _G.GetTrainerServiceInfo and _G.GetTrainerServiceInfo(skillIndex)
		local professionName = _G.GetTrainerServiceSkillLine and _G.GetTrainerServiceSkillLine(skillIndex)
		if serviceName and professionName then
			local recipeID = ns.FindTrainerRecipe(professionName, serviceName)
			if recipeID then
				mapped = mapped + 1
				ns.EnsureRecipe(recipeID)
				local econ = ns.GetCachedEconomics(recipeID)
				local moneyCost = _G.GetTrainerServiceCost and _G.GetTrainerServiceCost(skillIndex)
				if econ and econ.net and econ.net > 0 then
					profitable = profitable + 1
					if moneyCost and moneyCost > 0 and math.ceil(moneyCost / econ.net) <= 20 then
						paybackCount = paybackCount + 1
					end
				end
			end
		end
	end

	if mapped == 0 then
		summary:SetText("OpenMargin: open this profession once to load its recipes.")
		summary:SetTextColor(0.6, 0.6, 0.6)
	else
		summary:SetText(string.format("OpenMargin: %d of %d recipes repay training within 20 crafts.", paybackCount, mapped))
		if paybackCount > 0 then
			summary:SetTextColor(0.25, 1, 0.25)
		else
			summary:SetTextColor(0.8, 0.8, 0.8)
		end
	end
	summary:Show()
end

function ns.RefreshTrainer()
	local frame = _G.ClassTrainerFrame
	if not frame then return end
	if frame:IsShown() and type(_G.ClassTrainerFrame_Update) == "function" then
		pcall(_G.ClassTrainerFrame_Update, true)
	end
	ns.UpdateTrainerSummary()
end

function ns.InstallTrainerHooks()
	if not ns.trainerHooks then ns.trainerHooks = {} end

	if not ns.trainerHooks.service then
		ns.trainerHooks.service = safeHookGlobal("ClassTrainerFrame_InitServiceButton", function(button, elementData)
			local ok, err = pcall(ns.OnTrainerServiceButton, button, elementData)
			if not ok then ns.ReportError(err) end
		end)
	end

	if not ns.trainerHooks.update then
		ns.trainerHooks.update = safeHookGlobal("ClassTrainerFrame_Update", function()
			local ok, err = pcall(ns.UpdateTrainerSummary)
			if not ok then ns.ReportError(err) end
		end)
	end
end
