extends Node

# =============================================================================
# Safe Relay Chat  v1.7.5
# Hardened WebSocket chat with strict filters, ephemeral identity, tripwire,
# stealth mode, AFK auto-disconnect, and a mod-event API.
#
# Cannot hide your IP from the relay operator (TCP-level fact). Use a VPN
# at the OS level if needed.
# =============================================================================

const Filters     = preload("res://mods/SafeRelayChat/Filters.gd")
const IncomingLog = preload("res://mods/SafeRelayChat/IncomingLog.gd")

# SECURITY INVARIANT: never call OS.execute / OS.shell_open / OS.create_process,
# never load() or ResourceLoader.load() a path derived from network input.

# ---- Constants ---------------------------------------------------------------
const DEFAULT_RELAY_URL := "wss://vostok-relay-chat.mrdeadnasty.workers.dev/ws"
const RECONNECT_DELAY   := 5.0
const TOGGLE_ACTION     := "safe_relay_chat_toggle"

const MAX_TOASTS         := 5
const TOAST_FADE_TIME    := 0.6

const BLOCKLIST_PATH       := "user://SafeRelayChat/blocklist.cfg"
const PRIVACY_ACK_PATH     := "user://SafeRelayChat/privacy_acknowledged.cfg"
const PERSISTENT_NAME_PATH := "user://SafeRelayChat/username.cfg"
const EVENT_REGISTRY_PATH  := "user://SafeRelayChat/event_registry.cfg"

# Hard guard: any incoming string longer than this is truncated before display.
const MAX_INCOMING_TEXT := 300
const MAX_OUTGOING_TEXT := 200

# ---- Live settings (from MCM, hot-reloadable) -------------------------------
var _relay_url        : String = DEFAULT_RELAY_URL
var _show_join_leave  : bool   = true
var _opacity          : float  = 0.88
var _max_history      : int    = 80
var _username         : String = ""
var _font_size        : int    = 12
var _passive_enabled  : bool   = true
var _toast_duration   : float  = 8.0
var _network_enabled  : bool   = true
var _auto_connect     : bool   = false
var _ephemeral_identity : bool = true
var _connect_on_open  : bool   = true
var _stealth_closed   : bool   = false  # Stay connected when window closed, but mute all outgoing.
var _suppress_jl      : bool   = false  # Never broadcast join/leave system messages.
var _outbox_buffer    : Array  = []     # Stored messages while muted; never auto-flushed.

# AFK auto-disconnect.
var _afk_enabled        : bool    = true
var _afk_timeout_s      : float   = 900.0   # 15 min default
var _afk_warn_s         : float   = 30.0    # warn this many seconds before
var _afk_last_activity  : float   = 0.0
var _afk_warned         : bool    = false
var _afk_last_mouse_pos : Vector2 = Vector2.ZERO

# Background Sync -- periodic short connection windows while chat is closed.
var _bg_enabled       : bool   = false
var _bg_interval_s    : float  = 300.0  # 5 min default
var _bg_window_s      : float  = 15.0
var _bg_silent        : bool   = true
var _bg_toasts        : bool   = false
var _bg_next_sync_t   : float  = 30.0   # first sync ~30s after game start
var _bg_window_left   : float  = 0.0
var _bg_active        : bool   = false
var _bg_collected     : int    = 0
var _bg_total_synced  : int    = 0

var _filter_in        : bool   = true
var _filter_out       : bool   = false
var _strip_urls       : bool   = true
var _block_pii_out    : bool   = true
var _extra_terms      : Array  = []
var _send_cooldown    : float  = 1.0

# Auto-broadcast settings.
var _ab_enabled       : bool   = false
var _ab_chance        : int    = 30
var _ab_cooldown      : float  = 45.0
var _ab_last_t        : float  = -1e6
var _tpl_shelter      : String = ""
var _tpl_trader       : String = ""
var _tpl_map          : String = ""
var _tpl_hunted       : String = ""
var _tpl_combat_end   : String = ""

# Metadata privacy.
var _meta_pad         : bool   = true
var _meta_jitter      : float  = 0.3

# Tripwire (emergency disconnect).
var _tw_enabled       : bool   = true
var _tw_link_thresh   : int    = 5
var _tw_lockout       : float  = 300.0
var _tw_tripped       : bool   = false
var _tw_tripped_t     : float  = 0.0
var _tw_reason        : String = ""
var _tw_link_count    : int    = 0
var _tw_link_window_t : float  = 0.0
var _tw_bad_json      : int    = 0
var _tw_bad_json_t    : float  = 0.0

# Toggle key (resolved from MCM at runtime).
var _toggle_keycode   : int    = KEY_BACKSLASH
# Hardcoded emergency key that ALWAYS works regardless of MCM corruption,
# Keycode parsing issues, or rebind bugs. Pick KEY_HOME -- not used by RTV.
const EMERGENCY_TOGGLE_KEY := KEY_HOME
const KILL_SWITCH_KEY     := KEY_MINUS
const TOGGLE_ACTION_NAME  := "safe_relay_chat_toggle"

# Event tracker state.
var _ab_last_shelter  : bool   = false
var _ab_last_trading  : bool   = false
var _ab_last_map      : String = ""
var _ab_in_combat     : bool   = false
var _ab_last_combat_t : float  = -1e6
var _ab_scan_timer    : float  = 0.0
var _ab_combat_end_pending : bool = false

# ---- Internal state ----------------------------------------------------------
var _socket          : WebSocketPeer = null
var _connected       := false
var _reconnect_timer := 0.0
var _last_send_t     : float = -1e6
var _blocklist       : Dictionary = {}  # lower(name) -> true
var _log             : RefCounted = null

# Game integration
var _game_data : Resource = null
var _prev_mouse_mode : int = Input.MOUSE_MODE_CAPTURED
var _prev_freeze : bool = false

# UI nodes
var _canvas        : CanvasLayer
var _root_control  : Control
var _chat_panel    : PanelContainer
var _scroll        : ScrollContainer
var _message_list  : VBoxContainer
var _input_box     : LineEdit
var _status_label  : Label
var _hint_label    : Control
var _toast_container : VBoxContainer
var _hint_panel      : Control
var _open          := false

# ---- Entry point -------------------------------------------------------------
func _ready() -> void:
	Engine.set_meta("SafeRelayChatNode", self)
	print("[SafeRelayChat] booting (v1.7.5) -- toggle key cached as keycode ", _toggle_keycode)

	if ResourceLoader.exists("res://Resources/GameData.tres"):
		_game_data = load("res://Resources/GameData.tres")

	DirAccess.make_dir_recursive_absolute("user://SafeRelayChat")
	_log = IncomingLog.new()
	_load_blocklist()
	_load_event_registry()
	_load_config_from_disk()
	_resolve_username()
	_afk_last_activity = Time.get_ticks_msec() / 1000.0

	_ensure_input_action()
	_build_ui()

	if _has_privacy_ack():
		if not _network_enabled:
			_set_status("Mod network disabled (offline mode).")
		elif _connect_on_open:
			# In connect-on-open mode the socket stays closed until the chat
			# window is opened. This overrides auto_connect by design.
			_set_status("Idle. Open chat to connect.")
		elif _auto_connect:
			_connect_socket()
		else:
			_set_status("Idle. Open chat and type /connect to join.")
	else:
		_show_privacy_notice()

func _ensure_input_action() -> void:
	if not InputMap.has_action(TOGGLE_ACTION):
		InputMap.add_action(TOGGLE_ACTION)
	_apply_toggle_key()

func _apply_toggle_key() -> void:
	# MCM may have already registered an event for this action; rebuild from
	# our cached _toggle_keycode either way so the two sources can't drift.
	if not InputMap.has_action(TOGGLE_ACTION):
		InputMap.add_action(TOGGLE_ACTION)
	InputMap.action_erase_events(TOGGLE_ACTION)
	# Primary binding (from MCM or default).
	var ev := InputEventKey.new()
	ev.physical_keycode = _toggle_keycode
	InputMap.action_add_event(TOGGLE_ACTION, ev)
	# Emergency fallback: KEY_HOME always works even if the primary fails.
	if _toggle_keycode != EMERGENCY_TOGGLE_KEY:
		var ev2 := InputEventKey.new()
		ev2.physical_keycode = EMERGENCY_TOGGLE_KEY
		InputMap.action_add_event(TOGGLE_ACTION, ev2)
	if is_instance_valid(_hint_label):
		_update_hint_text()

# ---- Config -----------------------------------------------------------------
func _load_config_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://MCM/SafeRelayChat/config.ini") != OK:
		return
	_apply_config_file(cfg)

func _entry_value(cfg: ConfigFile, section: String, key: String, default):
	var entry = cfg.get_value(section, key, null)
	if typeof(entry) == TYPE_DICTIONARY:
		return entry.get("value", default)
	return default

func _apply_config_file(cfg: ConfigFile) -> void:
	var url : String = _entry_value(cfg, "String", "relay_url", DEFAULT_RELAY_URL)
	url = url.strip_edges()
	if _is_safe_url(url):
		_relay_url = url
	else:
		push_warning("[SafeRelayChat] Refusing non-wss:// URL: %s" % url)

	var name_val : String = _entry_value(cfg, "String", "username", "")
	var validated := Filters.validate_username(name_val, _extra_terms)
	if validated != "":
		_username = validated

	_show_join_leave  = bool(_entry_value(cfg, "Bool",  "show_join_leave",  true))
	_opacity          = clampf(float(_entry_value(cfg, "Float", "chat_opacity",    0.88)), 0.2, 1.0)
	_max_history      = clampi(int(_entry_value(cfg, "Int",   "max_history",      80)),   20, 200)
	_font_size        = clampi(int(_entry_value(cfg, "Int",   "font_size",        12)),    8,  24)
	_passive_enabled  = bool(_entry_value(cfg, "Bool",  "passive_enabled",  true))
	_toast_duration   = clampf(float(_entry_value(cfg, "Float", "toast_duration",   8.0)), 3.0, 30.0)
	_network_enabled  = bool(_entry_value(cfg, "Bool",  "network_enabled",  true))
	_auto_connect     = bool(_entry_value(cfg, "Bool",  "auto_connect",     false))
	_ephemeral_identity = bool(_entry_value(cfg, "Bool", "ephemeral_identity", true))
	_connect_on_open  = bool(_entry_value(cfg, "Bool",  "connect_on_open",  true))
	_stealth_closed   = bool(_entry_value(cfg, "Bool",  "stealth_when_closed", false))
	_suppress_jl      = bool(_entry_value(cfg, "Bool",  "suppress_join_leave", false))
	_afk_enabled      = bool(_entry_value(cfg, "Bool",  "afk_disconnect_enabled", true))
	_afk_timeout_s    = float(clampi(int(_entry_value(cfg, "Int", "afk_timeout_min", 15)), 1, 120)) * 60.0
	_bg_enabled       = bool(_entry_value(cfg, "Bool",  "bg_sync_enabled",  false))
	_bg_interval_s    = float(int(_entry_value(cfg, "Int", "bg_sync_interval_min", 5))) * 60.0
	_bg_window_s      = float(int(_entry_value(cfg, "Int", "bg_sync_window_sec",   15)))
	_bg_silent        = bool(_entry_value(cfg, "Bool",  "bg_sync_silent",   true))
	_bg_toasts        = bool(_entry_value(cfg, "Bool",  "bg_sync_toasts",   false))
	_filter_in        = bool(_entry_value(cfg, "Bool",  "filter_incoming_profanity", true))
	_filter_out       = bool(_entry_value(cfg, "Bool",  "filter_outgoing_profanity", false))
	_strip_urls       = bool(_entry_value(cfg, "Bool",  "strip_urls",       true))
	_block_pii_out    = bool(_entry_value(cfg, "Bool",  "block_pii_outgoing", true))
	_send_cooldown    = clampf(float(_entry_value(cfg, "Float", "send_cooldown",    1.0)), 0.0, 10.0)

	var extra_str : String = String(_entry_value(cfg, "String", "extra_blocked_terms", ""))
	_extra_terms = []
	for piece in extra_str.split(","):
		var t : String = String(piece).strip_edges().to_lower()
		if t != "":
			_extra_terms.append(t)

	# Toggle key: MCM stores it under section "Keycode". Across MCM versions
	# this has been seen as a Dictionary (with .value), a raw int, or even a
	# stringified int. Accept all three so a single MCM regression doesn't
	# brick the toggle key.
	var kc_entry = cfg.get_value("Keycode", "safe_relay_chat_toggle", null)
	var parsed_kc := -1
	match typeof(kc_entry):
		TYPE_DICTIONARY:
			var v = kc_entry.get("value", kc_entry.get("default", -1))
			if typeof(v) == TYPE_INT:
				parsed_kc = v
			elif typeof(v) == TYPE_FLOAT:
				parsed_kc = int(v)
			elif typeof(v) == TYPE_STRING and v.is_valid_int():
				parsed_kc = int(v)
		TYPE_INT:
			parsed_kc = kc_entry
		TYPE_FLOAT:
			parsed_kc = int(kc_entry)
		TYPE_STRING:
			if kc_entry.is_valid_int():
				parsed_kc = int(kc_entry)
	if parsed_kc > 0:
		_toggle_keycode = parsed_kc
		print("[SafeRelayChat] toggle keycode loaded from MCM: %d (%s)" % [
			parsed_kc, OS.get_keycode_string(parsed_kc)])
	else:
		print("[SafeRelayChat] toggle keycode not set in MCM (got %s), using default %d (%s)" % [
			str(kc_entry), _toggle_keycode, OS.get_keycode_string(_toggle_keycode)])
	_apply_toggle_key()

	# Auto-broadcast.
	_ab_enabled     = bool(_entry_value(cfg, "Bool",   "autobroadcast_enabled",  false))
	_ab_chance      = clampi(int(_entry_value(cfg, "Int", "autobroadcast_chance", 30)), 0, 100)
	_ab_cooldown    = clampf(float(_entry_value(cfg, "Float", "autobroadcast_cooldown", 45.0)), 5.0, 600.0)
	_tpl_shelter    = String(_entry_value(cfg, "String", "tpl_shelter_enter",
		"Back at the shelter on {map}, restocking."))
	_tpl_trader     = String(_entry_value(cfg, "String", "tpl_trader",
		"Shopping at a trader on {map}."))
	_tpl_map        = String(_entry_value(cfg, "String", "tpl_map_change",
		"Made it to {map}."))
	_tpl_hunted     = String(_entry_value(cfg, "String", "tpl_hunted",
		"Pinned down on {map}, AI are hunting me."))
	_tpl_combat_end = String(_entry_value(cfg, "String", "tpl_combat_end",
		"Clear on {map}. That was close."))

	# Metadata privacy.
	_meta_pad     = bool(_entry_value(cfg, "Bool",  "metadata_padding", true))
	_meta_jitter  = clampf(float(_entry_value(cfg, "Float", "metadata_jitter", 0.3)), 0.0, 3.0)

	# Tripwire.
	_tw_enabled     = bool(_entry_value(cfg, "Bool",  "tripwire_enabled", true))
	_tw_link_thresh = clampi(int(_entry_value(cfg, "Int", "tripwire_link_threshold", 5)), 1, 50)
	_tw_lockout     = clampf(float(_entry_value(cfg, "Float", "tripwire_lockout", 300.0)), 0.0, 86400.0)

	# Mod Event Hooks -- override registry enabled/template from MCM (per slug).
	for slug in _event_registry.keys():
		var slug_str : String = String(slug)
		var entry : Dictionary = _event_registry[slug_str]
		var en_key : String = "event_enabled__" + slug_str
		var tp_key : String = "event_tpl__" + slug_str
		entry["enabled"]  = bool(_entry_value(cfg, "Bool",   en_key, entry.get("enabled", false)))
		var tpl_override := String(_entry_value(cfg, "String", tp_key, entry.get("template", "")))
		if tpl_override != "":
			entry["template"] = tpl_override
		_event_registry[slug] = entry

func apply_mcm_config(cfg: ConfigFile) -> void:
	var old_url := _relay_url
	var old_eph := _ephemeral_identity
	var old_coo := _connect_on_open
	var old_net := _network_enabled
	_apply_config_file(cfg)

	if is_instance_valid(_chat_panel):
		_chat_panel.modulate.a = _opacity
	if is_instance_valid(_hint_label):
		_update_hint_text()
	_refresh_font_sizes()

	# Master kill-switch flipped OFF: kill EVERYTHING network-side immediately.
	if old_net and not _network_enabled:
		_add_local_message("* Mod network DISABLED -- closing all sockets.",
			Color(1, 0.6, 0.4))
		if _bg_active:
			_bg_end_window(false)
		if _connected:
			_close_disconnect()
		else:
			_disconnect_socket()
		_reconnect_timer = 0.0

	if _relay_url != old_url:
		_add_local_message("* Relay URL changed -- reconnecting...", Color(0.8, 0.8, 0.4))
		_disconnect_socket()
		if _has_privacy_ack() and _auto_connect and not _connect_on_open:
			_reconnect_timer = RECONNECT_DELAY

	# Connect-on-open mode toggled: reconcile current socket state with mode.
	if _connect_on_open != old_coo:
		if _connect_on_open and not _open and _connected:
			# Just enabled the mode and chat isn't open -- drop the socket.
			_close_disconnect()
		elif not _connect_on_open and _open and not _connected and _has_privacy_ack():
			# Just disabled the mode while chat is open -- reconnect normally.
			_connect_socket()

	if _ephemeral_identity != old_eph:
		_resolve_username()

	_add_local_message("* Settings updated.", Color(0.5, 1.0, 0.6))

func _refresh_font_sizes() -> void:
	if not is_instance_valid(_message_list):
		return
	for child in _message_list.get_children():
		if child is RichTextLabel:
			(child as RichTextLabel).add_theme_font_size_override("normal_font_size", _font_size)

# ---- TLS-only URL guard -----------------------------------------------------
func _is_safe_url(url: String) -> bool:
	if not url.begins_with("wss://"):
		return false
	# Reject explicit IP literals -- force a hostname so cert validation runs.
	var host_part := url.substr(6)
	var slash := host_part.find("/")
	if slash != -1:
		host_part = host_part.substr(0, slash)
	# Strip port for the IP check.
	var colon := host_part.find(":")
	if colon != -1:
		host_part = host_part.substr(0, colon)
	# Basic IPv4 literal detection.
	var re := RegEx.new()
	re.compile("^\\d+\\.\\d+\\.\\d+\\.\\d+$")
	if re.search(host_part) != null:
		return false
	return true

# ---- Username ---------------------------------------------------------------
func _resolve_username() -> void:
	if _ephemeral_identity:
		# Fresh anonymous handle every boot; never written to disk.
		_username = _generate_username()
		return
	# Persistent path: load if present, else generate + save.
	if _username.strip_edges() != "":
		return
	var cfg := ConfigFile.new()
	if cfg.load(PERSISTENT_NAME_PATH) == OK:
		var n : String = cfg.get_value("chat", "username", "")
		var v := Filters.validate_username(n, _extra_terms)
		if v != "":
			_username = v
			return
	_username = _generate_username()
	_save_username(_username)

func _generate_username() -> String:
	var adj  := ["Lost", "Quiet", "Grim", "Weary", "Bold", "Lone", "Iron", "Gray", "Faded", "Hush"]
	var noun := ["Stalker", "Drifter", "Ghost", "Runner", "Scout", "Trader", "Ranger", "Wanderer"]
	var rng  := RandomNumberGenerator.new()
	rng.randomize()
	return adj[rng.randi() % adj.size()] + noun[rng.randi() % noun.size()] + str(rng.randi_range(10, 99))

func _save_username(name: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("chat", "username", name)
	cfg.save(PERSISTENT_NAME_PATH)

# ---- Privacy notice ---------------------------------------------------------
func _has_privacy_ack() -> bool:
	return FileAccess.file_exists(PRIVACY_ACK_PATH)

func _set_privacy_ack() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("privacy", "acknowledged", true)
	cfg.set_value("privacy", "version", 1)
	cfg.save(PRIVACY_ACK_PATH)

func _show_privacy_notice() -> void:
	# Wait one frame so the canvas is added.
	await get_tree().process_frame
	if not is_instance_valid(_root_control):
		return
	var overlay := ColorRect.new()
	overlay.name = "SafeRelayPrivacyNotice"
	overlay.color = Color(0.0, 0.0, 0.0, 0.78)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 250
	_root_control.add_child(overlay)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(620, 0)
	panel.position -= Vector2(310, 180)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.08, 1.0)
	sb.border_color = Color(0.4, 0.55, 0.7, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	overlay.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "SAFE RELAY CHAT - PRIVACY NOTICE"
	title.add_theme_font_size_override("font_size", 20)
	title.modulate = Color(0.85, 0.95, 1.0)
	vb.add_child(title)
	var msg := RichTextLabel.new()
	msg.fit_content = true
	msg.bbcode_enabled = true
	msg.custom_minimum_size = Vector2(560, 320)
	msg.text = (
		"[b]What gets sent:[/b]\n" +
		"  - Your chosen (or random) display name\n" +
		"  - The text of messages you type and submit\n" +
		"  - Join/leave events\n\n" +
		"[b]What can be observed by the relay operator and Cloudflare:[/b]\n" +
		"  - Your [color=#ffaaaa]public IP address[/color] (unavoidable for any direct connection)\n" +
		"  - Connection timestamps and message contents\n\n" +
		"[b]This mod CANNOT hide your IP from the server.[/b] No mod can. " +
		"If you need IP privacy, route the game through a system VPN or Tor.\n\n" +
		"[b]Mitigations active in this mod:[/b]\n" +
		"  - TLS-only (wss://) enforced\n" +
		"  - No game state, position, inventory, or save data is sent\n" +
		"  - Ephemeral random username by default (no persistent ID on disk)\n" +
		"  - Profanity / URL / PII filters and a local block list\n" +
		"  - Rate limiting on outgoing messages\n\n" +
		"By clicking [b]Accept[/b] you acknowledge the above and allow the mod to connect."
	)
	vb.add_child(msg)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_END
	hb.add_theme_constant_override("separation", 12)
	vb.add_child(hb)
	var decline := Button.new()
	decline.text = "Stay Offline"
	decline.custom_minimum_size = Vector2(140, 36)
	decline.pressed.connect(func():
		overlay.queue_free()
		_set_status("Offline -- privacy notice declined."))
	hb.add_child(decline)
	var accept := Button.new()
	accept.text = "Accept and Connect"
	accept.custom_minimum_size = Vector2(180, 36)
	accept.pressed.connect(func():
		_set_privacy_ack()
		overlay.queue_free()
		if _auto_connect:
			_connect_socket())
	hb.add_child(accept)

# ---- Block list -------------------------------------------------------------
func _load_blocklist() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(BLOCKLIST_PATH) != OK:
		return
	var arr = cfg.get_value("block", "names", [])
	if arr is Array:
		for n in arr:
			_blocklist[String(n).to_lower()] = true

func _save_blocklist() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("block", "names", _blocklist.keys())
	cfg.save(BLOCKLIST_PATH)

func _is_blocked(name: String) -> bool:
	return _blocklist.has(name.strip_edges().to_lower())

# ---- WebSocket --------------------------------------------------------------
func _connect_socket() -> void:
	if not _network_enabled:
		_set_status("Mod network disabled in MCM. No connection will be made.")
		return
	if _tw_tripped and _is_lockout_active():
		_set_status("LOCKED OUT by tripwire (%s). Use /reset to clear." % _tw_reason)
		return
	if not _is_safe_url(_relay_url):
		_set_status("Refusing unsafe URL (must be wss:// to a hostname).")
		return
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_relay_url)
	if err != OK:
		_set_status("Connection failed (err %d). Retry in %.0fs..." % [err, RECONNECT_DELAY])
		_connected = false
	else:
		_set_status("Connecting...")

func _disconnect_socket() -> void:
	if _socket:
		_socket.close()
	_connected = false

func _send_raw(data: Dictionary) -> void:
	if not _connected:
		return
	# Metadata privacy: add a random pad field of varying length so that
	# packet sizes do not directly leak message length to a passive observer.
	# This does NOT hide your IP -- nothing client-side can.
	if _meta_pad:
		var pad_len := (randi() % 48) + 16  # 16..63 chars
		var chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
		var pad := ""
		for i in range(pad_len):
			pad += chars[randi() % chars.length()]
		# Underscore prefix marks it as a discard field; the server forwards
		# the whole JSON object as-is, but our incoming handler ignores any
		# field not in {type, username, text}.
		data["_p"] = pad
	# Send with optional jitter. We schedule a one-shot timer so we don't
	# block the calling frame.
	if _meta_jitter > 0.0:
		var delay := randf() * _meta_jitter
		var sock := _socket
		get_tree().create_timer(delay).timeout.connect(func():
			if is_instance_valid(self) and _connected and sock == _socket:
				_socket.send_text(JSON.stringify(data)))
		return
	_socket.send_text(JSON.stringify(data))

func _send_chat(text: String) -> void:
	text = Filters.sanitize_unicode(text.strip_edges(), MAX_OUTGOING_TEXT)
	if text == "":
		return
	if text.begins_with("/"):
		_handle_command(text)
		return
	# Rate limit.
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_send_t < _send_cooldown:
		_add_local_message("* Slow down -- wait %.1fs." % (_send_cooldown - (now - _last_send_t)),
			Color(1, 0.6, 0.4))
		return
	# PII guard.
	if _block_pii_out and Filters.contains_pii(text):
		_add_local_message("* Message blocked: looks like it contains an IP/email/phone.",
			Color(1, 0.4, 0.4))
		return
	# STRICT: refuse to send messages containing links / paths / commands.
	# Same detector used on incoming -- keeps both sides clean.
	if Filters.contains_link_or_path(text):
		_add_local_message("* Message blocked: links, file paths, and shell commands are not allowed.",
			Color(1, 0.4, 0.4))
		return
	# Outgoing profanity guard.
	if _filter_out:
		var scan := Filters.profanity_scan(text, _extra_terms)
		if scan.get("blocked", false):
			_add_local_message("* Message blocked by outgoing filter.",
				Color(1, 0.4, 0.4))
			return
	if not _connected:
		_add_local_message("* Not connected. Type /connect first.",
			Color(1, 0.6, 0.4))
		return
	if _stealth_closed and not _open:
		_add_local_message("* Stealth mode: outgoing messages muted while chat is closed.",
			Color(1, 0.7, 0.4))
		return
	_last_send_t = now
	_send_raw({"type": "chat", "username": _username, "text": text.left(MAX_OUTGOING_TEXT)})

func _handle_command(text: String) -> void:
	if text == "/connect":
		if not _network_enabled:
			_add_local_message("* Mod network is DISABLED in MCM. Enable it to connect.",
				Color(1, 0.4, 0.4))
			return
		if _connected:
			_add_local_message("* Already connected.", Color(0.7, 0.9, 1.0))
		else:
			if not _has_privacy_ack():
				_show_privacy_notice()
				return
			_connect_socket()
		return
	if text == "/disconnect":
		_disconnect_socket()
		_add_local_message("* Disconnected.", Color(0.8, 0.8, 0.4))
		return
	if text.begins_with("/name "):
		var new_name := text.substr(6).strip_edges()
		var valid := Filters.validate_username(new_name, _extra_terms)
		if valid == "":
			_add_local_message("* Invalid name. 2-24 ASCII chars, no profanity.",
				Color(1, 0.4, 0.4))
			return
		_username = valid
		if not _ephemeral_identity:
			_save_username(_username)
		_add_local_message("* Name changed to %s." % _username, Color(0.8, 0.8, 0.4))
		return
	if text.begins_with("/block "):
		var who := text.substr(7).strip_edges().to_lower()
		if who == "":
			return
		_blocklist[who] = true
		_save_blocklist()
		_add_local_message("* Blocked: %s" % who, Color(0.8, 0.8, 0.4))
		return
	if text.begins_with("/unblock "):
		var who := text.substr(9).strip_edges().to_lower()
		if _blocklist.erase(who):
			_save_blocklist()
			_add_local_message("* Unblocked: %s" % who, Color(0.6, 1.0, 0.6))
		else:
			_add_local_message("* %s was not blocked." % who, Color(0.7, 0.7, 0.7))
		return
	if text == "/blocks":
		if _blocklist.is_empty():
			_add_local_message("* No blocked names.", Color(0.7, 0.9, 1.0))
		else:
			_add_local_message("* Blocked: " + ", ".join(_blocklist.keys()),
				Color(0.7, 0.9, 1.0))
		return
	if text == "/log":
		if _log == null:
			return
		var tail : Array = _log.tail(15)
		if tail.is_empty():
			_add_local_message("* Log is empty.", Color(0.7, 0.9, 1.0))
		else:
			_add_local_message("* Last %d incoming events:" % tail.size(), Color(0.7, 0.9, 1.0))
			for e in tail:
				_add_local_message(
					"  [%s] %s/%s : %s (fp=%s)" % [
						String(e.get("action", "?")),
						String(e.get("type", "?")),
						String(e.get("name", "?")),
						String(e.get("text", "")),
						String(e.get("fp", "")),
					],
					Color(0.75, 0.85, 0.95))
		return
	if text.begins_with("/report "):
		if _log == null:
			return
		var target := text.substr(8).strip_edges()
		if target == "":
			return
		var path : String = _log.export_report_for(target)
		if path == "":
			_add_local_message("* No log entries found for %s." % target,
				Color(1, 0.6, 0.4))
		else:
			_add_local_message("* Report written: %s" % path, Color(0.6, 1, 0.6))
			_add_local_message("  Forward this file to the relay operator for an IP ban.",
				Color(0.7, 0.9, 1.0))
		return
	if text == "/purgelog":
		if _log != null:
			_log.purge()
			_add_local_message("* Log purged.", Color(0.8, 0.8, 0.4))
		return
	if text == "/reset":
		if not _tw_tripped:
			_add_local_message("* Tripwire is not active.", Color(0.7, 0.9, 1.0))
		else:
			_tw_tripped = false
			_tw_reason = ""
			_tw_link_count = 0
			_tw_bad_json = 0
			_add_local_message("* Tripwire cleared. You may /connect again.",
				Color(0.6, 1, 0.6))
		return
	if text == "/syncnow":
		if not _bg_enabled:
			_add_local_message("* Background Sync is disabled in MCM.", Color(1, 0.6, 0.4))
			return
		if _open:
			_add_local_message("* Already in an open chat session.", Color(0.7, 0.9, 1.0))
			return
		if _connected or _bg_active:
			_add_local_message("* Sync already in progress.", Color(0.7, 0.9, 1.0))
			return
		_bg_next_sync_t = 0.0
		_add_local_message("* Forcing background sync now.", Color(0.6, 1, 0.6))
		return
	if text == "/help":
		_add_local_message(
			"Commands: /connect | /disconnect | /name NEW | /block NAME | /unblock NAME | /blocks | /log | /report NAME | /purgelog | /reset | /syncnow | /status | /listevents | /afk on|off",
			Color(0.7, 0.9, 1.0))
		return
	if text.begins_with("/afk"):
		var arg := text.substr(4).strip_edges().to_lower()
		if arg == "on":
			_afk_enabled = true
			_bump_activity()
			_add_local_message("* AFK auto-disconnect: ON (%d min)." % int(round(_afk_timeout_s / 60.0)),
				Color(0.6, 1, 0.6))
		elif arg == "off":
			_afk_enabled = false
			_add_local_message("* AFK auto-disconnect: OFF.", Color(0.8, 0.8, 0.4))
		else:
			var on_off := "ON" if _afk_enabled else "OFF"
			_add_local_message("* AFK: %s, timeout %d min." % [on_off, int(round(_afk_timeout_s / 60.0))],
				Color(0.7, 0.9, 1.0))
		return
	if text == "/listevents":
		if _event_registry.is_empty():
			_add_local_message("* No mod events registered. Mods register them via the SafeRelayChat API.", Color(0.7, 0.9, 1.0))
		else:
			_add_local_message("* Registered mod events (%d):" % _event_registry.size(), Color(0.7, 0.9, 1.0))
			for slug in _event_registry.keys():
				var e : Dictionary = _event_registry[slug]
				var on_off := "ON" if bool(e.get("enabled", false)) else "off"
				_add_local_message("    [%s] %s.%s  (%s)" % [on_off, e.get("source",""), e.get("category",""), slug],
					Color(0.7, 0.9, 1.0))
		return
	if text == "/status":
		var mode_str := ""
		if _connect_on_open:
			mode_str = " | mode: open-only"
		elif _auto_connect:
			mode_str = " | mode: auto"
		else:
			mode_str = " | mode: manual"
		var trip_str := ""
		if _tw_tripped:
			trip_str = " | TRIPPED: %s" % _tw_reason
		var sync_str := ""
		if _bg_enabled:
			if _bg_active:
				sync_str = " | sync: ACTIVE %.0fs left, %d msg" % [_bg_window_left, _bg_collected]
			else:
				sync_str = " | sync: idle, next in %.0fs (total %d msg)" % [
					max(0.0, _bg_next_sync_t), _bg_total_synced]
		var afk_str := ""
		if _afk_enabled and (_connected or _bg_active or _open):
			var idle : float = (Time.get_ticks_msec() / 1000.0) - _afk_last_activity
			var left : int = max(0, int(round(_afk_timeout_s - idle)))
			afk_str = " | afk-in: %d:%02d" % [left / 60, left % 60]
		_add_local_message("Server: %s | User: %s | %s%s%s%s%s%s" % [
			_relay_url, _username,
			"Connected" if _connected else ("Disconnected" if _network_enabled else "OFFLINE (network disabled)"),
			" (ephemeral)" if _ephemeral_identity else "",
			mode_str, trip_str, sync_str, afk_str,
		], Color(0.7, 0.9, 1.0))
		return
	_add_local_message("* Unknown command. Try /help.", Color(1, 0.6, 0.4))

# ---- _process ---------------------------------------------------------------
func _process(delta: float) -> void:
	# Event auto-broadcaster runs even when the socket is not yet connected
	# so that we can correctly track edges for the FIRST connection too.
	if _ab_enabled and _game_data != null:
		_ab_scan_timer += delta
		if _ab_scan_timer >= 2.0:
			_ab_scan_timer = 0.0
			_scan_events()

	_tick_background_sync(delta)
	_tick_afk(delta)

	if not _socket:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				_reconnect_timer = 0.0
				if _bg_active and _bg_silent:
					_set_status("Background sync: connected (silent, %.0fs)" % _bg_window_left)
				elif _stealth_closed and not _open:
					_set_status("Connected as %s (stealth)" % _username)
				else:
					_set_status("Connected as %s" % _username)
					if not _suppress_jl:
						_send_raw({"type": "join", "username": _username})
			_drain_packets()
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_set_status("Disconnected. Retry in %.0fs..." % RECONNECT_DELAY)
			_reconnect_timer += delta
			if _reconnect_timer >= RECONNECT_DELAY and _auto_connect and _has_privacy_ack() \
				and _network_enabled \
				and not _connect_on_open \
				and not (_tw_tripped and _is_lockout_active()):
				_reconnect_timer = 0.0
				_connect_socket()
		_:
			pass

func _drain_packets() -> void:
	while _socket.get_available_packet_count() > 0:
		var raw := _socket.get_packet().get_string_from_utf8()
		# Hard cap on packet size to keep parsing cheap.
		if raw.length() > 8192:
			# Oversized packet from a chat relay is never legitimate.
			_trip("oversized_packet (%d bytes)" % raw.length())
			return
		var parsed = JSON.parse_string(raw)
		if typeof(parsed) == TYPE_DICTIONARY:
			_tw_bad_json = 0  # good packet resets the bad-JSON counter
			_handle_incoming(parsed)
		else:
			# Track malformed-JSON spam -- 20 bad packets in 10s == tripwire.
			var now := Time.get_ticks_msec() / 1000.0
			if now - _tw_bad_json_t > 10.0:
				_tw_bad_json = 0
			_tw_bad_json_t = now
			_tw_bad_json += 1
			if _tw_bad_json >= 20:
				_trip("malformed_json_flood")
				return

func _handle_incoming(msg: Dictionary) -> void:
	# ---- Tripwire: scan raw payload for code-execution attempts BEFORE any
	# other handling. If found, drop the socket and lock out reconnects.
	if _tw_enabled:
		var trip_reason := _scan_payload_for_exec(msg)
		if trip_reason != "":
			_trip(trip_reason)
			return
	# Whitelist protocol types -- anything else is dropped silently.
	var t := String(msg.get("type", ""))
	if not (t in ["chat", "join", "leave", "server"]):
		if _tw_enabled:
			# Unknown protocol type from a frozen-spec relay is suspicious.
			# Count it the same as a link-burst event.
			_tw_bump_link_burst("unknown_type:%s" % t)
		return
	var raw_user := String(msg.get("username", "???"))
	var name_clean := Filters.sanitize_unicode(raw_user, 32)
	if Filters.validate_username(name_clean, _extra_terms) == "":
		name_clean = "anon"

	# Local user block applies to all message types; recorded as blocked.
	if _is_blocked(name_clean):
		if _log != null:
			_log.append(msg, name_clean, "", "blocked:user")
		return

	match t:
		"chat":
			var raw_text := String(msg.get("text", ""))
			var text := Filters.sanitize_unicode(raw_text, MAX_INCOMING_TEXT)
			# STRICT: drop the entire message if any link, file path, IP literal,
			# or shell-command pattern is detected (after de-obfuscation).
			if Filters.contains_link_or_path(text):
				if _log != null:
					_log.append(msg, name_clean, text, "dropped:link_or_command")
				_add_local_message("* Dropped message from %s (link/command)." % name_clean,
					Color(0.85, 0.5, 0.5))
				if _tw_enabled:
					_tw_bump_link_burst("chat_link_burst")
				return
			if _filter_in:
				var scan := Filters.profanity_scan(text, _extra_terms)
				text = scan.get("clean", text)
			if _log != null:
				_log.append(msg, name_clean, text, "delivered")
			_add_chat_message(name_clean, text)
		"join":
			if _log != null:
				_log.append(msg, name_clean, "", "event:join")
			if _show_join_leave:
				_add_local_message(">> %s joined." % name_clean, Color(0.5, 1.0, 0.6))
		"leave":
			if _log != null:
				_log.append(msg, name_clean, "", "event:leave")
			if _show_join_leave:
				_add_local_message("<< %s left." % name_clean, Color(1.0, 0.6, 0.5))
		"server":
			var stext := Filters.sanitize_unicode(String(msg.get("text", "")), MAX_INCOMING_TEXT)
			if Filters.contains_link_or_path(stext):
				if _log != null:
					_log.append(msg, name_clean, stext, "dropped:link_or_command")
				if _tw_enabled:
					_tw_bump_link_burst("server_link_burst")
				return
			if _filter_in:
				stext = Filters.profanity_scan(stext, _extra_terms).get("clean", stext)
			if _log != null:
				_log.append(msg, name_clean, stext, "delivered")
			_add_local_message("[SERVER] " + stext, Color(1.0, 0.9, 0.3))

# ---- UI ---------------------------------------------------------------------
func _build_ui() -> void:
	_canvas = CanvasLayer.new()
	_canvas.name = "SafeRelayChatLayer"
	# High layer so we sit on top of RTV's HUD/pause menus. The MCM lives at
	# layer 1000-ish; we stay just below to avoid covering it. If you ever
	# can't see the chat in-game, suspect a higher CanvasLayer somewhere.
	_canvas.layer = 900
	get_tree().root.call_deferred("add_child", _canvas)

	_root_control = Control.new()
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.name = "SafeRelayChatRoot"
	_root_control.process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas.call_deferred("add_child", _root_control)

	_build_chat_panel()
	_build_toast_container()
	_build_hint_label()

func _build_chat_panel() -> void:
	_chat_panel = PanelContainer.new()
	_chat_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	_chat_panel.set_anchor(SIDE_LEFT,   0.0)
	_chat_panel.set_anchor(SIDE_TOP,    0.45)
	_chat_panel.set_anchor(SIDE_RIGHT,  0.36)
	_chat_panel.set_anchor(SIDE_BOTTOM, 1.0)
	_chat_panel.set_offset(SIDE_LEFT,   12)
	_chat_panel.set_offset(SIDE_TOP,    0)
	_chat_panel.set_offset(SIDE_RIGHT,  -12)
	_chat_panel.set_offset(SIDE_BOTTOM, -120)
	_chat_panel.modulate     = Color(1, 1, 1, _opacity)
	_chat_panel.visible      = false
	_chat_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.add_child(_chat_panel)

	var style := StyleBoxFlat.new()
	style.bg_color            = Color(0.05, 0.05, 0.05, 0.82)
	style.border_color        = Color(0.25, 0.25, 0.25, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left   = 8
	style.content_margin_right  = 8
	style.content_margin_top    = 6
	style.content_margin_bottom = 6
	_chat_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_chat_panel.add_child(vbox)

	# Header row: status label on the left, [X] close button on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	_status_label = Label.new()
	_status_label.text = "Safe Relay Chat"
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.modulate = Color(0.6, 0.85, 1.0)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_status_label)

	var close_btn := Button.new()
	close_btn.process_mode = Node.PROCESS_MODE_ALWAYS
	close_btn.text = "X"
	close_btn.tooltip_text = "Close chat and disconnect from relay."
	close_btn.custom_minimum_size = Vector2(24, 20)
	close_btn.add_theme_font_size_override("font_size", 11)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(_on_close_button_pressed)
	header.add_child(close_btn)

	var sep := HSeparator.new()
	sep.modulate = Color(0.3, 0.3, 0.3, 0.6)
	vbox.add_child(sep)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)

	_message_list = VBoxContainer.new()
	_message_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message_list.add_theme_constant_override("separation", 2)
	_scroll.add_child(_message_list)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	vbox.add_child(hbox)

	_input_box = LineEdit.new()
	_input_box.process_mode = Node.PROCESS_MODE_ALWAYS
	_input_box.placeholder_text = "Message... (/help)"
	_input_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_box.max_length = MAX_OUTGOING_TEXT
	_input_box.text_submitted.connect(_on_text_submitted)
	_input_box.gui_input.connect(_on_input_box_gui_input)
	hbox.add_child(_input_box)

	var send_btn := Button.new()
	send_btn.process_mode = Node.PROCESS_MODE_ALWAYS
	send_btn.text = "Send"
	send_btn.pressed.connect(_on_send_pressed)
	hbox.add_child(send_btn)

func _build_toast_container() -> void:
	_toast_container = VBoxContainer.new()
	_toast_container.set_anchor(SIDE_LEFT,   0.0)
	_toast_container.set_anchor(SIDE_TOP,    1.0)
	_toast_container.set_anchor(SIDE_RIGHT,  0.36)
	_toast_container.set_anchor(SIDE_BOTTOM, 1.0)
	_toast_container.set_offset(SIDE_LEFT,   12)
	_toast_container.set_offset(SIDE_TOP,    -420)
	_toast_container.set_offset(SIDE_RIGHT,  -12)
	_toast_container.set_offset(SIDE_BOTTOM, -150)
	_toast_container.alignment = BoxContainer.ALIGNMENT_END
	_toast_container.add_theme_constant_override("separation", 2)
	_toast_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root_control.add_child(_toast_container)

func _build_hint_label() -> void:
	# A clickable button -- the user can ALWAYS open the chat by clicking
	# this, even if their toggle key is hijacked by RTV's input system.
	var btn := Button.new()
	btn.name = "SafeRelayChatHint"
	btn.process_mode = Node.PROCESS_MODE_ALWAYS
	btn.set_anchor(SIDE_LEFT,   0.0)
	btn.set_anchor(SIDE_TOP,    0.0)
	btn.set_anchor(SIDE_RIGHT,  0.0)
	btn.set_anchor(SIDE_BOTTOM, 0.0)
	btn.set_offset(SIDE_LEFT,   14)
	btn.set_offset(SIDE_TOP,    14)
	btn.set_offset(SIDE_RIGHT,  240)
	btn.set_offset(SIDE_BOTTOM, 44)
	btn.focus_mode = Control.FOCUS_NONE  # don't steal keyboard focus
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.add_theme_font_size_override("font_size", 13)
	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = Color(0.05, 0.05, 0.05, 0.65)
	sb_normal.border_color = Color(0.4, 0.6, 0.85, 0.75)
	sb_normal.set_border_width_all(1)
	sb_normal.set_corner_radius_all(3)
	sb_normal.content_margin_left = 10
	sb_normal.content_margin_right = 10
	sb_normal.content_margin_top = 3
	sb_normal.content_margin_bottom = 3
	btn.add_theme_stylebox_override("normal", sb_normal)
	var sb_hover := sb_normal.duplicate() as StyleBoxFlat
	sb_hover.bg_color = Color(0.1, 0.12, 0.18, 0.85)
	btn.add_theme_stylebox_override("hover", sb_hover)
	var sb_press := sb_normal.duplicate() as StyleBoxFlat
	sb_press.bg_color = Color(0.15, 0.2, 0.3, 0.9)
	btn.add_theme_stylebox_override("pressed", sb_press)
	btn.modulate = Color(0.85, 0.95, 1.0, 0.95)
	btn.pressed.connect(func():
		print("[SafeRelayChat] hint button clicked -> opening chat.")
		if not _open:
			_toggle_chat())
	_hint_panel = btn
	_hint_label = btn  # the button itself shows the text
	_root_control.add_child(btn)
	_update_hint_text()

func _update_hint_text() -> void:
	var key_str := OS.get_keycode_string(_toggle_keycode)
	if key_str == "":
		key_str = "?"
	var emer := OS.get_keycode_string(EMERGENCY_TOGGLE_KEY)
	if _hint_label:
		# Display works for both Label (old) and Button (new) via .text.
		# Show the emergency key alongside the configured key so the player
		# always has a guaranteed-working fallback.
		var txt : String
		if _toggle_keycode == EMERGENCY_TOGGLE_KEY:
			txt = "[%s] Safe Relay Chat (click)" % key_str
		else:
			txt = "[%s / %s] Safe Relay Chat (click)" % [key_str, emer]
		_hint_label.text = txt

# ---- Message handling -------------------------------------------------------
# Network text path: JSON -> sanitize_unicode -> _scrub_text -> RichTextLabel.text.
# _scrub_text replaces `[` and `]` with fullwidth lookalikes so no BBCode tag
# can form from network content. The only real BBCode tags in the rendered
# string come from the mod's own format template.

func _add_chat_message(username: String, text: String) -> void:
	var u := _scrub_text(username)
	var t := _scrub_text(text)
	if _bg_active:
		_bg_collected += 1
	var bbcode := "[color=#d4c97a][b]%s[/b][/color][color=#cccccc]: %s[/color]" % [u, t]
	_attach_label(bbcode, Color.WHITE)
	_api_dispatch_chat(u, t)

func _add_local_message(text: String, color: Color = Color.WHITE) -> void:
	_attach_label(_scrub_text(text), color)

func _attach_label(bbcode: String, color: Color) -> void:
	var lbl := _make_label(bbcode, color)
	_message_list.add_child(lbl)
	while _message_list.get_child_count() > _max_history:
		_message_list.get_child(0).queue_free()
	if not _open and (_passive_enabled or (_bg_active and _bg_toasts)):
		_spawn_toast(bbcode, color)
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)

func _make_label(bbcode: String, color: Color) -> RichTextLabel:
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content    = true
	lbl.scroll_active  = false
	lbl.autowrap_mode  = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("normal_font_size", _font_size)
	lbl.modulate = color
	lbl.text = bbcode
	# No-op meta handlers: belt-and-suspenders against OS.shell_open via tags.
	lbl.meta_clicked.connect(func(_meta): pass)
	lbl.meta_hover_started.connect(func(_meta): pass)
	return lbl

# Strip C0/C1 controls (except \n,\t), zero-width, bidi overrides, BOM.
# Brackets replaced with fullwidth lookalikes so no BBCode tag can form.
const _DANGEROUS_CODEPOINTS := [
	0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
	0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
	0x2060, 0xFEFF,
]

func _scrub_text(s: String) -> String:
	if s == "":
		return ""
	var out := ""
	for i in range(min(s.length(), MAX_INCOMING_TEXT)):
		var cp : int = s.unicode_at(i)
		if cp < 0x20 and cp != 0x0A and cp != 0x09:
			continue
		if cp >= 0x7F and cp <= 0x9F:
			continue
		if cp in _DANGEROUS_CODEPOINTS:
			continue
		if cp == 0x5B:
			out += "\uFF3B"
			continue
		if cp == 0x5D:
			out += "\uFF3D"
			continue
		out += String.chr(cp)
	return out

func _safe_bb(s: String) -> String:
	return _scrub_text(s)

# ---- Toasts -----------------------------------------------------------------
func _spawn_toast(bbcode: String, color: Color) -> void:
	if not is_instance_valid(_toast_container):
		return
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color            = Color(0.05, 0.05, 0.05, 0.72)
	style.set_corner_radius_all(3)
	style.content_margin_left   = 6
	style.content_margin_right  = 6
	style.content_margin_top    = 3
	style.content_margin_bottom = 3
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(_make_label(bbcode, color))
	_toast_container.add_child(panel)
	while _toast_container.get_child_count() > MAX_TOASTS:
		_toast_container.get_child(0).queue_free()
	var tween := create_tween()
	tween.tween_interval(_toast_duration)
	tween.tween_property(panel, "modulate:a", 0.0, TOAST_FADE_TIME)
	tween.tween_callback(panel.queue_free)

func _clear_toasts() -> void:
	if not is_instance_valid(_toast_container):
		return
	for child in _toast_container.get_children():
		child.queue_free()

func _set_status(text: String) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = text

# ---- Toggle (with game integration) -----------------------------------------
func _toggle_chat() -> void:
	# Defensive: refuse to toggle if the UI isn't built yet. This can happen
	# if a hotkey fires on the same frame as _ready (call_deferred mount).
	if not is_instance_valid(_chat_panel) or not is_instance_valid(_root_control):
		print("[SafeRelayChat] toggle aborted -- UI not built yet (chat_panel=%s root=%s)" % [
			is_instance_valid(_chat_panel), is_instance_valid(_root_control)])
		return
	if _chat_panel.get_parent() == null:
		print("[SafeRelayChat] toggle aborted -- chat panel not in tree yet.")
		return
	_open = not _open
	print("[SafeRelayChat] toggle -> _open=%s, panel.visible=%s, canvas.layer=%d" % [
		_open, _chat_panel.visible, (_canvas.layer if is_instance_valid(_canvas) else -1)])
	if _open:
		if _game_data:
			_prev_freeze = _game_data.freeze
			_game_data.freeze = true
		_prev_mouse_mode = Input.get_mouse_mode()
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		_clear_toasts()
		_chat_panel.visible        = true
		_chat_panel.modulate.a     = _opacity
		_chat_panel.mouse_filter   = Control.MOUSE_FILTER_STOP
		_root_control.mouse_filter = Control.MOUSE_FILTER_STOP
		if is_instance_valid(_hint_panel):
			_hint_panel.visible = false
		_input_box.grab_focus()
		# Connect on open: always honored. In stealth, we still want the
		# socket up by the time the user opens, but it likely already is.
		if _connect_on_open or _stealth_closed:
			_open_connect()
	else:
		if _game_data:
			_game_data.freeze = _prev_freeze
		Input.set_mouse_mode(_prev_mouse_mode)
		_chat_panel.visible        = false
		_chat_panel.mouse_filter   = Control.MOUSE_FILTER_IGNORE
		_root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if is_instance_valid(_hint_panel):
			_hint_panel.visible = true
		_input_box.release_focus()
		# Stealth mode overrides connect_on_open -- we KEEP the socket open
		# but go silent (no outgoing). Disconnect only if stealth is OFF and
		# the user opted into connect-on-open behaviour.
		if _connect_on_open and not _stealth_closed:
			_close_disconnect()

# Hard disconnect from any state. Idempotent.
func _kill_switch() -> void:
	var was_connected := _connected or _open
	# End background sync window cleanly if active.
	if _bg_active:
		_bg_end_window(false)
	# Synchronous leave if we have an open socket and broadcasts not suppressed.
	if is_instance_valid(_socket) and not _suppress_jl:
		var st := _socket.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			_socket.send_text(JSON.stringify({"type": "leave", "username": _username}))
	_disconnect_socket()
	# Close the chat window if open.
	if _open:
		_toggle_chat()
	if was_connected:
		_set_status("KILL SWITCH (-) -- disconnected.")
		_add_local_message("* Kill switch: disconnected from relay.", Color(1.0, 0.5, 0.4))
	else:
		_set_status("Kill switch -- already offline.")

# Open the socket on chat-window open. Respects privacy ack + tripwire.
func _open_connect() -> void:
	if not _has_privacy_ack():
		_show_privacy_notice()
		return
	if _tw_tripped and _is_lockout_active():
		_set_status("Locked out by tripwire (%s). /reset to clear." % _tw_reason)
		return
	# Handoff: if a background sync window is currently active, just promote
	# it to a full chat session -- keep the socket, end the sync window, send
	# the join announcement that silent-sync suppressed.
	if _bg_active:
		_bg_end_window(true)
		if _connected and _bg_silent and not _suppress_jl:
			_send_raw({"type": "join", "username": _username})
			_set_status("Connected as %s (handoff)" % _username)
		else:
			_set_status("Connected as %s (handoff, stealth)" % _username)
		return
	if _connected:
		return
	# Re-roll ephemeral identity for each chat session so even the relay
	# operator can't trivially link two sessions of the same player.
	if _ephemeral_identity:
		_username = _generate_username()
	_connect_socket()

# Close the socket on chat-window close. Synchronous 'leave' bypasses jitter.
func _close_disconnect() -> void:
	if _socket != null and _connected and not _suppress_jl:
		# Bypass _send_raw's jitter timer -- if we jittered this, the socket
		# would already be closed by the time the timer fired.
		_socket.send_text(JSON.stringify({
			"type": "leave",
			"username": _username,
		}))
	_disconnect_socket()
	_set_status("Disconnected (chat closed).")

# ---- Background Sync --------------------------------------------------------
# Opens a short socket window once per interval while chat is closed.
func _tick_background_sync(delta: float) -> void:
	if not _network_enabled:
		if _bg_active:
			_bg_end_window(false)
		return
	if not _bg_enabled:
		# Reset timers so re-enabling later doesn't fire instantly.
		if _bg_active:
			_bg_end_window(false)
		return
	if _bg_active:
		_bg_window_left -= delta
		if _bg_window_left <= 0.0:
			_bg_end_window(false)
		return
	# Idle phase: count down until next sync.
	if _open or _connected:
		# Chat is open, or a normal connection is alive -- don't double up.
		# Treat this as "fresh" -- restart the interval timer.
		_bg_next_sync_t = _bg_interval_s
		return
	if not _has_privacy_ack():
		return
	if _tw_tripped and _is_lockout_active():
		return
	if not _is_safe_url(_relay_url):
		return
	_bg_next_sync_t -= delta
	if _bg_next_sync_t > 0.0:
		return
	_bg_start_window()

func _bg_start_window() -> void:
	_bg_active = true
	_bg_window_left = _bg_window_s
	_bg_collected = 0
	# Use a fresh ephemeral name for the sync window too, so the relay
	# operator can't link sync sessions to each other or to chat sessions.
	if _ephemeral_identity:
		_username = _generate_username()
	_connect_socket()
	# Status will be set when STATE_OPEN fires.

func _bg_end_window(handoff: bool) -> void:
	var was_collected := _bg_collected
	_bg_active = false
	_bg_window_left = 0.0
	_bg_next_sync_t = _bg_interval_s
	if handoff:
		# Caller is taking over the socket; do not close it.
		return
	# Send synchronous leave (only if we actually announced ourselves and
	# join/leave broadcasts are not suppressed).
	if _socket != null and _connected and not _bg_silent and not _suppress_jl:
		_socket.send_text(JSON.stringify({
			"type": "leave",
			"username": _username,
		}))
	_disconnect_socket()
	_bg_total_synced += was_collected
	if was_collected > 0:
		_set_status("Background sync done -- %d message(s) collected (total %d)." % [
			was_collected, _bg_total_synced])
	else:
		_set_status("Background sync done -- no new messages.")

# ---- AFK auto-disconnect ----------------------------------------------------
# Disconnects after `_afk_timeout_s` of no input (keyboard, mouse, or chat).
# Only runs while there is something to disconnect (open socket, active sync,
# or chat window open).

func _bump_activity() -> void:
	_afk_last_activity = Time.get_ticks_msec() / 1000.0
	_afk_warned = false

func _check_passive_activity() -> bool:
	var moved := false
	var vp := get_viewport()
	if vp != null:
		var mp : Vector2 = vp.get_mouse_position()
		if mp != _afk_last_mouse_pos:
			_afk_last_mouse_pos = mp
			moved = true
	if Input.is_anything_pressed():
		moved = true
	return moved

func _tick_afk(_delta: float) -> void:
	if not _afk_enabled:
		return
	if not (_connected or _bg_active or _open):
		_bump_activity()
		return
	if _check_passive_activity():
		_bump_activity()
		return
	var now : float = Time.get_ticks_msec() / 1000.0
	var idle : float = now - _afk_last_activity
	if idle >= _afk_timeout_s:
		_afk_disconnect()
		return
	if not _afk_warned and idle >= max(_afk_timeout_s - _afk_warn_s, _afk_timeout_s * 0.9):
		_afk_warned = true
		var remaining : int = max(1, int(round(_afk_timeout_s - idle)))
		_add_local_message("* AFK: disconnecting in %ds -- any input cancels." % remaining,
			Color(1.0, 0.75, 0.4))

func _afk_disconnect() -> void:
	_add_local_message("* AFK timeout (%d min). Disconnected from relay." %
		int(round(_afk_timeout_s / 60.0)), Color(1.0, 0.6, 0.4))
	_set_status("AFK -- disconnected.")
	if _bg_active:
		_bg_end_window(false)
	if is_instance_valid(_socket) and _connected and not _suppress_jl:
		var st := _socket.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			_socket.send_text(JSON.stringify({"type": "leave", "username": _username}))
	_disconnect_socket()
	if _open:
		_toggle_chat()
	# Suppress auto-reconnect for one full timeout window so we don't loop.
	_reconnect_timer = -_afk_timeout_s
	_bump_activity()

# ---- Input ------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	# Use _input (not _unhandled_input) so the game's UI/weapon scripts can't
	# swallow our toggle key. Match in THREE ways for maximum reliability:
	#   1. The InputMap action (auto-registered by MCM Keycode entry) -- this
	#      survives the user rebinding without any reload.
	#   2. Direct keycode match on configured MCM key (raw fallback).
	#   3. Hardcoded emergency keys (KEY_HOME open, KEY_MINUS kill).
	if event is InputEventKey:
		var ke := event as InputEventKey
		if not ke.pressed or ke.echo:
			return
		_bump_activity()
		var pk : int = ke.physical_keycode
		var lk : int = ke.keycode

		# Kill switch fires regardless of open/closed state. Hard disconnect.
		if pk == KILL_SWITCH_KEY or lk == KILL_SWITCH_KEY:
			print("[SafeRelayChat] kill-switch (-) pressed -> force disconnect.")
			_kill_switch()
			get_viewport().set_input_as_handled()
			return

		if _open:
			return

		# Action match -- the most robust path. InputMap re-maps automatically
		# when MCM rebinds, so this catches Y, \, or whatever the user set.
		var action_match : bool = InputMap.has_action(TOGGLE_ACTION_NAME) \
			and event.is_action_pressed(TOGGLE_ACTION_NAME)
		if action_match \
			or pk == _toggle_keycode or lk == _toggle_keycode \
			or pk == EMERGENCY_TOGGLE_KEY or lk == EMERGENCY_TOGGLE_KEY:
			if _game_data and _game_data.menu:
				print("[SafeRelayChat] toggle pressed (kc=%d, action=%s) but game menu is active, ignoring." % [pk, action_match])
				return
			print("[SafeRelayChat] toggle pressed (kc=%d, action=%s) -> opening chat." % [pk, action_match])
			_toggle_chat()
			get_viewport().set_input_as_handled()

func _on_input_box_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	_bump_activity()
	var pk : int = event.physical_keycode
	var lk : int = event.keycode
	# Kill switch works even while typing.
	if pk == KILL_SWITCH_KEY or lk == KILL_SWITCH_KEY:
		_input_box.accept_event()
		_kill_switch()
		return
	# IMPORTANT: while the input box has focus, the toggle key types literally
	# (so users can type words like "y", "yes", "thanks", whatever). Only ESC
	# and the kill switch act as panel-control keys here. The [X] button and
	# the toggle key from _input (with _open guard) handle closing.
	if event.keycode == KEY_ESCAPE:
		_input_box.accept_event()
		_toggle_chat()

func _on_text_submitted(text: String) -> void:
	_bump_activity()
	_send_chat(text)
	_input_box.clear()

func _on_send_pressed() -> void:
	_on_text_submitted(_input_box.text)

# Close button [X] in the chat header. Always disconnects, regardless of the
# "connect on open" MCM setting -- this is meant to be a clear user-driven
# exit from the relay.
func _on_close_button_pressed() -> void:
	print("[SafeRelayChat] close button pressed -> disconnect + close.")
	if _bg_active:
		_bg_end_window(false)
	if is_instance_valid(_socket) and not _suppress_jl:
		var st := _socket.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			_socket.send_text(JSON.stringify({"type": "leave", "username": _username}))
	_disconnect_socket()
	if _open:
		_toggle_chat()
	_set_status("Disconnected (close button).")

# ---- Auto-broadcast event tracker -------------------------------------------
func _scan_events() -> void:
	if _game_data == null:
		return
	var map := String(_game_data.currentMap)
	# Map change.
	if _ab_last_map == "":
		_ab_last_map = map
	elif map != "" and map != _ab_last_map:
		_ab_last_map = map
		_try_autobroadcast(_tpl_map, map)
	# Shelter rising edge.
	var in_shelter := bool(_game_data.shelter)
	if in_shelter and not _ab_last_shelter:
		_try_autobroadcast(_tpl_shelter, map)
	_ab_last_shelter = in_shelter
	# Trading rising edge.
	var trading := bool(_game_data.isTrading)
	if trading and not _ab_last_trading:
		_try_autobroadcast(_tpl_trader, map)
	_ab_last_trading = trading
	# Combat / hunted detection.
	var hunted := _detect_hunted()
	var now := Time.get_ticks_msec() / 1000.0
	if hunted:
		_ab_last_combat_t = now
		if not _ab_in_combat:
			_ab_in_combat = true
			_ab_combat_end_pending = true
			_try_autobroadcast(_tpl_hunted, map)
	elif _ab_in_combat and (now - _ab_last_combat_t) > 15.0:
		# 15s of quiet = combat ended.
		_ab_in_combat = false
		if _ab_combat_end_pending:
			_ab_combat_end_pending = false
			_try_autobroadcast(_tpl_combat_end, map)

func _detect_hunted() -> bool:
	# Cheap heuristic A: fresh wound flags.
	if _game_data != null:
		if bool(_game_data.bleeding) or bool(_game_data.fracture) or bool(_game_data.headshot) \
			or bool(_game_data.burn) or bool(_game_data.rupture):
			return true
	# Heuristic B: any AI in scene tree currently in Hunt/Combat/Attack.
	# Capped scan: we only look at the first 64 CharacterBody3D nodes to keep
	# this cheap. State enum: Combat=9, Hunt=10, Attack=11 in RTV's AI.gd.
	var tree := get_tree()
	if tree == null:
		return false
	var checked := 0
	var root := tree.current_scene
	if root == null:
		return false
	for n in root.find_children("*", "CharacterBody3D", true, false):
		checked += 1
		if checked > 64:
			break
		if not "currentState" in n:
			continue
		var st = n.currentState
		if typeof(st) == TYPE_INT and (st == 9 or st == 10 or st == 11):
			return true
	return false

func _try_autobroadcast(template: String, map: String) -> void:
	if not _ab_enabled:
		return
	# Stealth mode: never autobroadcast while the chat window is closed.
	if _stealth_closed and not _open:
		return
	template = template.strip_edges()
	if template == "":
		return
	# Global cooldown floor.
	var now := Time.get_ticks_msec() / 1000.0
	if now - _ab_last_t < _ab_cooldown:
		return
	# Probability gate.
	if randi() % 100 >= _ab_chance:
		return
	# Render template (placeholders are user-controlled; safe by construction).
	var msg := template.replace("{name}", _username).replace("{map}",
		map if map != "" else "Unknown")
	# Run the same outgoing filters as a typed message would.
	if Filters.contains_link_or_path(msg):
		# User-authored template contains a link/path -- refuse silently
		# instead of bypassing the strict filter.
		return
	if _block_pii_out and Filters.contains_pii(msg):
		return
	if _filter_out and Filters.profanity_scan(msg, _extra_terms).get("blocked", false):
		return
	if not _connected:
		# Don't queue; events come around again.
		return
	_ab_last_t = now
	_last_send_t = now  # also touch the manual rate limiter
	var text := Filters.sanitize_unicode(msg, MAX_OUTGOING_TEXT)
	_send_raw({"type": "chat", "username": _username, "text": text.left(MAX_OUTGOING_TEXT)})
	_add_local_message("[auto] " + text, Color(0.7, 0.85, 0.6))

# ---- Tripwire (emergency disconnect) ---------------------------------------
# Patterns that look like attempts to make the client EXECUTE something rather
# than just display chat. ANY hit forces an immediate disconnect and lockout.
# Regex strings are kept simple (no catastrophic backtracking).
const _EXEC_PATTERNS := [
	"OS\\.execute",
	"OS\\.shell_open",
	"OS\\.create_process",
	"OS\\.set_environment",
	"ResourceLoader\\.load",
	"Engine\\.set_meta",
	"ClassDB\\.",
	"call_deferred\\s*\\(",
	"\\.connect\\s*\\(",
	"GDScript\\.new",
	"PackedScene\\.new",
	"FileAccess\\.open",
	"DirAccess\\.",
	"@tool",
	"extends\\s+Node",
	"func\\s+_ready\\s*\\(",
	"<\\?xml",
	"<!DOCTYPE",
	"\\$\\{[^}]*\\}",        # bash-style ${...} expansion
	"`[^`]{2,}`",            # backtick command substitution
	"%[a-zA-Z_][a-zA-Z0-9_]*%",  # Windows env-var expansion %X%
	"res://",
	"user://",
	"uid://",
]
var _exec_regex : Array = []

func _ensure_exec_regex() -> void:
	if not _exec_regex.is_empty():
		return
	for pat in _EXEC_PATTERNS:
		var rx := RegEx.new()
		if rx.compile(pat) == OK:
			_exec_regex.append(rx)

func _scan_payload_for_exec(msg: Dictionary) -> String:
	# Concatenate every string value in the dict (defensive: incl. any future
	# fields). Cap at 16 KB total to keep regex work bounded.
	_ensure_exec_regex()
	var blob := ""
	for key in msg.keys():
		var v = msg[key]
		if typeof(v) == TYPE_STRING:
			blob += String(v)
			blob += "\n"
		if blob.length() > 16384:
			break
	# BBCode-style tag injection that wraps a meta payload -- our _safe_bb
	# neutralizes these, but seeing them is still a hostile signal.
	if "[url=" in blob or "[/url]" in blob or "[img=" in blob \
		or "[code]" in blob.to_lower() or "[script" in blob.to_lower():
		return "bbcode_injection"
	# BOM / UTF tricks that try to slip past the sanitizer.
	if blob.find(String.chr(0xFEFF)) != -1:
		return "bom_injection"
	# Regex sweep.
	for rx in _exec_regex:
		if rx.search(blob) != null:
			return "exec_pattern"
	return ""

func _tw_bump_link_burst(label: String) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Sliding window: reset count if last hit was >30s ago.
	if now - _tw_link_window_t > 30.0:
		_tw_link_count = 0
	_tw_link_window_t = now
	_tw_link_count += 1
	if _tw_link_count >= _tw_link_thresh:
		_trip("link_burst:%s (%d hits)" % [label, _tw_link_count])

func _is_lockout_active() -> bool:
	if not _tw_tripped:
		return false
	if _tw_lockout <= 0.0:
		return true  # 0 = manual /reset required forever
	var now := Time.get_ticks_msec() / 1000.0
	if now - _tw_tripped_t >= _tw_lockout:
		# Lockout window expired -- auto-clear.
		_tw_tripped = false
		_tw_reason = ""
		_tw_link_count = 0
		return false
	return true

func _trip(reason: String) -> void:
	_tw_tripped = true
	_tw_tripped_t = Time.get_ticks_msec() / 1000.0
	_tw_reason = reason
	if _log != null:
		_log.append({"type": "tripwire", "username": "system", "text": reason},
			"system", reason, "tripwire")
	push_warning("[SafeRelayChat] TRIPWIRE: %s" % reason)
	# Hard-kill the socket and prevent reconnects.
	_disconnect_socket()
	_auto_connect = false
	# Cancel any background-sync window in progress so we don't loop on lockout.
	if _bg_active:
		_bg_active = false
		_bg_window_left = 0.0
		_bg_next_sync_t = _bg_interval_s
	_add_local_message("!! EMERGENCY DISCONNECT: %s" % reason, Color(1, 0.3, 0.3))
	_add_local_message("   Socket closed. Auto-connect disabled. Lockout: %.0fs."
		% _tw_lockout, Color(1, 0.6, 0.4))
	_add_local_message("   Use /reset to clear after reviewing /log.",
		Color(1, 0.6, 0.4))
	_set_status("TRIPWIRE: %s" % reason)

# ---- Public Mod API ---------------------------------------------------------
# Discover the node via Engine.get_meta("SafeRelayChatNode"). All entry points
# go through the same outgoing safety pipeline as user-typed chat. See
# MOD_EVENT_API.md for the full contract.

const API_VERSION := 1
const API_PER_SOURCE_COOLDOWN := 2.0  # seconds between events per source mod
const API_MAX_SOURCES_TRACKED := 32

var _api_last_send : Dictionary = {}   # source -> last send timestamp (sec)
var _api_send_count : int = 0
var _api_chat_subs : Array = []        # Array[Callable] subscribed to chat
var _api_event_subs : Array = []       # Array[Callable] subscribed to events

# Discovered event registry: slug -> { source, category, template, enabled, description }
var _event_registry : Dictionary = {}

# Returns the API contract version. Increment on breaking changes only.
func api_version() -> int:
	return API_VERSION

# True only when the socket is open AND not tripped AND network is enabled.
# Use this to gate mod-side activity that should only run while online.
func is_relay_connected() -> bool:
	return _connected and _network_enabled and not _tw_tripped

# True if the master kill-switch is enabled. A mod can use this to decide
# whether to even bother queueing events.
func is_relay_network_enabled() -> bool:
	return _network_enabled

# Best-effort: returns a sanitized snapshot of current state for mods that
# want to display chat status in their own UI.
func get_relay_status() -> Dictionary:
	return {
		"version":         API_VERSION,
		"network_enabled": _network_enabled,
		"connected":       _connected,
		"tripped":         _tw_tripped,
		"trip_reason":     _tw_reason if _tw_tripped else "",
		"bg_active":       _bg_active,
		"chat_open":       _open,
	}

# Broadcast an in-game event to the chat relay. Returns true if accepted,
# false if dropped (offline, rate-limited, filtered, or invalid). Other
# users see it as a normal chat message tagged with the event category and
# the source mod, e.g. "[AIRDROP] Crate at North Highway -- via Nomads".
func post_event(category: String, text: String, source: String = "external") -> bool:
	if not _network_enabled:
		return false
	if _tw_tripped:
		return false
	if not _connected:
		return false
	# Stealth mode: refuse outgoing events while the chat window is closed.
	# Incoming events still flow through normally; this only mutes us.
	if _stealth_closed and not _open:
		return false
	if typeof(category) != TYPE_STRING or typeof(text) != TYPE_STRING:
		return false
	# Sanitize category and source to [a-z0-9_-] only -- prevents BBCode,
	# whitespace tricks, unicode lookalikes from leaking into the formatted
	# message.
	var cat := _api_slug(category, 24)
	var src := _api_slug(source, 24)
	if cat == "" or src == "":
		return false
	# Per-source rate limit. Discard the source if we already track too many
	# so a hostile mod can't blow the dictionary up.
	var now := Time.get_ticks_msec() / 1000.0
	var last := float(_api_last_send.get(src, -1e6))
	if now - last < API_PER_SOURCE_COOLDOWN:
		return false
	if _api_last_send.size() >= API_MAX_SOURCES_TRACKED and not _api_last_send.has(src):
		return false
	_api_last_send[src] = now
	# Sanitize body the same way outgoing chat is sanitized.
	var clean := Filters.sanitize_unicode(text, MAX_OUTGOING_TEXT - 40)
	if clean == "":
		return false
	if Filters.contains_link_or_path(clean):
		return false
	if _block_pii_out and Filters.contains_pii(clean):
		return false
	if _filter_out:
		var scan := Filters.profanity_scan(clean, _extra_terms)
		if scan.get("blocked", false):
			return false
	# Format: "[CATEGORY] body -- via source"
	var formatted := "[%s] %s -- via %s" % [cat.to_upper(), clean, src]
	if formatted.length() > MAX_OUTGOING_TEXT:
		formatted = formatted.left(MAX_OUTGOING_TEXT)
	_send_raw({"type": "chat", "username": _username, "text": formatted})
	_api_send_count += 1
	# Echo locally so the player can see what their other mods sent.
	_add_local_message("* [mod-api/%s] %s" % [src, clean], Color(0.6, 0.85, 1.0))
	return true

# Send a chat message as if the player typed it. Useful for mods that want
# to provide quick-reply buttons. Goes through _send_chat so the player
# rate limit applies (anti-spam vs the mod-api cooldown which is per-mod).
func post_chat_as_self(text: String) -> bool:
	if not _network_enabled or not _connected or _tw_tripped:
		return false
	if typeof(text) != TYPE_STRING:
		return false
	var clean := text.strip_edges()
	if clean == "" or clean.begins_with("/"):
		return false
	_send_chat(clean)
	return true

# Subscribe a callable to receive sanitized incoming chat. Callback signature:
#   func on_chat(username: String, text: String) -> void
# Only delivered AFTER filters/log/tripwire -- subscribers see exactly what
# the player sees.
func subscribe_incoming_chat(cb: Callable) -> bool:
	if not cb.is_valid():
		return false
	if not _api_chat_subs.has(cb):
		_api_chat_subs.append(cb)
	return true

func unsubscribe_incoming_chat(cb: Callable) -> bool:
	if not _api_chat_subs.has(cb):
		return false
	_api_chat_subs.erase(cb)
	return true

# Subscribe to events posted by OTHER mods via post_event (or remote ones if
# the relay echoes mod-api-formatted messages). Callback signature:
#   func on_event(category: String, body: String, src: String, username: String) -> void
func subscribe_incoming_events(cb: Callable) -> bool:
	if not cb.is_valid():
		return false
	if not _api_event_subs.has(cb):
		_api_event_subs.append(cb)
	return true

func unsubscribe_incoming_events(cb: Callable) -> bool:
	if not _api_event_subs.has(cb):
		return false
	_api_event_subs.erase(cb)
	return true

# Force a background sync window right now (subject to MCM settings). Useful
# if a mod wants fresher chat history before showing a chat-summary UI.
func request_sync_now() -> bool:
	if not _network_enabled or not _bg_enabled:
		return false
	if _open or _connected or _bg_active:
		return false
	_bg_next_sync_t = 0.0
	return true

func _api_slug(s: String, max_len: int) -> String:
	var lower := s.strip_edges().to_lower()
	var rx := RegEx.new()
	rx.compile("[^a-z0-9_-]")
	var stripped := rx.sub(lower, "", true)
	return stripped.substr(0, max_len)

# ---- Mod Event Registry -----------------------------------------------------
# Mods register categories; each becomes a Bool+String pair in MCM on next boot.
# In-memory registry is live the same session.

const EVENT_SLUG_MAX := 48

func _load_event_registry() -> void:
	_event_registry.clear()
	if not FileAccess.file_exists(EVENT_REGISTRY_PATH):
		return
	var cfg := ConfigFile.new()
	if cfg.load(EVENT_REGISTRY_PATH) != OK:
		return
	var rx := RegEx.new()
	rx.compile("^[a-z0-9_-]{1,%d}$" % EVENT_SLUG_MAX)
	for section in cfg.get_sections():
		if not section.begins_with("event:"):
			continue
		var slug := section.substr(6)
		if rx.search(slug) == null:
			continue
		_event_registry[slug] = {
			"source"      = String(cfg.get_value(section, "source", "unknown")),
			"category"    = String(cfg.get_value(section, "category", "event")),
			"template"    = String(cfg.get_value(section, "default_template", "")),
			"description" = String(cfg.get_value(section, "description", "")),
			"enabled"     = bool(cfg.get_value(section, "default_enabled", false)),
		}
	print("[SafeRelayChat] event registry loaded: %d entr(ies)" % _event_registry.size())

func _save_event_registry_entry(slug: String, data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(EVENT_REGISTRY_PATH):
		cfg.load(EVENT_REGISTRY_PATH)
	var section := "event:" + slug
	cfg.set_value(section, "source",            data.get("source", "unknown"))
	cfg.set_value(section, "category",          data.get("category", "event"))
	cfg.set_value(section, "default_template",  data.get("template", ""))
	cfg.set_value(section, "description",       data.get("description", ""))
	# Only write default_enabled if section is brand new -- never clobber the
	# user's MCM toggle by re-running register at boot.
	if not cfg.has_section_key(section, "default_enabled"):
		cfg.set_value(section, "default_enabled", data.get("enabled", false))
	DirAccess.make_dir_recursive_absolute("user://SafeRelayChat")
	cfg.save(EVENT_REGISTRY_PATH)

# Register an event category (idempotent). Returns slug or "" on rejection.
# See MOD_EVENT_API.md for usage.
func register_event_category(source: String, category: String,
		default_template: String, description: String = "",
		default_enabled: bool = false) -> String:
	var src_slug := _api_slug(source, 24)
	var cat_slug := _api_slug(category, 24)
	if src_slug == "" or cat_slug == "":
		push_warning("[SafeRelayChat] register_event_category: invalid source/category")
		return ""
	var slug := src_slug + "__" + cat_slug
	# Preserve user's MCM-chosen enabled state across re-registers.
	var was_enabled : bool = default_enabled
	var was_template : String = default_template
	if _event_registry.has(slug):
		was_enabled = _event_registry[slug].get("enabled", default_enabled)
		# Keep the user-edited template if it differs from default.
		var existing_tpl : String = _event_registry[slug].get("template", "")
		if existing_tpl != "":
			was_template = existing_tpl
	var entry := {
		"source"      = src_slug,
		"category"    = cat_slug,
		"template"    = was_template,
		"description" = description,
		"enabled"     = was_enabled,
	}
	_event_registry[slug] = entry
	_save_event_registry_entry(slug, {
		"source"      = src_slug,
		"category"    = cat_slug,
		"template"    = default_template,
		"description" = description,
		"enabled"     = default_enabled,
	})
	return slug

# Public API: emit a registered event with placeholder substitution.
# `vars` keys correspond to {placeholder} tokens in the template. Returns
# true if the event was actually broadcast.
func post_registered_event(source: String, category: String,
		vars: Dictionary = {}) -> bool:
	var slug := _api_slug(source, 24) + "__" + _api_slug(category, 24)
	if not _event_registry.has(slug):
		return false
	var entry : Dictionary = _event_registry[slug]
	if not bool(entry.get("enabled", false)):
		return false
	var tpl : String = entry.get("template", "")
	if tpl.strip_edges() == "":
		return false
	var text := tpl
	for k in vars.keys():
		text = text.replace("{" + String(k) + "}", String(vars[k]))
	return post_event(entry.get("category", category), text, entry.get("source", source))

# Public API: enumerate registered events (read-only snapshot).
func list_registered_events() -> Array:
	var out : Array = []
	for slug in _event_registry.keys():
		var e : Dictionary = _event_registry[slug].duplicate()
		e["slug"] = slug
		out.append(e)
	return out

# Public API: remove a registered event. Returns true if it existed.
func unregister_event_category(source: String, category: String) -> bool:
	var slug := _api_slug(source, 24) + "__" + _api_slug(category, 24)
	if not _event_registry.has(slug):
		return false
	_event_registry.erase(slug)
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(EVENT_REGISTRY_PATH):
		cfg.load(EVENT_REGISTRY_PATH)
		cfg.erase_section("event:" + slug)
		cfg.save(EVENT_REGISTRY_PATH)
	return true

# Internal: invoke subscriber callables safely (one bad mod can't break others).
func _api_dispatch_chat(username: String, text: String) -> void:
	if _api_chat_subs.is_empty():
		return
	for cb in _api_chat_subs.duplicate():
		if cb is Callable and cb.is_valid():
			# Wrap so a subscriber throwing doesn't take us with it.
			cb.call_deferred(username, text)
	# Detect mod-api format and dispatch to event subscribers.
	if _api_event_subs.is_empty():
		return
	var rx := RegEx.new()
	rx.compile("^\\[([A-Z0-9_-]{1,24})\\]\\s+(.+?)\\s+--\\s+via\\s+([a-z0-9_-]{1,24})$")
	var m := rx.search(text)
	if m == null:
		return
	var cat := m.get_string(1).to_lower()
	var body := m.get_string(2)
	var src := m.get_string(3)
	for cb in _api_event_subs.duplicate():
		if cb is Callable and cb.is_valid():
			cb.call_deferred(cat, body, src, username)

# ---- Cleanup ----------------------------------------------------------------
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _connected and not _suppress_jl:
			_send_raw({"type": "leave", "username": _username})
		_disconnect_socket()
		if _open and _game_data:
			_game_data.freeze = _prev_freeze
		if Engine.has_meta("SafeRelayChatNode"):
			Engine.remove_meta("SafeRelayChatNode")
