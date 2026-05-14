extends Node

# =============================================================================
# Safe Relay Chat -- MCM Config Registration
# =============================================================================

const MOD_ID    := "SafeRelayChat"
const FILE_PATH := "user://MCM/SafeRelayChat"
const CFG_FILE  := "user://MCM/SafeRelayChat/config.ini"

const MCM_HELPERS_PATH := "res://ModConfigurationMenu/Scripts/Doink Oink/MCM_Helpers.tres"

func _ready() -> void:
	var config := ConfigFile.new()

	# ---- Identity --------------------------------------------------------------
	config.set_value("String", "username", {
		"name"    = "Display Name",
		"tooltip" = "Your name in chat (2-24 ASCII chars). Leave blank to auto-generate. Note: anyone connected to the relay can see this.",
		"default" = "",
		"value"   = "",
		"category" = "Identity"
	})

	config.set_value("Bool", "ephemeral_identity", {
		"name"    = "Ephemeral Identity",
		"tooltip" = "Generate a fresh random username every session and never persist it to disk. Strongest setting for anonymity.",
		"default" = true,
		"value"   = true,
		"category" = "Identity"
	})

	# ---- Connection ------------------------------------------------------------
	config.set_value("Bool", "network_enabled", {
		"name"    = ">>> MOD NETWORK ENABLED (MASTER ON/OFF) <<<",
		"tooltip" = "MASTER SWITCH for the entire mod's network activity. When OFF: no auto-connect, no reconnect-on-drop, no background sync, no manual /connect, no connect-on-chat-open. The chat window still opens and shows local /commands and chat history, but cannot send or receive anything from the relay. Use this to go fully offline without uninstalling the mod.",
		"default" = true,
		"value"   = true,
		"category" = "0 - Master Switch"
	})

	config.set_value("String", "relay_url", {
		"name"    = "Relay Server URL",
		"tooltip" = "Only wss:// URLs are accepted (TLS-only enforcement). Anyone running the relay server can see your IP -- use a VPN or your own relay to mitigate.",
		"default" = "wss://vostok-relay-chat.mrdeadnasty.workers.dev/ws",
		"value"   = "wss://vostok-relay-chat.mrdeadnasty.workers.dev/ws",
		"category" = "Connection"
	})

	config.set_value("Bool", "auto_connect", {
		"name"    = "Auto-Connect On Boot",
		"tooltip" = "If off, no socket is opened until you click Connect in the chat panel. Stops the mod from contacting the relay at all when disabled. Ignored if 'Connect Only While Chat Open' is on.",
		"default" = false,
		"value"   = false,
		"category" = "Connection"
	})

	config.set_value("Bool", "connect_on_open", {
		"name"    = "Connect Only While Chat Open",
		"tooltip" = "Open the WebSocket only while the chat window is visible. Closing the chat window sends 'leave' and drops the socket; opening it again reconnects. Maximum privacy mode -- relay only sees you while you're actively chatting. Side effect: auto-broadcast events can only fire while chat is open.",
		"default" = true,
		"value"   = true,
		"category" = "Connection"
	})

	config.set_value("Bool", "stealth_when_closed", {
		"name"    = "Stealth Mode (stay connected, mute outgoing while closed)",
		"tooltip" = "Alternative to Connect-Only-While-Open. The socket stays connected the whole game session, but while the chat window is CLOSED no outgoing chat, autobroadcasts, or mod events are sent. Incoming messages still arrive and accumulate in the chat history so you see them when you open the window. Avoids the noisy join/leave churn other players see every time you peek at the chat. Overrides 'Connect Only While Chat Open'.",
		"default" = false,
		"value"   = false,
		"category" = "Connection"
	})

	config.set_value("Bool", "suppress_join_leave", {
		"name"    = "Suppress Join/Leave Broadcasts",
		"tooltip" = "Never send the 'join' or 'leave' system messages. Other players will not see you connect or disconnect. Recommended ON when using Stealth Mode. Note: the relay still knows you connected -- only other players are blind to it.",
		"default" = true,
		"value"   = true,
		"category" = "Connection"
	})

	config.set_value("Bool", "afk_disconnect_enabled", {
		"name"    = "AFK Auto-Disconnect",
		"tooltip" = "Automatically disconnect from the relay after a period of no keyboard, mouse, or chat input. Resets the moment you press any key, move the mouse, or type in chat. A 30-second warning appears in chat before the disconnect fires.",
		"default" = true,
		"value"   = true,
		"category" = "Connection"
	})

	config.set_value("Int", "afk_timeout_min", {
		"name"    = "AFK Timeout (minutes)",
		"tooltip" = "Disconnect after this many minutes of no input. A warning appears 30 seconds before disconnect.",
		"default" = 15,
		"value"   = 15,
		"minRange" = 1,
		"maxRange" = 120,
		"category" = "Connection"
	})

	# ---- Background Sync -------------------------------------------------------
	# Periodically opens a short connection window while the chat is closed, just
	# long enough to populate the in-game chat history with whatever messages
	# arrive during the window. The relay protocol does NOT support history
	# replay -- this only captures messages that are live during the window.
	config.set_value("Bool", "bg_sync_enabled", {
		"name"    = "Background Sync",
		"tooltip" = "Periodically open a short WebSocket window in the background to populate chat history with live messages. Only runs while the chat window is closed and the privacy notice has been accepted. Each sync window reveals your IP to the relay for the duration of the window (same as any normal connect). Does nothing when 'Connect Only While Chat Open' is off and you're already connected.",
		"default" = false,
		"value"   = false,
		"category" = "Background Sync"
	})

	config.set_value("Int", "bg_sync_interval_min", {
		"name"    = "Sync Interval (minutes)",
		"tooltip" = "Time between sync windows.",
		"default" = 5,
		"value"   = 5,
		"minRange" = 1,
		"maxRange" = 60,
		"category" = "Background Sync"
	})

	config.set_value("Int", "bg_sync_window_sec", {
		"name"    = "Sync Window (seconds)",
		"tooltip" = "How long each sync stays connected. Longer = more chance to receive live messages, but more time exposed.",
		"default" = 15,
		"value"   = 15,
		"minRange" = 5,
		"maxRange" = 120,
		"category" = "Background Sync"
	})

	config.set_value("Bool", "bg_sync_silent", {
		"name"    = "Silent Sync (Lurker Mode)",
		"tooltip" = "Do NOT send a 'join' announcement during sync windows. Other users won't see you appear and disappear every few minutes. Recommended.",
		"default" = true,
		"value"   = true,
		"category" = "Background Sync"
	})

	config.set_value("Bool", "bg_sync_toasts", {
		"name"    = "Show Toasts During Sync",
		"tooltip" = "If on, messages received during background sync windows pop up as passive toasts even when chat is closed. If off, they are silently appended to chat history and you'll see them next time you open the chat.",
		"default" = false,
		"value"   = false,
		"category" = "Background Sync"
	})

	# ---- Controls --------------------------------------------------------------
	# NOTE: KEY_T conflicts with several RTV in-game bindings. Default is now
	# backslash (rarely bound). MCM auto-rebinds this action when changed.
	config.set_value("Keycode", "safe_relay_chat_toggle", {
		"name"    = "Chat Toggle Key",
		"tooltip" = "Key that opens/closes the chat window. Avoid keys the base game uses for movement/weapons (e.g. T).",
		"default" = KEY_BACKSLASH,
		"value"   = KEY_BACKSLASH,
		"category" = "Controls"
	})

	# ---- Display ---------------------------------------------------------------
	config.set_value("Bool", "show_join_leave", {
		"name"    = "Show Join/Leave",
		"tooltip" = "Display a notice when other players join or leave the relay.",
		"default" = true,
		"value"   = true,
		"category" = "Display"
	})

	config.set_value("Float", "chat_opacity", {
		"name"    = "Chat Window Opacity",
		"tooltip" = "Transparency of the open chat panel.",
		"default" = 0.88,
		"value"   = 0.88,
		"minRange" = 0.2,
		"maxRange" = 1.0,
		"category" = "Display"
	})

	config.set_value("Int", "font_size", {
		"name"    = "Chat Text Size",
		"tooltip" = "Font size for chat messages.",
		"default" = 12,
		"value"   = 12,
		"minRange" = 8,
		"maxRange" = 24,
		"category" = "Display"
	})

	config.set_value("Int", "max_history", {
		"name"    = "Message History",
		"tooltip" = "Max number of messages kept in the scroll buffer.",
		"default" = 80,
		"value"   = 80,
		"minRange" = 20,
		"maxRange" = 200,
		"category" = "Display"
	})

	# ---- Passive Toasts --------------------------------------------------------
	config.set_value("Bool", "passive_enabled", {
		"name"    = "Passive Toasts",
		"tooltip" = "Show fading message popups in the corner while the chat panel is closed.",
		"default" = true,
		"value"   = true,
		"category" = "Passive View"
	})

	config.set_value("Float", "toast_duration", {
		"name"    = "Toast Duration",
		"tooltip" = "How long each passive message stays before fading.",
		"default" = 8.0,
		"value"   = 8.0,
		"minRange" = 3.0,
		"maxRange" = 30.0,
		"category" = "Passive View"
	})

	# ---- Stream Safety ---------------------------------------------------------
	config.set_value("Bool", "filter_incoming_profanity", {
		"name"    = "Censor Incoming Profanity",
		"tooltip" = "Replaces profanity/slurs in received messages with asterisks. Recommended ON when recording or streaming.",
		"default" = true,
		"value"   = true,
		"category" = "Stream Safety"
	})

	config.set_value("Bool", "filter_outgoing_profanity", {
		"name"    = "Block Outgoing Profanity",
		"tooltip" = "Refuses to broadcast your own messages if they contain profanity (so a stream slip can't leak to other players).",
		"default" = false,
		"value"   = false,
		"category" = "Stream Safety"
	})

	config.set_value("Bool", "strip_urls", {
		"name"    = "Strip URLs From Incoming",
		"tooltip" = "Replace http/https/wss URLs and bare domains in received messages with [link]. Prevents malicious or doxxing links from appearing on stream.",
		"default" = true,
		"value"   = true,
		"category" = "Stream Safety"
	})

	config.set_value("Bool", "block_pii_outgoing", {
		"name"    = "Block PII In Outgoing",
		"tooltip" = "Refuses to send messages that look like they contain an IP, email, or phone number. Defense in depth against keyboard slips.",
		"default" = true,
		"value"   = true,
		"category" = "Stream Safety"
	})

	config.set_value("String", "extra_blocked_terms", {
		"name"    = "Extra Blocked Terms",
		"tooltip" = "Comma-separated additional words to censor (case-insensitive). Example: badword, anotherword",
		"default" = "",
		"value"   = "",
		"category" = "Stream Safety"
	})

	# ---- Rate Limiting / Anti-Spam --------------------------------------------
	config.set_value("Float", "send_cooldown", {
		"name"    = "Send Cooldown (seconds)",
		"tooltip" = "Minimum delay between your outgoing messages. Prevents accidental spam (and being kicked by future server moderation).",
		"default" = 1.0,
		"value"   = 1.0,
		"minRange" = 0.0,
		"maxRange" = 10.0,
		"category" = "Rate Limit"
	})

	# ---- Auto-Broadcast --------------------------------------------------------
	config.set_value("Bool", "autobroadcast_enabled", {
		"name"    = "Auto-Broadcast Events",
		"tooltip" = "Automatically send chat messages when in-game events happen (entered shelter, trading, map change, in combat). Each event has the configured chance to fire.",
		"default" = false,
		"value"   = false,
		"category" = "Auto-Broadcast"
	})

	config.set_value("Int", "autobroadcast_chance", {
		"name"    = "Broadcast Chance %",
		"tooltip" = "Probability that any single qualifying event triggers a broadcast. Lower = quieter, higher = noisier.",
		"default" = 30,
		"value"   = 30,
		"minRange" = 0,
		"maxRange" = 100,
		"category" = "Auto-Broadcast"
	})

	config.set_value("Float", "autobroadcast_cooldown", {
		"name"    = "Min Seconds Between Broadcasts",
		"tooltip" = "Hard global floor between auto-broadcast messages, regardless of how many events trigger.",
		"default" = 45.0,
		"value"   = 45.0,
		"minRange" = 5.0,
		"maxRange" = 600.0,
		"category" = "Auto-Broadcast"
	})

	# Templates support placeholders: {name} (your username) and {map}.
	# Empty template disables that specific event.
	config.set_value("String", "tpl_shelter_enter", {
		"name"    = "Shelter Enter Message",
		"tooltip" = "Sent when you enter a shelter. Placeholders: {name}, {map}. Leave empty to disable.",
		"default" = "Back at the shelter on {map}, restocking.",
		"value"   = "Back at the shelter on {map}, restocking.",
		"category" = "Auto-Broadcast Templates"
	})

	config.set_value("String", "tpl_trader", {
		"name"    = "Trader Message",
		"tooltip" = "Sent when you start trading with a trader. Placeholders: {name}, {map}. Leave empty to disable.",
		"default" = "Shopping at a trader on {map}.",
		"value"   = "Shopping at a trader on {map}.",
		"category" = "Auto-Broadcast Templates"
	})

	config.set_value("String", "tpl_map_change", {
		"name"    = "Map Change Message",
		"tooltip" = "Sent when you arrive on a new map. Placeholders: {name}, {map}. Leave empty to disable.",
		"default" = "Made it to {map}.",
		"value"   = "Made it to {map}.",
		"category" = "Auto-Broadcast Templates"
	})

	config.set_value("String", "tpl_hunted", {
		"name"    = "Being Hunted Message",
		"tooltip" = "Sent when AI in Combat/Hunt state is targeting you, or you take fresh damage in the field. Placeholders: {name}, {map}. Leave empty to disable.",
		"default" = "Pinned down on {map}, AI are hunting me.",
		"value"   = "Pinned down on {map}, AI are hunting me.",
		"category" = "Auto-Broadcast Templates"
	})

	config.set_value("String", "tpl_combat_end", {
		"name"    = "Combat Over Message",
		"tooltip" = "Sent some seconds after the last shot when combat ends. Placeholders: {name}, {map}. Leave empty to disable.",
		"default" = "Clear on {map}. That was close.",
		"value"   = "Clear on {map}. That was close.",
		"category" = "Auto-Broadcast Templates"
	})

	# ---- Metadata Privacy ------------------------------------------------------
	config.set_value("Bool", "metadata_padding", {
		"name"    = "Pad Outgoing Metadata",
		"tooltip" = "Adds random padding bytes and timing jitter to each outgoing packet. Does NOT hide your IP from the relay -- nothing client-side can. It DOES make message fingerprinting and traffic-analysis harder for a passive observer.",
		"default" = true,
		"value"   = true,
		"category" = "Metadata Privacy"
	})

	config.set_value("Float", "metadata_jitter", {
		"name"    = "Send Jitter (seconds)",
		"tooltip" = "Random delay added before each message is sent. Larger = more cover, but also more lag perceived by other chatters.",
		"default" = 0.3,
		"value"   = 0.3,
		"minRange" = 0.0,
		"maxRange" = 3.0,
		"category" = "Metadata Privacy"
	})

	# ---- Tripwire (Emergency Disconnect) --------------------------------------
	config.set_value("Bool", "tripwire_enabled", {
		"name"    = "Emergency Disconnect Tripwire",
		"tooltip" = "Forcibly drop the socket and lock out reconnects if the relay sends anything that looks like an attempted code/command execution, BBCode/resource-path injection, oversized payload, malformed-JSON flood, or a sustained burst of malicious links. Strongly recommended ON.",
		"default" = true,
		"value"   = true,
		"category" = "Tripwire"
	})

	config.set_value("Int", "tripwire_link_threshold", {
		"name"    = "Link/Command Burst Threshold",
		"tooltip" = "If this many link/command messages are dropped within the burst window, the tripwire fires.",
		"default" = 5,
		"value"   = 5,
		"minRange" = 1,
		"maxRange" = 50,
		"category" = "Tripwire"
	})

	config.set_value("Float", "tripwire_lockout", {
		"name"    = "Lockout Duration (seconds)",
		"tooltip" = "After the tripwire fires, refuse all reconnects (manual or auto) for this long. 0 = require manual /reset.",
		"default" = 300.0,
		"value"   = 300.0,
		"minRange" = 0.0,
		"maxRange" = 86400.0,
		"category" = "Tripwire"
	})

	# ---- Persist ---------------------------------------------------------------
	# ---- Mod Event Hooks (discovered from other mods at runtime) ---------------
	# Other mods call SafeRelayChat.register_event_category(...) which writes
	# entries to user://SafeRelayChat/event_registry.cfg. We read that here so
	# each registered category becomes a pair of MCM entries (enabled + template).
	# New registrations only appear in MCM on the NEXT game boot; the mod can
	# still emit events the same session via the live in-memory registry.
	_register_dynamic_events(config)

	if not FileAccess.file_exists(CFG_FILE):
		DirAccess.make_dir_recursive_absolute(FILE_PATH)
		config.save(CFG_FILE)

	if not ResourceLoader.exists(MCM_HELPERS_PATH):
		return

	var helpers = load(MCM_HELPERS_PATH)
	if helpers == null:
		push_warning("[SafeRelayChat] Failed to load MCM helpers.")
		return

	if FileAccess.file_exists(CFG_FILE) and helpers.has_method("CheckConfigurationHasUpdated"):
		helpers.CheckConfigurationHasUpdated(MOD_ID, config, CFG_FILE)

	if helpers.has_method("RegisterConfiguration"):
		helpers.RegisterConfiguration(
			MOD_ID,
			"Safe Relay Chat",
			FILE_PATH,
			"Global cross-player chat with profanity/PII/URL filters and identity hardening.",
			{ "config.ini": _on_config_updated }
		)

func _on_config_updated(updated_config: ConfigFile) -> void:
	if Engine.has_meta("SafeRelayChatNode"):
		var chat_node = Engine.get_meta("SafeRelayChatNode")
		if is_instance_valid(chat_node) and chat_node.has_method("apply_mcm_config"):
			chat_node.apply_mcm_config(updated_config)

# Reads event_registry.cfg and adds one Bool + one String MCM entry per
# registered category. Category in MCM is "Mod Event Hooks". A short header
# row appears at the top to explain what the section is for.
func _register_dynamic_events(config: ConfigFile) -> void:
	var registry_path := "user://SafeRelayChat/event_registry.cfg"
	if not FileAccess.file_exists(registry_path):
		return
	var reg := ConfigFile.new()
	if reg.load(registry_path) != OK:
		return
	var added := 0
	for section in reg.get_sections():
		if not section.begins_with("event:"):
			continue
		var slug := section.substr(6)
		# Tight slug sanity check -- never trust the file.
		var rx := RegEx.new()
		rx.compile("^[a-z0-9_-]{1,48}$")
		if rx.search(slug) == null:
			continue
		var src := String(reg.get_value(section, "source", "unknown"))
		var cat := String(reg.get_value(section, "category", "event"))
		var desc := String(reg.get_value(section, "description", ""))
		var tpl := String(reg.get_value(section, "default_template", ""))
		var def_enabled := bool(reg.get_value(section, "default_enabled", false))
		var human_name := "[%s] %s" % [src, cat]
		var tooltip_enabled := "Enable broadcasting this event."
		if desc != "":
			tooltip_enabled = desc + "  (from mod: " + src + ")"
		config.set_value("Bool", "event_enabled__" + slug, {
			"name"     = human_name + "  (enable)",
			"tooltip"  = tooltip_enabled,
			"default"  = def_enabled,
			"value"    = def_enabled,
			"category" = "Mod Event Hooks"
		})
		var tpl_tooltip := "Template for this event. Placeholders like {map}, {name} are filled in by the source mod."
		config.set_value("String", "event_tpl__" + slug, {
			"name"     = human_name + "  (template)",
			"tooltip"  = tpl_tooltip,
			"default"  = tpl,
			"value"    = tpl,
			"category" = "Mod Event Hooks"
		})
		added += 1
	if added > 0:
		print("[SafeRelayChat] registered %d dynamic event categor(ies) in MCM" % added)
