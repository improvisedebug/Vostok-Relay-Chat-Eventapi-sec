extends RefCounted
class_name SafeRelayLog

# =============================================================================
# Safe Relay Chat -- Incoming Message Log
# =============================================================================
# Append-only JSONL log of every incoming message we see, for forensics /
# moderation reports. Stored under user://SafeRelayChat/incoming_log.jsonl.
#
# IMPORTANT: We do NOT see peer IPs from a WebSocket relay. The IP is only
# visible to the relay operator. What we log is everything the relay tells us
# (timestamp, type, raw + sanitized username, truncated text, fingerprint,
# any extra fields the relay attaches). Operators can match our fingerprint
# against their server-side IP logs to issue actual IP bans.
#
# Truncation: text fields are capped to 64 chars to keep the log compact,
# but a sha256 fingerprint of the full original text is recorded so identical
# messages from different display names can be correlated.
#
# Rotation: when the file passes MAX_BYTES, it's renamed to .1 and a fresh
# file is opened. One generation of history is kept.
# =============================================================================

const LOG_DIR     := "user://SafeRelayChat"
const LOG_PATH    := "user://SafeRelayChat/incoming_log.jsonl"
const LOG_OLD     := "user://SafeRelayChat/incoming_log.jsonl.1"
const MAX_BYTES   := 2 * 1024 * 1024     # 2 MB before rotation
const TEXT_TRUNC  := 64

# Cached metadata for the running session.
var _started_at_ms : int = 0
var _seq          : int = 0
var _rotated      : bool = false

func _init() -> void:
	_started_at_ms = Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(LOG_DIR)

# Public API ------------------------------------------------------------------

# Append one incoming-message record. raw_msg is the full Dictionary as parsed
# from the relay; sanitized_name and sanitized_text are the cleaned versions.
func append(raw_msg: Dictionary, sanitized_name: String, sanitized_text: String,
		filter_action: String) -> void:
	_seq += 1
	var unix_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var raw_text := String(raw_msg.get("text", ""))
	var entry := {
		"seq"      : _seq,
		"t_ms"     : unix_ms,
		"t_local"  : Time.get_datetime_string_from_system(false, true),
		"type"     : String(raw_msg.get("type", "")),
		"name"     : sanitized_name.left(48),
		"name_raw" : String(raw_msg.get("username", "")).left(48),
		"text"     : sanitized_text.left(TEXT_TRUNC),
		"text_len" : raw_text.length(),
		"fp"       : _fingerprint(raw_text),
		"action"   : filter_action,         # "delivered" | "dropped:link" | "dropped:profanity" | "blocked:user"
		# Capture any extra keys the relay attached (peer_id, session_id, etc.)
		# so a future protocol upgrade is preserved without code changes.
		"extra"    : _extract_extras(raw_msg),
	}
	_rotate_if_needed()
	var f := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE) \
		if FileAccess.file_exists(LOG_PATH) else FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f == null:
		f = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify(entry))
	f.close()

# Return the most recent N entries (newest last).
func tail(n: int = 20) -> Array:
	if not FileAccess.file_exists(LOG_PATH):
		return []
	var f := FileAccess.open(LOG_PATH, FileAccess.READ)
	if f == null:
		return []
	var lines := []
	while not f.eof_reached():
		var l := f.get_line()
		if l.strip_edges() != "":
			lines.append(l)
	f.close()
	var out: Array = []
	var start := max(0, lines.size() - n)
	for i in range(start, lines.size()):
		var parsed = JSON.parse_string(lines[i])
		if parsed is Dictionary:
			out.append(parsed)
	return out

# Write a single-user report bundle to a timestamped file under LOG_DIR.
# Returns the path written, or "" on failure. Used by /report NAME.
func export_report_for(name: String) -> String:
	var lower := name.strip_edges().to_lower()
	if lower == "":
		return ""
	var matches: Array = []
	for src in [LOG_OLD, LOG_PATH]:
		if not FileAccess.file_exists(src):
			continue
		var f := FileAccess.open(src, FileAccess.READ)
		if f == null:
			continue
		while not f.eof_reached():
			var l := f.get_line().strip_edges()
			if l == "":
				continue
			var parsed = JSON.parse_string(l)
			if parsed is Dictionary:
				var nm := String(parsed.get("name", "")).to_lower()
				var nmr := String(parsed.get("name_raw", "")).to_lower()
				if nm == lower or nmr == lower:
					matches.append(parsed)
		f.close()
	if matches.is_empty():
		return ""
	var stamp := Time.get_datetime_string_from_system(true, true).replace(":", "-").replace(" ", "_")
	var safe_name := name.strip_edges().to_lower()
	# Strip filesystem-unsafe chars from name component.
	var re := RegEx.new()
	re.compile("[^a-z0-9_-]")
	safe_name = re.sub(safe_name, "_", true).left(32)
	var path := "%s/report_%s_%s.json" % [LOG_DIR, safe_name, stamp]
	var fout := FileAccess.open(path, FileAccess.WRITE)
	if fout == null:
		return ""
	var bundle := {
		"reported_name" : name,
		"generated_at"  : Time.get_datetime_string_from_system(false, true),
		"mod"           : "SafeRelayChat",
		"note"          : "Forward this file to the relay operator. The 'fp' field is a sha256 of the full original text; the operator can match it against their server-side IP logs to issue an IP ban.",
		"entries"       : matches,
	}
	fout.store_string(JSON.stringify(bundle, "  "))
	fout.close()
	return path

# Erase both current and rotated log files.
func purge() -> void:
	for p in [LOG_PATH, LOG_OLD]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

# Internal -------------------------------------------------------------------

func _rotate_if_needed() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		return
	var sz := FileAccess.get_file_as_bytes(LOG_PATH).size()
	if sz < MAX_BYTES:
		return
	if FileAccess.file_exists(LOG_OLD):
		DirAccess.remove_absolute(LOG_OLD)
	DirAccess.rename_absolute(LOG_PATH, LOG_OLD)

func _fingerprint(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	var digest := ctx.finish()
	# Hex-encode first 8 bytes (16 hex chars) -- enough for cross-rename matching.
	var out := ""
	for i in range(min(8, digest.size())):
		out += "%02x" % digest[i]
	return out

func _extract_extras(msg: Dictionary) -> Dictionary:
	# Anything beyond the known protocol keys is preserved verbatim for the
	# moderation report. Values are coerced to strings and truncated.
	var known := ["type", "username", "text"]
	var out := {}
	for key in msg.keys():
		if key in known:
			continue
		var v = msg[key]
		var s := str(v)
		out[String(key).left(32)] = s.left(128)
	return out
