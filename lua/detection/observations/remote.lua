local Runtime, Records, State, engine_alive, adapters, peers, peer_delivery, report_fields = ...
local object_key = State.object_key
local FAMILY = "observation"

local TTL = 2

local REJECTED_CAP = 256

local SUB = 1001

local STATE_FIELDS = {
	{ "notice_progress", "number" },
	{ "uncover_progress", "number" },
	{ "suspicion_progress", "number" },
	{ "identified", "optional_boolean" },
	{ "verified", "optional_boolean" },
	{ "alarmed", "optional_boolean" },
}
local FIELDS = {}
for _, field in ipairs(report_fields) do
	FIELDS[#FIELDS + 1] = field
end
for _, field in ipairs(STATE_FIELDS) do
	FIELDS[#FIELDS + 1] = field
end

local function stream_key(report)
	return object_key(report.observer_kind, report.observer_id)
		.. ":"
		.. tostring(report.observer_generation or 0)
		.. ">"
		.. object_key(report.target_kind, report.target_id)
		.. ":"
		.. tostring(report.incarnation)
		.. "@"
		.. tostring(report.epoch)
end

local function views(self)
	local state = self.remote_views
	if not state then
		state = { entries = {}, rejected = {}, rejected_count = 0, steps = {}, step_count = 0 }
		self.remote_views = state
	end
	return state
end

local function rejected(self, report)
	local state = self.remote_views
	local seq = state and state.rejected[stream_key(report)]
	return seq ~= nil and report.seq <= seq
end

local function remember_rejection(self, report)
	local state = views(self)
	local key = stream_key(report)
	if not state.rejected[key] then
		if state.rejected_count >= REJECTED_CAP then
			state.rejected, state.rejected_count = {}, 0
		end
		state.rejected_count = state.rejected_count + 1
	end
	state.rejected[key] = math.max(state.rejected[key] or 0, report.seq)
end

local function cool(unit)
	local movement = engine_alive(unit) and unit:movement()
	return not movement or movement:cool() ~= false
end

local function current(self, actor, report)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local target_key = object_key(report.target_kind, report.target_id)
	local observer, target = self.core:observer(observer_key), self.core:target(target_key)
	local owner = self.core:owner_record(target_key)
	local revision = self.core:target_config_revision(target_key)
	if not observer or not target then
		return false, "missing_identity"
	elseif observer.generation ~= report.observer_generation then
		return false, "stale_observer"
	elseif target.incarnation ~= report.incarnation or not owner or owner.incarnation ~= report.incarnation then
		return false, "stale_incarnation"
	elseif owner.owner_peer_id ~= actor then
		return false, "wrong_owner"
	elseif owner.epoch ~= report.epoch then
		return false, "stale_epoch"
	elseif revision ~= report.config_revision then
		return false, "stale_config"
	elseif report.observer_kind == "guard" and not cool(observer.unit) then
		return false, "observer_alerted"
	end
	return true
end

local function settled(confirmed, entry)
	return confirmed ~= nil
		and confirmed.owner_peer_id == entry.actor
		and confirmed.epoch == entry.epoch
		and confirmed.incarnation == entry.incarnation
		and (confirmed.seq > entry.seq or confirmed.seq == entry.seq and entry.version % SUB == 0)
end

local function hide_player(entry)
	local player = adapters.player
	if entry.hud_keys and player and player.withdraw_remote then
		player.withdraw_remote(entry.hud_keys[1], entry.hud_keys[2])
	end
end

local function withdraw(self, entry)
	if entry.hud_keys and not settled(self.core:observation(entry.observer_key .. ">" .. entry.target_key), entry) then
		hide_player(entry)
	end
end

local function live(self, entry)
	return self.network_time < entry.expires_at
		and peers.session_id() == entry.session_id
		and peers.membership(entry.actor) == entry.membership
		and peers.allows(entry.actor, "detection")
		and peers.allows(self.local_peer_id, "detection")
		and current(self, entry.actor, entry)
		and not settled(self.core:observation(entry.observer_key .. ">" .. entry.target_key), entry)
		and engine_alive(self.core:observer(entry.observer_key).unit)
		and engine_alive(self.core:target(entry.target_key).unit)
end

function Runtime:clear_remote_observations()
	for _, entry in pairs(self.remote_views and self.remote_views.entries or {}) do
		hide_player(entry)
	end
	self.remote_views = nil
end

function Runtime:prune_remote_observations()
	local state = self.remote_views
	if not state then
		return
	end
	local active = self:is_active()
	for key, entry in pairs(state.entries) do
		if not active or not live(self, entry) then
			state.entries[key] = nil
			withdraw(self, entry)
		end
	end
end

function Runtime:remote_observation_entries()
	local state = self.remote_views
	if not state or not next(state.entries) then
		return nil
	end
	self:prune_remote_observations()
	return next(state.entries) and state.entries or nil
end

function Runtime:propose_remote_observation(observation, step)
	if not self.core.is_host and observation.observer_generation then
		peer_delivery:propose(FAMILY, stream_key(observation), observation.seq * SUB + (step or 0), observation)
	end
end

function Runtime:propose_remote_progress(observer_key, target_key)
	local observation = self.core:observation(observer_key .. ">" .. target_key)
	if not observation or not observation.observer_generation then
		return
	end
	local state, key = views(self), stream_key(observation)
	local last, pair = state.steps[key], observer_key .. ">" .. target_key
	if not last and state.step_count >= REJECTED_CAP then
		for stale, counter in pairs(state.steps) do
			local latest = self.core:observation(counter.pair)
			if not latest or latest.seq ~= counter.seq or stream_key(latest) ~= stale then
				state.steps[stale], state.step_count = nil, state.step_count - 1
			end
		end
		if state.step_count >= REJECTED_CAP then
			return
		end
	end
	local step = last and last.seq == observation.seq and last.step + 1 or 1
	if step < SUB then
		state.step_count = state.step_count + (last and 0 or 1)
		state.steps[key] = { seq = observation.seq, step = step, pair = pair }
		self:propose_remote_observation(observation, step)
	end
end

function Runtime:reject_remote_observation(peer_id, report, reason)
	if report and reason ~= "observer_alerted" and self.core.is_host and peer_id ~= self.local_peer_id then
		peer_delivery:retract(FAMILY, peer_id, stream_key(report), report.seq * SUB + SUB - 1, report)
	end
end

local function admit(self, env, report, route)
	local observer_key = object_key(report.observer_kind, report.observer_id)
	local target_key = object_key(report.target_kind, report.target_id)
	local key = observer_key .. ">" .. target_key
	local state = views(self)
	local previous = state.entries[key]
	report.actor, report.version = env.actor, env.version
	if
		settled(self.core:observation(key), report)
		or previous and stream_key(previous) == env.key and previous.version > env.version
	then
		return
	end
	local entry = report
	entry.cleared = report.transition == "lost" or report.transition == "clear"

	entry.alarm_pending, entry.alarmed = report.alarmed, nil
	entry.observer_key, entry.target_key = observer_key, target_key
	entry.provisional, entry.owner_peer_id, entry.source_peer_id = true, env.actor, env.actor
	entry.membership, entry.session_id, entry.route = env.membership, env.session_id, route
	entry.expires_at = self.network_time + TTL
	state.entries[key] = entry
	if entry.target_kind == "player" then
		local value = entry.uncover_progress or entry.suspicion_progress or entry.notice_progress
		value = not entry.cleared and (value or entry.identified and 1) or 0
		local observer, target = self.core:observer(observer_key), self.core:target(target_key)
		local player = adapters.player
		if value > 0 and player and player.show_remote then
			entry.hud_keys = { observer.unit:key(), target.unit:key() }
			player.show_remote(observer.unit, target.unit, value)
		elseif previous then
			hide_player(previous)
		end
	end
end

local function retract(self, env, report)
	remember_rejection(self, report)
	local key = object_key(report.observer_kind, report.observer_id)
		.. ">"
		.. object_key(report.target_kind, report.target_id)
	local entry = self.remote_views.entries[key]
	if entry and entry.actor == env.actor and stream_key(entry) == env.key and entry.seq <= report.seq then
		self.remote_views.entries[key] = nil
		withdraw(self, entry)
	end
end

function Runtime.register_remote_observations(get_runtime)
	peer_delivery:register(FAMILY, {
		feature = "detection",
		fields = FIELDS,
		lifetime = TTL,
		validate = function(record, env)
			local self = get_runtime()
			local report, reason = Records.validate_report(record)
			if not report then
				return nil, reason
			end
			for _, field in ipairs(STATE_FIELDS) do
				local value = record[field[1]]
				if field[2] == "number" and value ~= nil and (value < 0 or value > 1) then
					return nil, "invalid_progress"
				end
				report[field[1]] = value
			end
			if env.key ~= stream_key(report) or math.floor(env.version / SUB) ~= report.seq then
				return nil, "invalid_stream"
			elseif env.op == "reject" then
				return report
			elseif not self:is_active() then
				return nil, "inactive"
			elseif self.core.is_host then
				local confirmed = self.core:observation(
					object_key(report.observer_kind, report.observer_id)
						.. ">"
						.. object_key(report.target_kind, report.target_id)
				)
				if not confirmed or confirmed.seq ~= report.seq then
					return nil, "not_accepted"
				end
			elseif rejected(self, report) then
				return nil, "rejected"
			end
			local valid, why = current(self, env.actor, report)
			if not valid then
				return nil, why
			end
			return report
		end,
		apply = function(env, report, route)
			local self = get_runtime()
			if env.op == "reject" then
				retract(self, env, report)
			else
				admit(self, env, report, route)
			end
			return true
		end,
		reset = function()
			get_runtime():clear_remote_observations()
		end,
	})
end

return Runtime
