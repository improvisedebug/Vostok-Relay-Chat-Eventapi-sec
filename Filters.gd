extends RefCounted
class_name SafeRelayFilters

# =============================================================================
# Vostok Relay Chat -- Text Sanitization, Profanity, PII, URL handling
# =============================================================================
# All filters are pure functions. No side effects. No network calls.
# Built to be MIT-license-clean of any third-party word list: list below is
# a conservative, common set of strong English profanity / slurs commonly
# blocked on stream-safe platforms. Users can edit it via MCM "extra terms".
# =============================================================================

# Conservative base list of high-risk words for stream-safety. Stored as
# lower-case substrings; matched on word boundaries with leet-speak fold.
const BASE_BLOCKLIST: Array[String] = [
	"fuck", "shit", "bitch", "cunt", "asshole", "bastard", "dick", "pussy",
	"cock", "whore", "slut", "fag", "faggot", "nigger", "nigga", "retard",
	"retarded", "kike", "spic", "chink", "tranny", "dyke", "wetback",
]

# Leet-speak / homoglyph normalization map. Keys are single chars or short
# unicode sequences; values are the ASCII letter we collapse them to.
const _LEET_MAP := {
	"0": "o", "1": "i", "!": "i", "|": "i", "3": "e", "4": "a", "@": "a",
	"5": "s", "$": "s", "7": "t", "8": "b", "9": "g",
	# Cyrillic and other homoglyphs of ASCII letters
	"а": "a", "А": "a", "е": "e", "Е": "e", "о": "o", "О": "o",
	"р": "p", "Р": "p", "с": "c", "С": "c", "х": "x", "Х": "x",
	"у": "y", "У": "y", "і": "i", "І": "i", "ј": "j", "Ј": "j",
}

# Zero-width and bidi-override codepoints (homoglyph / spoofing risk).
# Stripped entirely.
const _UNICODE_KILL := [
	0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF,             # zero-width
	0x202A, 0x202B, 0x202C, 0x202D, 0x202E,             # bidi overrides
	0x2066, 0x2067, 0x2068, 0x2069,                     # isolate
]

# -----------------------------------------------------------------------------
# Unicode sanitization
# -----------------------------------------------------------------------------
# Removes invisible/control characters and clamps length. Always run on both
# incoming and outgoing text before display.
static func sanitize_unicode(s: String, max_len: int = 300) -> String:
	if s == "":
		return s
	var out := ""
	for ch in s:
		var cp := ch.unicode_at(0)
		# Strip ASCII control chars except common whitespace.
		if cp < 0x20 and cp != 0x09 and cp != 0x0A and cp != 0x0D:
			continue
		# Strip DEL.
		if cp == 0x7F:
			continue
		# Strip dangerous unicode classes.
		if cp in _UNICODE_KILL:
			continue
		out += ch
	# Collapse runs of newlines (no shouting blocks).
	while out.find("\n\n\n") != -1:
		out = out.replace("\n\n\n", "\n\n")
	return out.left(max_len)

# -----------------------------------------------------------------------------
# Profanity filter
# -----------------------------------------------------------------------------
# Builds a normalized scan string (leet-folded, lower-cased, non-alnum stripped)
# then searches for blocked terms. If found, the ORIGINAL string is censored
# by replacing the bad span with asterisks of equal visible length.
#
# extra_terms: user-added words from MCM (lower-case).
# returns: { "clean": String, "blocked": bool, "hits": Array[String] }
static func profanity_scan(s: String, extra_terms: Array, censor_char: String = "*") -> Dictionary:
	var result := {"clean": s, "blocked": false, "hits": []}
	if s.strip_edges() == "":
		return result

	var normalized := _normalize_for_match(s)
	var all_terms: Array = []
	for t in BASE_BLOCKLIST:
		all_terms.append(t)
	for t in extra_terms:
		var lo := String(t).strip_edges().to_lower()
		if lo != "" and not all_terms.has(lo):
			all_terms.append(lo)

	var hits: Array[String] = []
	for term in all_terms:
		if term.length() < 3:
			continue
		if normalized.find(term) != -1:
			hits.append(term)

	if hits.is_empty():
		return result

	result["blocked"] = true
	result["hits"] = hits
	# Censor each hit span in the original (best-effort, scan original lower-cased).
	var lower := s.to_lower()
	var censored := s
	for term in hits:
		var start := 0
		while true:
			var idx := lower.find(term, start)
			if idx == -1:
				break
			var stars := ""
			for i in range(term.length()):
				stars += censor_char
			censored = censored.substr(0, idx) + stars + censored.substr(idx + term.length())
			# also update lower so subsequent finds skip already-censored span
			lower = lower.substr(0, idx) + stars.to_lower() + lower.substr(idx + term.length())
			start = idx + term.length()
	result["clean"] = censored
	return result

static func _normalize_for_match(s: String) -> String:
	var lower := s.to_lower()
	var out := ""
	for ch in lower:
		if _LEET_MAP.has(ch):
			out += _LEET_MAP[ch]
		elif ch >= "a" and ch <= "z":
			out += ch
		elif ch >= "0" and ch <= "9":
			out += ch
		# everything else (spaces, punctuation, accents, etc.) is dropped so
		# spaced/punctuated obfuscations like "f.u.c.k" collapse to "fuck".
	return out

# -----------------------------------------------------------------------------
# Link / file-path / command detector (strict)
# -----------------------------------------------------------------------------
# Returns true if the text contains ANY recognized link, file path, IP literal,
# or shell-command pattern, after de-obfuscation. Used to DROP messages rather
# than display them with a placeholder.
#
# Defeats the following common obfuscations:
#   hxxps://example.com         (h-x-x-p-s prefix)
#   example[.]com               (bracketed dot)
#   example(.)com               (parenthesized dot)
#   example {dot} com           (word "dot")
#   example DOT com             (uppercase word "dot")
#   exa\nmple.com               (line breaks inside)
#   1.2.3.4                     (IPv4 literal)
#   xn--... (punycode)          (IDN)
#   discord.gg/abc              (any TLD via universal pattern)
static func contains_link_or_path(s: String) -> bool:
	if s == "":
		return false
	var norm := _deobfuscate(s)

	# Scheme-based URIs (http, https, ws, wss, ftp, ftps, file, magnet, ipfs, ipns, data, javascript, vbscript)
	var re_scheme := RegEx.new()
	re_scheme.compile("(?i)\\b(?:hxx?tps?|https?|wss?|ftps?|file|magnet|ipfs|ipns|data|javascript|vbscript|sftp|ssh|telnet|gopher|smb)\\s*:\\s*[/\\\\]")
	if re_scheme.search(norm) != null:
		return true

	# Bare domain (any TLD, 2+ chars after final dot). Catches discord.gg, foo.io, etc.
	var re_dom := RegEx.new()
	re_dom.compile("(?i)\\b[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?)*\\.[a-z]{2,24}\\b")
	if re_dom.search(norm) != null:
		return true

	# Punycode IDN.
	if norm.find("xn--") != -1:
		return true

	# IPv4 literal (with optional port/path).
	var re_ip := RegEx.new()
	re_ip.compile("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
	if re_ip.search(norm) != null:
		return true

	# IPv6 literal (loose: at least three colon groups of hex).
	var re_ip6 := RegEx.new()
	re_ip6.compile("\\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\\b")
	if re_ip6.search(norm) != null:
		return true

	# UNC paths   \\server\share
	if norm.find("\\\\") != -1:
		return true

	# Windows absolute paths   C:\...   D:/...
	var re_win := RegEx.new()
	re_win.compile("(?i)\\b[a-z]:[\\\\/]")
	if re_win.search(norm) != null:
		return true

	# Unix absolute paths to sensitive prefixes.
	for prefix in ["/etc/", "/usr/", "/var/", "/root/", "/home/", "/tmp/", "/dev/", "/proc/", "/sys/"]:
		if norm.find(prefix) != -1:
			return true

	# Dangerous file extensions anywhere in text.
	var re_ext := RegEx.new()
	re_ext.compile("(?i)\\.(?:exe|bat|cmd|com|scr|vbs|vbe|js|jse|jar|ps1|psm1|sh|bash|zsh|app|dmg|msi|deb|rpm|apk|ipa|elf|dll|so|dylib|pak|vmz|tres|tscn|gd|gdshader|cfg|ini|reg|lnk|url|hta)\\b")
	if re_ext.search(norm) != null:
		return true

	# Shell / scripting command tokens (case-insensitive). Word-boundary match.
	var dangerous := [
		"rm -rf", "rm -fr", "del /", "rmdir /", "format ", "mkfs",
		"sudo ", "su -", "chmod ", "chown ",
		"cmd /c", "cmd.exe", "powershell", "iex ", "iwr ", "invoke-",
		"curl ", "wget ", "fetch ", "nc -", "ncat ", "netcat",
		"bash -", "sh -c", "python -c", "perl -e", "ruby -e",
		"reg add", "reg delete", "schtasks", "taskkill",
		"net user", "net localgroup",
		"DROP TABLE", "DELETE FROM", "INSERT INTO", "UPDATE SET",
		"<script", "</script", "onerror=", "onload=", "onclick=",
	]
	var lower := norm.to_lower()
	for tok in dangerous:
		if lower.find(tok.to_lower()) != -1:
			return true

	return false

# Internal: de-obfuscate common URL/path camouflage patterns BEFORE matching.
static func _deobfuscate(s: String) -> String:
	var t := s
	# Strip zero-width chars and line breaks that splice tokens together.
	t = t.replace("\r", "").replace("\n", "").replace("\t", " ")
	# Common "hxxp" / "h**ps" tricks -> http
	t = t.replace("hxxps", "https").replace("hxxp", "http")
	t = t.replace("h**ps", "https").replace("h**p", "http")
	# Bracketed / parenthesized / spaced "dot"
	t = t.replace("[.]", ".").replace("(.)", ".").replace("{.}", ".")
	t = t.replace("[dot]", ".").replace("(dot)", ".").replace("{dot}", ".")
	# "word DOT word" -> "word.word"  (case-insensitive)
	var re_dot := RegEx.new()
	re_dot.compile("(?i)\\s+dot\\s+")
	t = re_dot.sub(t, ".", true)
	# Bracketed "@" trick
	t = t.replace("[at]", "@").replace("(at)", "@").replace("{at}", "@")
	# Spaced-out scheme like "h t t p s : / /"
	var re_sp := RegEx.new()
	re_sp.compile("(?i)\\bh\\s*t\\s*t\\s*p\\s*s?\\s*:\\s*/\\s*/")
	t = re_sp.sub(t, "https://", true)
	# Collapse internal whitespace runs.
	while t.find("  ") != -1:
		t = t.replace("  ", " ")
	return t

# -----------------------------------------------------------------------------
# PII guard
# -----------------------------------------------------------------------------
# Returns true if the outgoing message looks like it contains an IP address,
# an email, or a phone number. Used to refuse sending — defense in depth so a
# slip of the keyboard can't leak the user's own contact info.
static func contains_pii(s: String) -> bool:
	# IPv4
	var re_ip := RegEx.new()
	re_ip.compile("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b")
	if re_ip.search(s) != null:
		return true
	# IPv6 (loose -- 2+ colon groups)
	var re_ip6 := RegEx.new()
	re_ip6.compile("\\b(?:[0-9a-fA-F]{1,4}:){2,}[0-9a-fA-F]{1,4}\\b")
	if re_ip6.search(s) != null:
		return true
	# Email
	var re_em := RegEx.new()
	re_em.compile("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}")
	if re_em.search(s) != null:
		return true
	# Phone (>=10 consecutive digits with optional separators)
	var re_ph := RegEx.new()
	re_ph.compile("(?:\\+?\\d[\\s\\-\\.]?){10,}")
	if re_ph.search(s) != null:
		return true
	return false

# -----------------------------------------------------------------------------
# Username validator (also used on incoming display names)
# -----------------------------------------------------------------------------
# Enforces 2..24 chars, ASCII printable, no profanity, no leading/trailing
# whitespace. Returns "" if invalid.
static func validate_username(name: String, extra_terms: Array) -> String:
	var t := name.strip_edges()
	if t.length() < 2 or t.length() > 24:
		return ""
	for ch in t:
		var cp := ch.unicode_at(0)
		if cp < 0x20 or cp > 0x7E:
			return ""
	var scan := profanity_scan(t, extra_terms)
	if scan.get("blocked", false):
		return ""
	return t
