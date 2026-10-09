local Records, log_event, adapters, transport, control, control_host, features, camera_hud, load_module, peers, peer_delivery =
	...
local State = load_module("detection/domain", Records, load_module)
local Runtime = load_module(
	"detection/runtime",
	Records,
	State,
	log_event,
	adapters,
	transport,
	control,
	control_host,
	features,
	camera_hud,
	load_module,
	peers,
	peer_delivery
)
return {
	new = State.new,
	Runtime = Runtime.Runtime,
	runtime = Runtime.runtime,
}
