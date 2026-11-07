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

	if not ns.tooltipHooked and _G.GameTooltip then
		local ok = pcall(_G.GameTooltip.HookScript, _G.GameTooltip, "OnTooltipSetItem", function(tooltip)
			local success, err = pcall(ns.OnItemTooltip, tooltip)
			if not success then ns.ReportError(err) end
		end)
		if ok then ns.tooltipHooked = true end
	end

	if _G.GameTooltip and not ns.tooltipHideHooked then
		ns.tooltipHideHooked = true
		pcall(_G.GameTooltip.HookScript, _G.GameTooltip, "OnHide", function(tooltip)
			tooltip.OpenMarginItemID = nil
		end)
	end
end
