local get_runtime = ...
local M = {}
local ALERT_REPORT_HOLD = 5

function M.setup(self)
	self._cst_reported_attention = {}
end

function M.clear(self)
	if self._cst_reported_attention and next(self._cst_reported_attention) then
		self._cst_reported_attention = {}
	end
	self._cst_alert_reported_t = nil
end

function M.is_held(self, t)
	if self._cst_alert_reported_t and t < self._cst_alert_reported_t + ALERT_REPORT_HOLD then
		return true
	end
	self._cst_alert_reported_t = nil
	return false
end

function M.forget(self, key)
	self._cst_reported_attention[key] = nil
end

function M.refresh(self, key)
	local data = self._cst_detection_data
	local entry = data and data.detected_attention_objects[key]
	if not entry and not self._cst_reported_attention[key] then
		return
	end
	if entry then
		M.forget(self, key)
	end
	self._cst_alert_reported_t = nil
end

function M.remap(self, old_key, new_key)
	if old_key ~= new_key then
		self._cst_reported_attention[new_key] = self._cst_reported_attention[old_key]
		self._cst_reported_attention[old_key] = nil
	end
end

function M.restart(self, key)
	local previous = self._cst_reported_attention[key]
	if previous then
		get_runtime():send_report("guard", self._unit:id(), previous.target.kind, previous.target.id, "lost")
	end
	M.forget(self, key)
end

local function reported_notice(notice, target)
	if notice and notice < 1 and target and target.kind ~= "player" then
		return 0
	end
	return notice
end

function M.update(self, clear_local_alert)
	local runtime = get_runtime()
	local current = self._cst_detection_data.detected_attention_objects
	local previous = self._cst_reported_attention
	local observer_id = self._unit:id()
	local function alarming(entry)
		return entry.reaction and entry.reaction >= AIAttentionObject.REACT_SCARED
	end
	local targets = {}
	for key, entry in pairs(current) do
		targets[key] = runtime:target_for_unit(entry.unit)
	end

	local function report_entry(key, entry, target)
		local old = previous[key] or {}
		local verified = entry.verified == true
		local notice = reported_notice(entry.notice_progress, target)
		if not old.seen or notice ~= nil and notice ~= old.notice then
			runtime:send_report("guard", observer_id, target.kind, target.id, "notice", notice or 1)
		end
		if notice ~= entry.notice_progress and entry.notice_progress ~= old.shown then
			runtime:show_local_notice("guard", observer_id, target.kind, target.id, entry.notice_progress)
		end
		if verified ~= old.verified then
			runtime:send_report("guard", observer_id, target.kind, target.id, "verified", verified and 1 or 0)
		end
		local outcome
		if entry.identified and not old.identified then
			local reported, reason = runtime:send_report("guard", observer_id, target.kind, target.id, "identified")
			if not reported then
				clear_local_alert(self, entry.unit)
				outcome = "failed"
			elseif reason == "queued" then
				outcome = "queued"
			else
				outcome = "sent"
				if entry.reaction and entry.reaction >= AIAttentionObject.REACT_SCARED then
					self._cst_alert_reported_t = self._cst_detection_data.t
				end
			end
		end

		previous[key] = {
			identified = entry.identified and outcome ~= "failed" or false,
			notice = notice,
			queued = entry.identified
					and (outcome == "queued" or old.queued and outcome ~= "sent" and outcome ~= "failed")
				or nil,
			shown = notice ~= entry.notice_progress and entry.notice_progress or nil,
			uncover = entry.uncover_progress,
			seen = true,
			target = target,
			verified = verified,
		}
		if target.kind == "player" and entry.uncover_progress ~= old.uncover then
			local reported = runtime:send_report(
				"guard",
				observer_id,
				target.kind,
				target.id,
				"suspicion",
				entry.uncover_progress or 0
			)
			if not reported and entry._cst_uncovered then
				clear_local_alert(self, entry.unit)
			end
		end
		return outcome
	end

	for key, entry in pairs(current) do
		local target = targets[key]
		if target and (target.kind == "player" or not alarming(entry)) then
			report_entry(key, entry, target)
			if self._cst_alert_reported_t then
				return
			end
		end
	end

	local excluded = {}
	local selected
	local queued_selected
	local ready_identified_only = false
	while true do
		local best_key, best_score
		for key, entry in pairs(current) do
			local target = targets[key]
			if target and target.kind ~= "player" and alarming(entry) and not excluded[key] then
				local old = previous[key]
				local ready = not target.prediction or not target.subject_pending
				local actionable = entry.identified and not (old and old.identified)
				if not ready_identified_only or ready and actionable then
					local score = actionable and (ready and 5 or 3) or old and old.queued and 4 or ready and 2 or 1
					if old and old.seen then
						score = score + 0.5
					end
					if
						not best_score
						or score > best_score
						or score == best_score and tostring(key) < tostring(best_key)
					then
						best_key, best_score = key, score
					end
				end
			end
		end
		if not best_key then
			selected = queued_selected or selected
			break
		end
		selected = best_key
		local outcome = report_entry(best_key, current[best_key], targets[best_key])
		if self._cst_alert_reported_t or outcome ~= "failed" and outcome ~= "queued" then
			break
		end
		excluded[best_key] = true
		if outcome == "queued" then
			queued_selected = queued_selected or best_key
			ready_identified_only = true
		end
	end

	for key, entry in pairs(current) do
		local target = targets[key]
		if target and target.kind ~= "player" and alarming(entry) and key ~= selected then
			local notice = reported_notice(entry.notice_progress, target)
			local old = previous[key]
			if notice ~= entry.notice_progress and (not old or entry.notice_progress ~= old.shown) then
				runtime:show_local_notice("guard", observer_id, target.kind, target.id, entry.notice_progress)
			end
		end
	end
	for key, old in pairs(previous) do
		if not current[key] or old.target.kind ~= "player" and alarming(current[key]) and key ~= selected then
			runtime:send_report("guard", observer_id, old.target.kind, old.target.id, "lost")
			previous[key] = nil
		end
	end
end

function M.seed(self, key, entry, target)
	self._cst_reported_attention[key] = entry
			and {
				identified = entry.identified == true,
				notice = reported_notice(entry.notice_progress, target),
				uncover = entry.uncover_progress,
				seen = true,
				target = target,
				verified = entry.verified == true,
			}
		or nil
end

return M
