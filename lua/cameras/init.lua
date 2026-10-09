local load_module, get_runtime, features, equipment_ecm, world_target, adapters, camera_hud = ...

local observer = load_module("cameras/observer", get_runtime, features, equipment_ecm)
local capture = load_module("cameras/capture", get_runtime, observer)
local host = load_module("cameras/host", observer, get_runtime, capture)
local client = load_module("cameras/client", observer, get_runtime, features)
local attention =
	load_module("cameras/attention", world_target, get_runtime, adapters, camera_hud, capture, observer, host, client)
local camera = load_module("cameras/security_camera", get_runtime, attention, observer, host, client)
load_module("cameras/hooks/security_camera", camera, observer, attention, client)

return true
