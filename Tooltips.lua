local addonName, ns = ...

local function addItemLine(tooltip, itemID)
	if not tooltip or not itemID or itemID <= 0 then return end
	if not ns.db or not ns.db.settings.tooltips then return end
	if tooltip.OpenMarginItemID == itemID then return end

	local price, age = ns.GetPrice(itemID)
	if not price and not ns.IsTrackedItem(itemID) then
		return
	end

	tooltip.OpenMarginItemID = itemID

	if price then
		local source = "Auctionator"
		if age then
			source = source .. ", " .. (ns.FormatAge(age) or "age unknown")
		else
			source = source .. ", age unknown"
		end
		tooltip:AddLine("OpenMargin: " .. ns.FormatMoneyFull(price) .. " · " .. source, 1, 0.82, 0)
	else
		tooltip:AddLine("OpenMargin: no Auctionator price", 0.55, 0.55, 0.55)
	end
end

-- Recipe items in the Auction House teach a recipe. Show what the crafted
-- item costs and what it sells for, so the recipe's value is visible without
-- opening the profession window.
function ns.AddRecipeItemTooltip(tooltip, itemID)
	if not tooltip or not itemID or itemID <= 0 then return false end
	if not ns.db or not ns.db.settings.tooltips then return false end
	if tooltip.OpenMarginRecipeItemID == itemID then return true end

	local outputID, outputName, costInfo, missing

	local record, recipeID = ns.ResolveItemRecipe and ns.ResolveItemRecipe(itemID)
	if record and record.outputItemID then
		recipeID = recipeID or record.id
		outputID = record.outputItemID
		outputName = ns.GetItemName(outputID)
		costInfo = ns.GetAHCraftCost and ns.GetAHCraftCost(recipeID, record)
	end

	if not costInfo then
		-- Fallback: read the crafted item and reagent links from the item
		-- tooltip itself. This does not need the profession or a schematic.
		local parsed = ns.ParseRecipeItemTooltip and ns.ParseRecipeItemTooltip(itemID, tooltip)
		if parsed then
			outputID = parsed.outputID
			outputName = parsed.outputName or ns.GetRecipeNameFromItem(itemID)
			costInfo = { cost = parsed.cost, complete = parsed.complete }
			missing = parsed.missing
		end
	end

	if not costInfo then
		if ns.GetRecipeNameFromItem and ns.GetRecipeNameFromItem(itemID)
			and tooltip.OpenMarginRecipeHintID ~= itemID then
			tooltip.OpenMarginRecipeHintID = itemID
			tooltip:AddLine(" ")
			tooltip:AddLine("OpenMargin: no recipe data for this item", 0.55, 0.55, 0.55)
		end
		return false
	end

	tooltip.OpenMarginRecipeItemID = itemID
	tooltip:AddLine(" ")
	tooltip:AddLine("OpenMargin · " .. (outputName or "crafted item"), 1, 0.82, 0)

	local costText = "—"
	if costInfo.cost then
		costText = costInfo.complete and ns.FormatMoneyFull(costInfo.cost) or "partial"
	end
	tooltip:AddDoubleLine("AH mats", costText, 0.8, 0.8, 0.8, 1, 1, 1)

	if not costInfo.complete then
		local missingName = missing and missing[1]
		if not missingName then
			local details = costInfo.details or {}
			for index = 1, #details do
				if not details[index].unit then
					missingName = ns.GetItemName(details[index].itemID)
					break
				end
			end
		end
		if missingName then
			tooltip:AddDoubleLine("  no AH price", tostring(missingName), 0.55, 0.55, 0.55, 0.9, 0.7, 0.4)
		end
	end

	local vendorUnit = outputID and ns.GetVendorSellPrice(outputID)
	tooltip:AddDoubleLine("Vendor sell", vendorUnit and ns.FormatMoneyFull(vendorUnit) or "—",
		0.8, 0.8, 0.8, 1, 1, 1)

	local saleUnit = outputID and ns.GetPrice(outputID)
	tooltip:AddDoubleLine("AH price", saleUnit and ns.FormatMoneyFull(saleUnit) or "no Auctionator price",
		0.8, 0.8, 0.8, 1, 1, 1)

	if saleUnit and costInfo.cost then
		local outputQty = record and ns.GetOutputQuantity(record) or 1
		local sale = saleUnit * outputQty
		local cut = (ns.db.settings.ahCut or 5) / 100
		local profit = sale * (1 - cut) - costInfo.cost
		local text = ns.FormatMoneyFull(profit)
		if profit > 0 then text = "+" .. text end
		local r, g, b = 1, 0.35, 0.35
		if profit > 0 then r, g, b = 0.25, 1, 0.45 end
		tooltip:AddDoubleLine("AH profit", text, 0.8, 0.8, 0.8, r, g, b)
	end

	return true
end

function ns.OnItemTooltip(tooltip, data)
	if not tooltip then return end

	local itemID = data and (data.id or data.itemID)
	if not itemID then
		local ok, _, link = pcall(tooltip.GetItem, tooltip)
		if ok and link and not (_G.issecretvalue and _G.issecretvalue(link)) then
			itemID = ns.GetItemIDFromLink(link)
		end
	end

	addItemLine(tooltip, itemID)
	if ns.AddRecipeItemTooltip then
		ns.AddRecipeItemTooltip(tooltip, itemID)
	end
end

function ns.InstallTooltipHook()
	if ns.tooltipHooked then return end

	if _G.TooltipDataProcessor and _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item then
		local ok = pcall(_G.TooltipDataProcessor.AddTooltipPostCall, _G.Enum.TooltipDataType.Item, function(tooltip, data)
			local success, err = pcall(ns.OnItemTooltip, tooltip, data)
			if not success then ns.ReportError(err) end
		end)
		if ok then
			ns.tooltipHooked = true
		end
	end

	-- Also hook the classic item tooltip event. Some bag, merchant and
	-- Auction House paths do not fire the TooltipDataProcessor post-call.
	if _G.GameTooltip and not ns.tooltipItemHook then
		local ok = pcall(_G.GameTooltip.HookScript, _G.GameTooltip, "OnTooltipSetItem", function(tooltip)
			local success, err = pcall(ns.OnItemTooltip, tooltip)
			if not success then ns.ReportError(err) end
		end)
		if ok then
			ns.tooltipItemHook = true
			ns.tooltipHooked = true
		end
	end

	if _G.GameTooltip and not ns.tooltipHideHooked then
		ns.tooltipHideHooked = true
		pcall(_G.GameTooltip.HookScript, _G.GameTooltip, "OnHide", function(tooltip)
			tooltip.OpenMarginItemID = nil
			tooltip.OpenMarginRecipeItemID = nil
			tooltip.OpenMarginRecipeHintID = nil
		end)
	end
end
