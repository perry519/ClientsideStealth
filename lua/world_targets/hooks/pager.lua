local pager = ...
local M = {}
local client_installed, host_installed = false, false

function M.install_host_completion()
	if host_installed then
		return
	end
	host_installed = true
	local completions = {}
	Hooks:PreHook(
		CopBrain,
		"on_alarm_pager_interaction",
		"ClientsideStealthCapturePagerCompletion",
		function(brain, status, player)
			completions[brain] = pager.capture_host_completion(brain, status, player)
		end
	)
	Hooks:PostHook(CopBrain, "on_alarm_pager_interaction", "ClientsideStealthAssignPagerCompletion", function(brain)
		local completion = completions[brain]
		completions[brain] = nil
		pager.confirm_host_completion(brain, completion)
	end)
end

function M.install_completion()
	if client_installed then
		return
	end
	client_installed = true
	local eligible = {}
	Hooks:PreHook(
		IntimitateInteractionExt,
		"interact",
		"ClientsideStealthCapturePagerCompletion",
		function(interaction, player)
			eligible[interaction] = interaction.tweak_data == "corpse_alarm_pager"
					and interaction:can_interact(player)
					and pager.corpse(interaction._unit)
				or nil
		end
	)
	Hooks:PostHook(
		IntimitateInteractionExt,
		"interact",
		"ClientsideStealthPredictPagerCompletion",
		function(interaction, player)
			local corpse = eligible[interaction]
			eligible[interaction] = nil
			pager.predict_completion(interaction._unit, player, corpse)
		end
	)
end

return M
