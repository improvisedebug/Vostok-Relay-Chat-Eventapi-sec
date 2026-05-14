# Safe Relay Chat — Mod Event API

---

## Overview

Safe Relay Chat exposes a small public API that lets other mods:

1. **Register** named event categories at boot (e.g. "Improvised AI — Being Hunted").
2. **Emit** those events with placeholder substitution.
3. Have each registered event automatically surface in **MCM → Safe Relay Chat → Mod Event Hooks** as two settings the user controls:
   - a **Bool toggle** (enable/disable broadcasting),
   - a **String template** (the message body, with `{placeholder}` tokens).

All emitted events flow through the existing chat pipeline, so they inherit:

- Profanity / PII / URL filters
- Rate limiting & jitter
- Master network toggle (instantly silenced when the user turns the mod off)
- Tripwire lockout
- Background-sync handoff (no premature disconnects)
- **AFK auto-disconnect** — after the user's configured idle timeout (default 15 min) the relay disconnects, so a mod with chatty events won't keep an idle player connected indefinitely. `post_registered_event` returns `false` while disconnected.

If the user disables an event in MCM, your `post_registered_event` call returns `false` without sending anything. You never need to gate it yourself.

---

## Quick start

```gdscript
# In your mod's autoload _ready():
func _ready() -> void:
    var relay = _get_relay()
    if relay == null:
        return  # SafeRelayChat not installed — silently no-op
    relay.register_event_category(
        "improvisedai",                                # source mod slug
        "patrol_engaged",                              # category slug
        "Patrol opened fire on {map} near {area}.",    # default template
        "Fires when an Improvised AI patrol engages the player.",  # description
        false                                          # default_enabled (user enables in MCM)
    )

# When the actual event happens:
func _on_patrol_engaged(area_name: String) -> void:
    var relay = _get_relay()
    if relay == null:
        return
    relay.post_registered_event("improvisedai", "patrol_engaged", {
        "map":  GameData.currentMap,
        "area": area_name,
    })

func _get_relay():
    if Engine.has_meta("SafeRelayChatNode"):
        var n = Engine.get_meta("SafeRelayChatNode")
        if is_instance_valid(n) and n.has_method("register_event_category"):
            return n
    return null
```

That's the whole integration. Restart the game once and your event appears in MCM.

---

## API reference

All methods are called on the autoload retrieved via `Engine.get_meta("SafeRelayChatNode")`.

### `api_version() -> int`

Returns the API contract version. Currently `1`. Bump-on-break.

```gdscript
if relay.api_version() < 1:
    return  # too old, skip integration
```

### `register_event_category(source, category, default_template, description = "", default_enabled = false) -> String`

Register an event slot. Idempotent — safe to call every boot.

| Param | Type | Notes |
|-------|------|-------|
| `source` | `String` | Your mod's identifier. Sanitized to `[a-z0-9_-]{1,24}`. |
| `category` | `String` | What the event is. Sanitized to `[a-z0-9_-]{1,24}`. |
| `default_template` | `String` | Message body for new users. May contain `{name}` placeholders. |
| `description` | `String` | Shown as the MCM tooltip on the enable toggle. |
| `default_enabled` | `bool` | Whether the toggle starts ON for fresh installs. Default `false` (recommended). |

**Returns:** the canonical slug (`source__category`), or `""` if rejected.

**Important behavior:**

- Re-registering an existing slug **preserves** the user's MCM-edited template and enable flag. Only metadata (description) refreshes.
- The MCM entries themselves appear on the **next** game boot. The in-memory registry is live the same session, so `post_registered_event` works immediately during early development/testing — it just won't have user-visible settings until restart.

### `post_registered_event(source, category, vars = {}) -> bool`

Emit a registered event. Returns `true` if the event was broadcast.

```gdscript
relay.post_registered_event("improvisedai", "patrol_engaged", {
    "map":  "Sawmill",
    "area": "the gas station",
})
```

Returns `false` (silently, no warning) when:

- The slug isn't registered.
- The user disabled it in MCM.
- The template is empty.
- The master network toggle is off, or the relay is tripped, or rate-limited.

You never need to check state — just call it.

**Placeholder substitution:** every `{key}` in the template is replaced with `String(vars[key])`. Missing keys are left literal so you can spot them in chat.

### `list_registered_events() -> Array[Dictionary]`

Returns a snapshot of all registered events. Each dict contains:

```gdscript
{
    "slug":        "improvisedai__patrol_engaged",
    "source":      "improvisedai",
    "category":    "patrol_engaged",
    "template":    "Patrol opened fire on {map} near {area}.",
    "description": "Fires when an Improvised AI patrol engages the player.",
    "enabled":     true,
}
```

Useful for debug overlays or for mods that want to react to other mods' registered events.

### `unregister_event_category(source, category) -> bool`

Remove a registered event from both the in-memory registry and the persisted registry file. Returns `true` if the entry existed.

You generally **do not** need to call this — registry entries are cheap and removing one will discard the user's MCM choices. Use only when permanently retiring an event from your mod.

---

## How it appears in MCM

After one game restart following `register_event_category`, the user sees a new section under **Safe Relay Chat**:

```
Mod Event Hooks
├─ [improvisedai] patrol_engaged  (enable)        [bool checkbox]
├─ [improvisedai] patrol_engaged  (template)      [text field]
├─ [improvisedai] patrol_disengaged  (enable)
├─ [improvisedai] patrol_disengaged  (template)
└─ ...
```

The user can:

- Toggle individual events on/off.
- Customize the broadcast text with their own wording (placeholders still work).

The master network toggle in `0 - Master Switch` still overrides everything — turning the mod off silences every registered event globally.

---

## How it looks in chat

Events are routed through the same formatter as `post_event`:

```
[PATROL_ENGAGED] Patrol opened fire on Sawmill near the gas station. -- via improvisedai
```

This format is parseable by `subscribe_incoming_events` (see "Listening to events" below), so other mods can react to events from across the network.

---

## Listening to events from other mods

Separate from registration, you can subscribe to **all** event-format chat messages (your own and others'):

```gdscript
func _ready() -> void:
    var relay = _get_relay()
    if relay == null:
        return
    relay.subscribe_incoming_events(Callable(self, "_on_relay_event"))

func _on_relay_event(category: String, body: String, source: String, username: String) -> void:
    # category = "patrol_engaged"
    # body     = "Patrol opened fire on Sawmill near the gas station."
    # source   = "improvisedai"
    # username = sender's ephemeral name
    ...
```

Pair `register_event_category` (outgoing) with `subscribe_incoming_events` (incoming) to make mods that talk to each other across players.

---

## Slash commands

Players have one debug command for the registry:

| Command | Effect |
|---------|--------|
| `/listevents` | Lists every registered event slug with its on/off state. |
| `/afk on\|off` | Toggle the AFK auto-disconnect (also configurable in MCM → Connection). With no argument, prints current state and timeout. |
| `/help`       | Shows the full command list. |

---

## Storage

The persisted registry lives at:

```
user://SafeRelayChat/event_registry.cfg
```

One `[event:<slug>]` section per registered event, with keys: `source`, `category`, `default_template`, `description`, `default_enabled`.

The file is **never trusted blindly** — slugs are re-validated against `[a-z0-9_-]{1,48}` on read.

The user's MCM choices live in the normal MCM config at `user://MCM/SafeRelayChat/config.ini` and override the registry's defaults at runtime.

---

## Best practices

- **Default off.** Pass `default_enabled = false`. Let the user opt in. Chat noise from a mod that auto-enables a dozen events on install is what got the original VostokRelayChat banned from servers.
- **Use placeholders.** Don't bake the map name or player name into the registered template — pass them through `vars`. The user can then rewrite the template however they like and still get their data.
- **Keep slugs stable.** Renaming `patrol_engaged` to `patrol_attacked` orphans every user's saved toggle. Treat slugs like a public API.
- **One register call per category, at autoload `_ready`.** Don't register inside hot paths.
- **Don't spam.** The relay enforces rate limits, but well-behaved mods coalesce. E.g. fire `patrol_engaged` once per encounter, not once per shot.
- **Fail silent.** Always check `_get_relay() == null`. Treat SafeRelayChat as an optional dependency, never a hard one.

---

## Versioning

| API version | Mod version | Notes |
|-------------|-------------|-------|
| 1           | 1.6+        | `post_event`, `post_chat_as_self`, subscribe/unsubscribe chat & events, `request_sync_now`, `get_relay_status`. |
| 1 (additive) | 1.7+        | `register_event_category`, `post_registered_event`, `list_registered_events`, `unregister_event_category`. |
| 1 (additive) | 1.7.4+      | Incoming text renders through `RichTextLabel.add_text()` — no BBCode parsing of network strings. |
| 1 (additive) | 1.7.5+      | AFK auto-disconnect (MCM → Connection). `is_relay_connected()` flips false on AFK timeout; subscribers do not see a disconnect event but `get_relay_status().connected` reflects it. |

Additive changes do not bump `API_VERSION`. Breaking changes will.

---

## Troubleshooting

**My event doesn't show up in MCM.**
You need one full game restart after the first `register_event_category` call. The MCM panel is built from `Config.gd` at boot.

**`post_registered_event` returns false but my event is enabled.**
Check `get_relay_status()` — the master toggle might be off, the relay might be tripped, or you might be rate-limited. `/status` in chat shows the same info.

**My slug came back as `""`.**
Source or category contained no `[a-z0-9_-]` characters after sanitization, or was empty.

**The template prints `{map}` literally instead of substituting.**
Missing key in your `vars` dict. Add `"map": GameData.currentMap` (or whatever).

**Other mods see my event but with the wrong source name.**
Sanitization collapses unsupported characters. `"My Cool Mod"` becomes `"my-cool-mod"` (sort of — spaces are dropped, not replaced). Pick a clean lowercase slug up front.

**My event stopped firing after a while.**
The user probably hit the AFK timeout (default 15 min, configurable in MCM → Connection). `get_relay_status().connected` will be `false`. The user reconnects by reopening the chat window (or typing `/connect` if auto-connect is on). Subscribers should treat this exactly like a manual disconnect.
