local husk = ...
local M = {}

function M:install()
	if self._installed then
		return
	end
	self._installed = true
	husk.start()
	HuskCopBrain.set_important = husk.set_important
	HuskCopBrain.on_detected_attention_obj_tweak_data_changed = husk.tweak_data_changed
	HuskCopBrain.on_detected_attention_obj_modified = husk.attention_modified
	Hooks:PostHook(HuskCopBrain, "post_init", "ClientsideStealthSetupHuskCopBrain", husk.setup)
	Hooks:Add("GameSetupUpdate", "ClientsideStealthUpdateHuskCopBrains", husk.update_brains)
	Hooks:PostHook(HuskCopBrain, "sync_net_event", "ClientsideStealthTrackSyncedHostage", function(brain, event_id)
		local events = HuskCopBrain._NET_EVENTS
		if event_id == events.surrender_civilian_tied then
			husk.hostage_tied(brain)
		elseif event_id == events.surrender_civilian_untied then
			husk.hostage_untied(brain)
		end
	end)
	Hooks:PostHook(HuskCopBrain, "clbk_death", "ClientsideStealthStopDeadHuskCopBrain", husk.stop)
	Hooks:PreHook(HuskCopBrain, "pre_destroy", "ClientsideStealthStopDestroyedHuskCopBrain", husk.stop)
	Hooks:PostHook(HuskCopBrain, "sync_surrender", "ClientsideStealthStopSurrenderedHuskCopBrain", husk.sync_surrender)
	Hooks:PostHook(HuskCopBrain, "sync_converted", "ClientsideStealthStopConvertedHuskCopBrain", husk.sync_converted)
	Hooks:PostHook(HuskCopBrain, "on_cool_state_changed", "ClientsideStealthStopLoudHuskCopBrain", husk.cool_changed)
end

return M
