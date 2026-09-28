extends Node

signal transition_finished # emitted every time a run finishes, on its own or via _abort()
## TransitionLab.gd -- "Screensaver Developer" mode: a test bench for transition effects
##
## A transition hides a cut between two presets behind a distortion of the final image:
##   no effect  ->  maximum effect  ->  no effect
## At the peak the next preset is swapped in (the "snap"), so the viewer never sees the cut.
##
## Developer mode (main menu > SCREENSAVER DEV, leave the menu with B):
##   D-pad left / right   transition to the previous / next saved preset (oldest first, wraps around)
##   D-pad up / down      cycle the transition time 5 s / 10 s / 20 s
##   B                    abort a running transition: the next preset is applied at once
##   A                    (saving screensaver presets comes in the next update)
##   OPT                  the transition lab menu: pick formulas (several can be active at once), then
##                        pick a uniform and dial in its MAX value (its peak). Uniforms with a rest value
##                        move from rest to your value and back; the others just keep the value you set.
##
## TRANSITION FORMULAS use the same tag comments as the shader recipes, plus one extra tag:
##   uniform float u_strength = 8.0; // @label Twist Strength | @min -40 | @max 40 | @sens 0.5 | @rest 0
##   @rest   marks a FLOAT uniform as animated and gives its value when no transition is running.
##           The formula MUST look like "no effect" at its rest values. The default (8.0) is the peak.
##   No @rest: a fixed setting (any type) that keeps the value you dial in.
## Formula kinds:  "warp"   vec2 fx_<id>(vec2 uv)                   moves where the image is sampled
##                 "color"  vec4 fx_<id>(vec4 c, vec2 uv, sampler2D screen)   changes the sampled color
##                          (TEXTURE only exists inside fragment(); pass it in as "screen" to sample it, as fx_chroma does)
## Use screen-relative units (fractions of the screen), so a setting behaves the same on any device.
## Formula ids and uniform names should stay stable once saved styles exist.

const TIMES: Array = [5.0, 10.0, 20.0]
const HOLD_FRACTION: float = 0.18 # share of the transition spent holding the peak (covers the snap hitch)
const SENS_DEFAULT_INDEX: int = 2
const SCREENSAVER_DIR: String = "user://screensaver_presets"
const NAME_MAX_LENGTH: int = 24


enum M { FORMULAS, UNIFORMS, CHANNELS, TWEAK, TWEAK_COLOR, LOAD_LIST, CONFIRM_DELETE }

var main
var owner_menu

var dev_mode: bool = false
var running: bool = false
var time_idx: int = 1

# Formula registry and what is currently active (in stacking order)
var formulas: Dictionary = {}     # id -> {id, name, kind, source}
var active: Array = []
var peak_values: Dictionary = {}  # final uniform name -> value (the peak for animated ones)
var _records: Array = []          # uniform records of the assembled effect shader
var _material: ShaderMaterial = null

# The effect layer: a picture of the final display image, on top of it, only visible during a transition
var _screen: TextureRect
var _host
var _indicator: Label

# Transition state
var _t0_msec: int = 0
var _snapped: bool = false
var _target_entry: Dictionary = {}
var _current_file: String = ""
var _playlist_pos: int = -1
var _playlist_size: int = 0
var _message: String = ""
var _snapshot_stack: Array = []
var _snapshot_values: Array = []
var _original_opt: Callable = Callable()

# Lab menu
var menu_open: bool = false
var _panel_ref: Object = null
var mode: int = M.FORMULAS
var _cursor_formula: int = 0
var _cursor_uniform: int = 1
var _formula_id: String = ""
var _uniform_idx: int = 0
var _channel_idx: int = 0
var _tweak_row: int = 0
var _sens_idx: int = SENS_DEFAULT_INDEX
var _sens_memory: Dictionary = {}

# Saving a transition preset (A button, menus closed) and browsing saved ones (from the formula list)
var saving: bool = false
var typing: bool = false # true while the name field has focus (mirrors PresetsMenu.typing)
var _name_edit = null
var _load_entries: Array = []
var _load_cursor: int = 0


var _re_uniform: RegEx

const _Lib = preload("res://ShaderLibrary.gd")


# =========================================================================
# SETUP
# =========================================================================
func setup(main_manager, owner_options: Object) -> void:
	main = main_manager
	owner_menu = owner_options
	_re_uniform = RegEx.new()
	# groups: 1 type, 2 name, 3 hint, 4 default literal, 5 comment tags
	_re_uniform.compile("^\\s*uniform\\s+(float|vec2|vec4)\\s+(\\w+)\\s*(?::\\s*([^=;]+?))?\\s*=\\s*([^;]+);\\s*(?://(.*))?$")
	_register_formulas()
	set_process(false)

	_host = main.canvas_container.get_parent()
	_screen = TextureRect.new()
	_screen.texture = main.pass3_viewport.get_texture()
	_screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_screen.stretch_mode = TextureRect.STRETCH_SCALE
	_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_screen.visible = false
	_host.add_child(_screen)
	_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_host.move_child(_screen, main.canvas_container.get_index() + 1) # above the display, below the menus

	_indicator = Label.new()
	_indicator.position = Vector2(10, 8)
	_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_indicator.z_index = 3
	_indicator.add_theme_font_size_override("font_size", 20)
	_indicator.add_theme_color_override("font_color", Color(0.7, 1.0, 0.3))
	_indicator.add_theme_color_override("font_outline_color", Color.BLACK)
	_indicator.add_theme_constant_override("outline_size", 6)
	_indicator.visible = false
	_host.add_child(_indicator)


# =========================================================================
# DEVELOPER MODE ON / OFF
# =========================================================================
func toggle_dev_mode() -> void:
	dev_mode = not dev_mode
	if dev_mode:
		_snapshot_look()
		_original_opt = Callable(main, "_on_select_pass_button_pressed")
		if main.btn_select_pass.pressed.is_connected(_original_opt):
			main.btn_select_pass.pressed.disconnect(_original_opt)
		main.btn_select_pass.pressed.connect(_on_opt_pressed)
		_current_file = ""
		_playlist_pos = -1
		_message = ""
		_indicator.visible = true
		_update_indicator()
	else:
		if running:
			_finish()
		if saving:
			_end_typing()
			_close_save_session()
		if menu_open:
			_close_menu()
		if main.btn_select_pass.pressed.is_connected(_on_opt_pressed):
			main.btn_select_pass.pressed.disconnect(_on_opt_pressed)
		if _original_opt.is_valid() and not main.btn_select_pass.pressed.is_connected(_original_opt):
			main.btn_select_pass.pressed.connect(_original_opt)
		_indicator.visible = false
		_restore_look()

## The look on screen when the mode was switched on is put back when it is switched off.
func _snapshot_look() -> void:
	_snapshot_stack = main.pass_stack.duplicate(true)
	_snapshot_values = main.pass_values.duplicate(true)

func _restore_look() -> void:
	if _snapshot_stack.is_empty():
		return
	for p in range(3):
		main.pass_stack[p] = _snapshot_stack[p].duplicate()
		main.pass_values[p].clear() # in place, so the menu's link to it stays valid
		main.pass_values[p].merge(_snapshot_values[p])
		main.rebuild_pass(p)

func _update_indicator() -> void:
	var text: String = "DEV  %d S  ·  %d FX" % [int(TIMES[time_idx]), active.size()]
	if _playlist_size > 0 and _playlist_pos >= 0:
		text += "  ·  %d/%d" % [_playlist_pos + 1, _playlist_size]
	if _message != "":
		text += "\n" + _message
	_indicator.text = text

func _say(text: String) -> void:
	_message = text
	_update_indicator()
	get_tree().create_timer(3.0).timeout.connect(_clear_message.bind(text))

func _clear_message(text: String) -> void:
	if _message == text:
		_message = ""
		_update_indicator()


# =========================================================================
# INPUT WITH THE MENUS CLOSED (DynamicUI sends it here while developer mode is on)
# =========================================================================
func dev_input(action: String) -> bool:
	if not dev_mode or menu_active():
		return false
	match action:
		"left":
			start_transition(-1)
		"right":
			start_transition(1)
		"up":
			_cycle_time(1)
		"down":
			_cycle_time(-1)
		"b":
			if running:
				_abort()
		"a":
			if active.is_empty():
				_say("ADD A FORMULA FIRST (PRESS OPT)")
			else:
				_open_save()
	return true

func _cycle_time(step: int) -> void:
	time_idx = posmod(time_idx + step, TIMES.size())
	_say("TRANSITION TIME: %d S%s" % [int(TIMES[time_idx]), " (NEXT TRANSITION)" if running else ""])


# =========================================================================
# THE TRANSITION
# =========================================================================
func _playlist() -> Array:
	var entries: Array = owner_menu.presets._scan()
	entries.sort_custom(func(a, b): return a["created"] < b["created"]) # oldest first: new presets join the end
	return entries

func start_transition(direction: int) -> void:
	if running:
		return
	if _material == null:
		_say("NO TRANSITION FORMULA ACTIVE: PRESS OPT")
		return
	var entries: Array = _playlist()
	_playlist_size = entries.size()
	if entries.size() < 2:
		_say("NEED AT LEAST 2 SAVED PRESETS")
		return
	var pos: int = -1
	for i in range(entries.size()):
		if entries[i]["file"] == _current_file:
			pos = i
	var target: int
	if pos == -1:
		target = 0 if direction > 0 else entries.size() - 1
	else:
		target = posmod(pos + direction, entries.size())
	_playlist_pos = target
	_begin(entries[target])

## Runs a transition to a specific preset, regardless of the playlist. Used by Screensaver Mode, which
## picks its own random pairing rather than walking the saved-preset list in order. The transition
## formula and its peak values must already be set (Screensaver Mode loads a random transition preset
## into it first).
func run_transition_to(entry: Dictionary) -> void:
	if running:
		return
	_playlist_size = 0
	_playlist_pos = -1
	_begin(entry)

func _begin(entry: Dictionary) -> void:
	if _material == null:
		_say("NO TRANSITION FORMULA ACTIVE: PRESS OPT")
		return
	_target_entry = entry
	_snapped = false
	_t0_msec = Time.get_ticks_msec()
	running = true
	_screen.visible = true
	_apply_rest_values()
	set_process(true)
	_update_indicator()

func _process(_delta: float) -> void:
	if not running:
		set_process(false)
		return
	var duration: float = TIMES[time_idx]
	var p: float = float(Time.get_ticks_msec() - _t0_msec) / (duration * 1000.0) # by the clock, so a hitch never skips ahead
	if p >= 1.0:
		_finish()
		return
	if not _snapped and p >= 0.5:
		_snap()
	var e: float = _envelope(p)
	for rec in _records:
		if rec["animated"]:
			_material.set_shader_parameter(rec["name"], lerpf(float(rec["rest"]), float(peak_values[rec["name"]]), e))
	_material.set_shader_parameter("u_time", float(Time.get_ticks_msec()) / 1000.0)

## 0 -> 1 -> 0 with a short hold at the top.
func _envelope(p: float) -> float:
	var half_hold: float = HOLD_FRACTION * 0.5
	var rise_end: float = 0.5 - half_hold
	var fall_start: float = 0.5 + half_hold
	if p < rise_end:
		return smoothstep(0.0, 1.0, p / rise_end)
	if p <= fall_start:
		return 1.0
	return 1.0 - smoothstep(0.0, 1.0, (p - fall_start) / (1.0 - fall_start))

## Swap in the next preset while the image is at its most distorted. The time it takes is shown on screen.
func _snap() -> void:
	_snapped = true
	var before: int = Time.get_ticks_usec()
	var ok: bool = owner_menu.presets._load_preset(_target_entry)
	var took_ms: int = int(round(float(Time.get_ticks_usec() - before) / 1000.0))
	if ok:
		_current_file = _target_entry["file"]
		_say("%s   (SNAP %d MS)" % [String(_target_entry["name"]), took_ms])
	else:
		_say("COULD NOT LOAD %s" % String(_target_entry["name"]))

## B: skip to the end. If the snap has not happened yet, the next preset is applied right now.
func _abort() -> void:
	if not _snapped:
		_snap()
	_finish()

func _finish() -> void:
	running = false
	_screen.visible = false
	_apply_rest_values()
	set_process(false)
	_update_indicator()
	transition_finished.emit()


# =========================================================================
# THE EFFECT SHADER (built from the active formulas)
# =========================================================================
func _rebuild_effect() -> void:
	if active.is_empty():
		_material = null
		_records = []
		_screen.material = null
		_update_indicator()
		return
	var built: Dictionary = _assemble()
	var effect_shader := Shader.new()
	effect_shader.code = built["code"]
	_material = ShaderMaterial.new()
	_material.shader = effect_shader
	_records = built["records"]
	for rec in _records:
		if not peak_values.has(rec["name"]):
			peak_values[rec["name"]] = rec["default"]
	_apply_rest_values()
	_screen.material = _material
	_update_indicator()

## Everything at rest: animated uniforms at their rest value, fixed ones at the value that was dialed in.
func _apply_rest_values() -> void:
	if _material == null:
		return
	for rec in _records:
		if rec["animated"]:
			_material.set_shader_parameter(rec["name"], float(rec["rest"]))
		else:
			_material.set_shader_parameter(rec["name"], peak_values[rec["name"]])

func _assemble() -> Dictionary:
	var decls: PackedStringArray = PackedStringArray()
	var funcs: PackedStringArray = PackedStringArray()
	var records: Array = []
	var warp_calls: String = ""
	var color_calls: String = ""
	for id in active:
		var f: Dictionary = formulas[id]
		var renames: Dictionary = {}
		var body: PackedStringArray = PackedStringArray()
		for line in String(f["source"]).split("\n"):
			var rec: Dictionary = _parse_line(line, id)
			if rec.is_empty():
				body.append(line)
				continue
			# Prefix with the formula id so stacked formulas never share a uniform name
			rec["name"] = "u_%s_%s" % [id, String(rec["base"]).trim_prefix("u_")]
			renames[rec["base"]] = rec["name"]
			records.append(rec)
			decls.append(_decl_line(rec))
		var text: String = "\n".join(body)
		for base in renames:
			text = _rename_word(text, base, renames[base])
		funcs.append(text)
		if f["kind"] == "warp":
			warp_calls += "\tuv = fx_%s(uv);\n" % id
		else:
			color_calls += "\tc = fx_%s(c, UV, TEXTURE);\n" % id
	var code: String = "shader_type canvas_item;\nuniform float u_time;\n"
	code += "vec2 tatool_mirror(vec2 x) {\n\treturn abs(mod(x + 1.0, 2.0) - 1.0);\n}\n\n"
	code += "\n".join(decls) + "\n\n" + "\n".join(funcs) + "\n\n"
	code += "void fragment() {\n\tvec2 uv = UV;\n" + warp_calls
	code += "\tvec4 c = texture(TEXTURE, tatool_mirror(uv));\n" + color_calls + "\tCOLOR = c;\n}\n"
	return {"code": code, "records": records}

func _rename_word(text: String, from_name: String, to_name: String) -> String:
	var re: RegEx = RegEx.new()
	re.compile("\\b%s\\b" % from_name)
	return re.sub(text, to_name, true)

func _decl_line(rec: Dictionary) -> String:
	var hint: String = ""
	if rec["hint"] != "":
		hint = " : %s" % rec["hint"]
	var literal: String = rec["literal"]
	if rec["animated"]:
		literal = "%.6f" % float(rec["rest"]) # the shader's own default is "no effect"
	return "uniform %s %s%s = %s;" % [rec["type"], rec["name"], hint, literal]

func _parse_line(line: String, formula_id: String) -> Dictionary:
	var m: RegExMatch = _re_uniform.search(line)
	if m == null:
		return {}
	var type: String = m.get_string(1)
	var tags: Dictionary = _parse_tags(m.get_string(5))
	var literal: String = m.get_string(4).strip_edges()
	var base: String = m.get_string(2)
	var mn: float = float(tags["min"]) if tags.has("min") else -INF
	var mx: float = float(tags["max"]) if tags.has("max") else INF
	var sens: float = 0.01
	if tags.has("sens"):
		sens = float(tags["sens"])
	elif not is_inf(mn) and not is_inf(mx):
		sens = (mx - mn) / 100.0
	var channels: Array = ["VALUE"]
	if type == "vec2":
		channels = ["X", "Y"]
	elif type == "vec4":
		channels = ["R", "G", "B", "A"]
	var animated: bool = tags.has("rest") and type == "float"
	return {
		"formula": formula_id,
		"base": base,
		"name": base,
		"type": type,
		"hint": m.get_string(3).strip_edges(),
		"literal": literal,
		"default": _parse_literal(type, literal), # the peak (animated) or the fixed value
		"label": str(tags.get("label", base.trim_prefix("u_").replace("_", " ").capitalize())),
		"min": mn,
		"max": mx,
		"sens": sens,
		"channels": channels,
		"animated": animated,
		"rest": float(tags["rest"]) if animated else 0.0,
	}

func _parse_tags(comment: String) -> Dictionary:
	var tags: Dictionary = {}
	for part in comment.split("|"):
		var p: String = part.strip_edges()
		if not p.begins_with("@"):
			continue
		p = p.substr(1)
		var sp: int = p.find(" ")
		if sp == -1:
			tags[p] = true
		else:
			tags[p.substr(0, sp)] = p.substr(sp + 1).strip_edges()
	return tags

func _parse_literal(type: String, text: String) -> Variant:
	var t: String = text.strip_edges()
	if type == "float":
		return float(t)
	var nums: Array = []
	var open: int = t.find("(")
	var close: int = t.rfind(")")
	if open != -1 and close > open:
		for s in t.substr(open + 1, close - open - 1).split(","):
			nums.append(float(s.strip_edges()))
	if type == "vec2":
		if nums.size() == 1:
			nums.append(nums[0])
		while nums.size() < 2:
			nums.append(0.0)
		return Vector2(nums[0], nums[1])
	if nums.size() == 1:
		return Color(nums[0], nums[0], nums[0], nums[0])
	while nums.size() < 4:
		nums.append(0.0 if nums.size() < 3 else 1.0)
	return Color(nums[0], nums[1], nums[2], nums[3])

func _get_comp(value: Variant, type: String, idx: int) -> float:
	match type:
		"vec2":
			var v2: Vector2 = value
			return v2[idx]
		"vec4":
			var c4: Color = value
			return c4[idx]
	return float(value)

func _set_comp(value: Variant, type: String, idx: int, v: float) -> Variant:
	match type:
		"vec2":
			var v2: Vector2 = value
			v2[idx] = v
			return v2
		"vec4":
			var c4: Color = value
			c4[idx] = v
			return c4
	return v


# =========================================================================
# THE LAB MENU (OPT while developer mode is on): formulas > uniforms > (channels) > tweak
# =========================================================================
func _on_opt_pressed() -> void:
	if saving:
		return
	var cp = main.control_panel
	if menu_active():
		_close_menu()
		return
	if cp.active_state != cp.ControlState.HIDDEN:
		return # another menu is open
	if running:
		_say("WAIT FOR THE TRANSITION (B TO ABORT)")
		return
	_open_menu()

func menu_active() -> bool:
	return (menu_open or saving) and is_instance_valid(_panel_ref) and main.menu_overlay_panel == _panel_ref

func _open_menu() -> void:
	menu_open = true
	mode = M.FORMULAS
	_cursor_formula = 0
	var cp = main.control_panel
	cp.active_state = cp.ControlState.SYSTEM_MENU # routes the D-pad and A/B to the options menu, which forwards them here
	main._ensure_cyan_panel()
	_panel_ref = main.menu_overlay_panel
	redraw()

func _close_menu() -> void:
	menu_open = false
	_panel_ref = null
	var cp = main.control_panel
	cp.active_state = cp.ControlState.HIDDEN
	if is_instance_valid(main.menu_overlay_panel):
		main.menu_overlay_panel.queue_free()
		main.menu_overlay_panel = null
	main.menu_center_host.visible = false
	_update_indicator()


## A -> opens the save screen. B or a successful save closes it, same as an OPT submenu closing (no outer
## main menu to return to, since this was reached directly from the hidden/idle developer-mode screen).
func _open_save() -> void:
	saving = true
	var cp = main.control_panel
	cp.active_state = cp.ControlState.SYSTEM_MENU
	main._ensure_cyan_panel()
	_panel_ref = main.menu_overlay_panel
	redraw()

func _close_save_session() -> void:
	saving = false
	_panel_ref = null
	var cp = main.control_panel
	cp.active_state = cp.ControlState.HIDDEN
	if is_instance_valid(main.menu_overlay_panel):
		main.menu_overlay_panel.queue_free()
		main.menu_overlay_panel = null
	main.menu_center_host.visible = false
	_update_indicator()

func _on_typing_started() -> void:
	typing = true

func _on_typing_stopped() -> void:
	_end_typing()

func _end_typing() -> void:
	if is_instance_valid(_name_edit):
		_name_edit.release_focus()
	_name_edit = null
	var was_typing: bool = typing
	typing = false
	if was_typing and owner_menu != null:
		owner_menu.notify_typing_done() # the keyboard may have resized the window; re-check the layout



func _scan_names() -> Array:
	var out: Array = []
	for e in _scan_transition_presets():
		out.append(String(e["name"]))
	return out

func _default_name() -> String:
	var highest: int = 0
	for n in _scan_names():
		if n.begins_with("TRANSITION "):
			var tail: String = n.substr(11)
			if tail.is_valid_int():
				highest = maxi(highest, int(tail))
	return "TRANSITION %03d" % (highest + 1)

## Two saved transitions never share a name: the second becomes "NAME (2)", and so on.
func _unique_name(wanted: String) -> String:
	var taken: Array = _scan_names()
	if not taken.has(wanted):
		return wanted
	var n: int = 2
	while taken.has("%s (%d)" % [wanted, n]):
		n += 1
	return "%s (%d)" % [wanted, n]

func _new_path() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var base: String = "transition_%04d%02d%02d_%02d%02d%02d" % [dt["year"], dt["month"], dt["day"], dt["hour"], dt["minute"], dt["second"]]
	var path: String = "%s/%s.cfg" % [SCREENSAVER_DIR, base]
	var n: int = 2
	while FileAccess.file_exists(path):
		path = "%s/%s_%d.cfg" % [SCREENSAVER_DIR, base, n]
		n += 1
	return path

## Stores which formulas are active, in order, every one of their uniform values (the peaks for
## animated ones), and the duration you were testing at.
func _save_current(raw_name: String) -> void:
	var preset_name: String = raw_name.strip_edges().left(NAME_MAX_LENGTH)
	if preset_name == "":
		preset_name = _default_name()
	preset_name = _unique_name(preset_name)

	var cfg := ConfigFile.new()
	cfg.set_value("preset", "version", 1)
	cfg.set_value("preset", "name", preset_name)
	cfg.set_value("preset", "created", Time.get_datetime_string_from_system())
	cfg.set_value("preset", "duration_sec", float(TIMES[time_idx]))
	cfg.set_value("effect", "stack", active.duplicate())
	for rec in _records:
		cfg.set_value("effect", rec["name"], peak_values[rec["name"]])

	DirAccess.make_dir_recursive_absolute(SCREENSAVER_DIR)
	var err: int = cfg.save(_new_path())
	_end_typing()
	_close_save_session()
	_say(("SAVED: %s" % preset_name) if err == OK else "COULD NOT SAVE (ERROR %d)" % err)

func _scan_transition_presets() -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(SCREENSAVER_DIR):
		return out
	for f in DirAccess.get_files_at(SCREENSAVER_DIR):
		if not f.ends_with(".cfg"):
			continue
		var path: String = "%s/%s" % [SCREENSAVER_DIR, f]
		var cfg := ConfigFile.new()
		if cfg.load(path) != OK or not cfg.has_section("preset"):
			continue
		out.append({"file": path, "name": str(cfg.get_value("preset", "name", f.get_basename())),
				"created": str(cfg.get_value("preset", "created", ""))})
	out.sort_custom(func(a, b): return a["created"] > b["created"])
	return out

func _open_load_list() -> void:
	_load_entries = _scan_transition_presets()
	_load_cursor = 0
	mode = M.LOAD_LIST

## Unknown formulas are skipped, and every value is clamped to its uniform's range, so an older
## transition preset keeps working if a formula's tags change later.
func _load_transition_preset(entry: Dictionary) -> void:
	var cfg := ConfigFile.new()
	if cfg.load(entry["file"]) != OK:
		_say("COULD NOT READ THAT FILE")
		return
	var stack = cfg.get_value("effect", "stack", [])
	var ids: Array = []
	if stack is Array:
		for id in stack:
			if formulas.has(id) and not ids.has(id):
				ids.append(id)
	active = ids
	peak_values.clear()
	if cfg.has_section("effect"):
		for key in cfg.get_section_keys("effect"):
			if key != "stack":
				peak_values[key] = cfg.get_value("effect", key)

	var duration: float = float(cfg.get_value("preset", "duration_sec", TIMES[time_idx]))
	var best_idx: int = time_idx
	var best_diff: float = INF
	for i in range(TIMES.size()):
		var d: float = absf(float(TIMES[i]) - duration)
		if d < best_diff:
			best_diff = d
			best_idx = i
	time_idx = best_idx

	_rebuild_effect() # fills in defaults for any uniform the file didn't have
	for rec in _records:
		var v: Variant = peak_values[rec["name"]]
		if rec["type"] == "float":
			peak_values[rec["name"]] = clampf(float(v), rec["min"], rec["max"])
		else:
			for c in range(rec["channels"].size()):
				v = _set_comp(v, rec["type"], c, clampf(_get_comp(v, rec["type"], c), rec["min"], rec["max"]))
			peak_values[rec["name"]] = v
	_apply_rest_values()
	_say("LOADED: %s" % String(entry["name"]))


func _formula_ids() -> Array:
	return formulas.keys()

func _uniforms_of(id: String) -> Array:
	var out: Array = []
	for rec in _records:
		if rec["formula"] == id:
			out.append(rec)
	return out

func handle_vertical(step: int) -> void:
	if saving:
		return
	if mode == M.TWEAK_COLOR:
		return
	match mode:
		M.FORMULAS:
			_cursor_formula = posmod(_cursor_formula + step, _formula_ids().size() + 2)
		M.UNIFORMS:
			_cursor_uniform = posmod(_cursor_uniform + step, _uniforms_of(_formula_id).size() + 1)
		M.CHANNELS:
			_channel_idx = posmod(_channel_idx + step, _uniforms_of(_formula_id)[_uniform_idx]["channels"].size())
		M.TWEAK:
			_tweak_row = posmod(_tweak_row + step, 2)
		M.LOAD_LIST:
			if not _load_entries.is_empty():
				_load_cursor = posmod(_load_cursor + step, _load_entries.size())
	redraw()

## In the load list, left / right asks to delete the highlighted preset (same as the animation Load list).
func handle_horizontal(step: int) -> void:
	if saving:
		return
	if mode == M.TWEAK_COLOR:
		return
	if mode == M.LOAD_LIST:
		if not _load_entries.is_empty():
			mode = M.CONFIRM_DELETE
			redraw()
		return
	if mode != M.TWEAK:
		return
	var rec: Dictionary = _uniforms_of(_formula_id)[_uniform_idx]
	var ladder: Array = _ladder(rec)
	if _tweak_row == 0:
		var current: Variant = peak_values[rec["name"]]
		var comp: float = _get_comp(current, rec["type"], _channel_idx) + float(step) * float(ladder[_sens_idx])
		comp = snappedf(clampf(comp, rec["min"], rec["max"]), 0.000001)
		peak_values[rec["name"]] = _set_comp(current, rec["type"], _channel_idx, comp)
		if _material != null and not rec["animated"]:
			_material.set_shader_parameter(rec["name"], peak_values[rec["name"]])
	else:
		_sens_idx = clampi(_sens_idx + step, 0, ladder.size() - 1)
		_sens_memory[rec["name"]] = _sens_idx
	redraw()

func handle_a() -> void:
	if saving:
		_save_current(_name_edit.text if is_instance_valid(_name_edit) else "")
		return
	match mode:
		M.FORMULAS:
			var ids: Array = _formula_ids()
			if _cursor_formula == ids.size():
				# [ LOAD TRANSITION PRESET ]
				_open_load_list()
			elif _cursor_formula == ids.size() + 1:
				# [ REMOVE ALL FORMULAS ]
				active.clear()
				peak_values.clear()
				_rebuild_effect()
			else:
				_formula_id = ids[_cursor_formula]
				if not active.has(_formula_id):
					active.append(_formula_id)
					_rebuild_effect()
				mode = M.UNIFORMS
				_cursor_uniform = 1
		M.UNIFORMS:
			if _cursor_uniform == 0:
				active.erase(_formula_id)
				for rec in _uniforms_of(_formula_id):
					peak_values.erase(rec["name"])
				_rebuild_effect()
				mode = M.FORMULAS
			else:
				_uniform_idx = _cursor_uniform - 1
				_channel_idx = 0
				var rec: Dictionary = _uniforms_of(_formula_id)[_uniform_idx]
				if rec["type"] == "vec4":
					_enter_color_picker(rec)
				elif rec["channels"].size() == 1:
					_enter_tweak(rec)
				else:
					mode = M.CHANNELS
		M.CHANNELS:
			_enter_tweak(_uniforms_of(_formula_id)[_uniform_idx])
		M.TWEAK:
			return
		M.TWEAK_COLOR:
			return # the picker's own ✕ button is the only way out, by design
		M.LOAD_LIST:
			if not _load_entries.is_empty():
				_load_transition_preset(_load_entries[_load_cursor])
				mode = M.FORMULAS
				_cursor_formula = 0
		M.CONFIRM_DELETE:
			var entry: Dictionary = _load_entries[_load_cursor]
			DirAccess.remove_absolute(entry["file"])
			_load_entries = _scan_transition_presets()
			_load_cursor = clampi(_load_cursor, 0, maxi(_load_entries.size() - 1, 0))
			mode = M.LOAD_LIST
			_say("DELETED")
	redraw()


## A vec4 uniform is always a color (never animated -- @rest only applies to float), so it skips
## Channels/Tweak entirely and goes straight to the shared picker, same as a Tier 3 shader color.
func _enter_color_picker(rec: Dictionary) -> void:
	mode = M.TWEAK_COLOR
	var u_name: String = rec["name"]
	owner_menu.picker.open(peak_values[u_name], func(c: Color) -> void:
		peak_values[u_name] = c
		if _material != null:
			_material.set_shader_parameter(u_name, c)
	, _on_color_picker_done)

func _on_color_picker_done() -> void:
	mode = M.UNIFORMS
	redraw()


func _enter_tweak(rec: Dictionary) -> void:
	_tweak_row = 0
	_sens_idx = clampi(int(_sens_memory.get(rec["name"], SENS_DEFAULT_INDEX)), 0, 4)
	mode = M.TWEAK

## Returns true when the lab menu is closed (nothing for the caller to redraw: it closes itself).
func handle_b() -> bool:
	if saving:
		_end_typing()
		_close_save_session()
		return false
	if mode == M.TWEAK_COLOR:
		return false
	match mode:
		M.TWEAK:
			var rec: Dictionary = _uniforms_of(_formula_id)[_uniform_idx]
			mode = M.UNIFORMS if rec["channels"].size() == 1 else M.CHANNELS
		M.CHANNELS:
			mode = M.UNIFORMS
		M.UNIFORMS:
			mode = M.FORMULAS
		M.LOAD_LIST:
			mode = M.FORMULAS
		M.CONFIRM_DELETE:
			mode = M.LOAD_LIST
		M.FORMULAS:
			_close_menu()
			return false
	redraw()
	return false

func _ladder(rec: Dictionary) -> Array:
	var s: float = rec["sens"]
	return [s * 0.1, s * 0.5, s, s * 5.0, s * 10.0]


# =========================================================================
# DRAWING (uses MainManager's menu helpers so it looks like the other menus)
# =========================================================================
func redraw() -> void:
	if not is_instance_valid(main.menu_list_box):
		return
	for child in main.menu_list_box.get_children():
		child.queue_free()
	_name_edit = null
	if saving:
		_draw_save()
		return
	match mode:
		M.FORMULAS:
			_draw_formulas()
		M.UNIFORMS:
			_draw_uniforms()
		M.CHANNELS:
			_draw_channels()
		M.TWEAK:
			_draw_tweak()
		M.TWEAK_COLOR:
			pass # the picker draws itself in its own overlay; the list underneath stays frozen
		M.LOAD_LIST:
			_draw_load_list()
		M.CONFIRM_DELETE:
			_draw_confirm_delete()

func _add_label(text: String, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", color)
	main.menu_list_box.add_child(lbl)

func _draw_window(rows: Array, cursor: int, gold_rows: Array) -> void:
	var start: int = main._window_start(rows.size(), cursor)
	var stop: int = mini(start + main.MENU_PAGE_ROWS, rows.size())
	var scrolling: bool = rows.size() > main.MENU_PAGE_ROWS
	if scrolling: main._add_scroll_hint(start > 0, "▲")
	for i in range(start, stop):
		var gold: bool = gold_rows.has(i)
		main._add_menu_row(rows[i], i == cursor, Color.WHITE if gold else Color.YELLOW, Color.LIGHT_GOLDENROD if gold else Color.DARK_GRAY)
	if scrolling: main._add_scroll_hint(stop < rows.size(), "▼")

func _draw_formulas() -> void:
	_add_label(" 🌀 TRANSITION FORMULAS ", Color.CHARTREUSE)
	var rows: Array = []
	for id in _formula_ids():
		rows.append(("● " if active.has(id) else "○ ") + String(formulas[id]["name"]))
	var load_idx: int = rows.size()
	rows.append("[ LOAD TRANSITION PRESET ]")
	var remove_idx: int = rows.size()
	rows.append("[ REMOVE ALL FORMULAS ]")
	_draw_window(rows, _cursor_formula, [load_idx, remove_idx])


func _draw_uniforms() -> void:
	_add_label(" 🌀 %s " % String(formulas[_formula_id]["name"]), Color.CYAN)
	var rows: Array = ["[ REMOVE THIS FORMULA ]"]
	for rec in _uniforms_of(_formula_id):
		var shown: String = String(rec["label"]).to_upper()
		if rec["type"] == "float":
			shown += "  [%s]" % main._fmt(float(peak_values[rec["name"]]))
		if rec["animated"]:
			shown += " ▲"
		rows.append(shown)
	_draw_window(rows, _cursor_uniform, [0]) # row 0 removes the formula
	_add_label(" ▲ = MOVES DURING A TRANSITION ", Color.DIM_GRAY)

func _draw_channels() -> void:
	var rec: Dictionary = _uniforms_of(_formula_id)[_uniform_idx]
	_add_label(" %s: SELECT PARAMETER " % String(rec["label"]).to_upper(), Color.MAGENTA)
	var current: Variant = peak_values[rec["name"]]
	var names: Array = rec["channels"]
	for i in range(names.size()):
		main._add_menu_row("%s   [ %s ]" % [names[i], main._fmt(_get_comp(current, rec["type"], i))], i == _channel_idx)

func _draw_save() -> void:
	_add_label(" 💾 SAVE TRANSITION PRESET ", Color.CHARTREUSE)
	_add_label(" %d ACTIVE FORMULA(S)  ·  %d S " % [active.size(), int(TIMES[time_idx])], Color.DIM_GRAY)
	_add_label(" NAME (TAP THE NAME TO CHANGE IT) ", Color.DIM_GRAY)

	_name_edit = LineEdit.new()
	_name_edit.text = _default_name()
	_name_edit.max_length = NAME_MAX_LENGTH
	_name_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_edit.custom_minimum_size = Vector2(300, 52)
	_name_edit.select_all_on_focus = true
	_name_edit.text_submitted.connect(_save_current)
	_name_edit.focus_entered.connect(_on_typing_started)
	_name_edit.focus_exited.connect(_on_typing_stopped)
	main.menu_list_box.add_child(_name_edit)

	_add_label(" A OR KEYBOARD DONE = SAVE ", Color.YELLOW)
	_add_label(" B = CANCEL ", Color.DARK_GRAY)

func _draw_load_list() -> void:
	_add_label(" 📂 LOAD TRANSITION PRESET ", Color.CYAN)
	if _load_entries.is_empty():
		_add_label("    [ NO SAVED TRANSITIONS YET ]    ", Color.DARK_GRAY)
		return
	var names: Array = []
	for e in _load_entries:
		names.append(String(e["name"]))
	_draw_window(names, _load_cursor, [])
	_add_label(" ✔️ = LOADS    ◄ ► DELETES ", Color.DIM_GRAY)

func _draw_confirm_delete() -> void:
	_add_label(" DELETE THIS TRANSITION? ", Color.ORANGE)
	_add_label(String(_load_entries[_load_cursor]["name"]), Color.WHITE)
	_add_label(" ✔️ = YES, DELETE    ❌ = CANCEL ", Color.YELLOW)

func _draw_tweak() -> void:
	var rec: Dictionary = _uniforms_of(_formula_id)[_uniform_idx]
	var names: Array = rec["channels"]
	var value: float = _get_comp(peak_values[rec["name"]], rec["type"], _channel_idx)
	var ladder: Array = _ladder(rec)
	var title: String = String(rec["label"]).to_upper()
	if names.size() > 1:
		title += "  ·  " + String(names[_channel_idx])
	_add_label(" +═ TRANSITION TWEAK ═+ ", Color.ORANGE)
	_add_label(" ║ NAME: %s " % title, Color.WHITE)
	var value_word: String = "PEAK " if rec["animated"] else "VALUE"
	if _tweak_row == 0:
		_add_label(" ▶ ║ %s: ◄ [ %s ] ► " % [value_word, main._fmt(value)], Color.YELLOW)
		_add_label("    ║ SENS :   [ %s ]   " % main._fmt(float(ladder[_sens_idx])), Color.DARK_GRAY)
	else:
		_add_label("    ║ %s:   [ %s ]   " % [value_word, main._fmt(value)], Color.DARK_GRAY)
		_add_label(" ▶ ║ SENS : ◄ [ %s ] ► " % main._fmt(float(ladder[_sens_idx])), Color.YELLOW)
	_add_label(" ║                            ║ ", Color.DARK_GRAY)
	if rec["animated"]:
		_add_label(" ║ REST VAL : [ %s ]   ║ " % main._fmt(float(rec["rest"])), Color.DIM_GRAY)
	else:
		var d: float = _get_comp(rec["default"], rec["type"], _channel_idx)
		_add_label(" ║ DEFAULT VAL : [ %s ]   ║ " % main._fmt(d), Color.DIM_GRAY)
	_add_label(" ║ RECOMMENDED SENS: [ %s ]   ║ " % main._fmt(float(rec["sens"])), Color.DIM_GRAY)
	_add_label(" +════════════════════════════+ ", Color.ORANGE)


# =========================================================================
# THE STARTER FORMULAS
# =========================================================================
func _register_formulas() -> void:
	_add_formula("swirl", "SWIRL", "warp", SRC_SWIRL)
	_add_formula("fisheye", "FISHEYE", "warp", SRC_FISHEYE)
	_add_formula("ripple", "RIPPLE", "warp", SRC_RIPPLE)
	_add_formula("pixelate", "PIXELATE", "warp", SRC_PIXELATE)
	_add_formula("zoom", "ZOOM", "warp", SRC_ZOOM)
	_add_formula("flash", "COLOR DIP", "color", SRC_FLASH)
	_add_formula("tunnel", "TUNNEL PULL", "warp", SRC_TUNNEL)
	_add_formula("slice", "SLICE JITTER", "warp", SRC_SLICE)
	_add_formula("dissolve", "NOISE DISSOLVE", "color", SRC_DISSOLVE)
	_add_formula("chroma", "CHROMA SPLIT", "color", SRC_CHROMA)
	_add_formula("petals", "PETAL WARP", "warp", SRC_PETALS)
	_add_formula("scanroll", "SCANLINE ROLL", "warp", SRC_SCANROLL)
	_add_formula("invert", "COLOR INVERT", "color", SRC_INVERT)
	_add_formula("huerotate", "HUE ROTATE", "color", SRC_HUEROTATE)
	_add_formula("duotone", "DUOTONE OVERRIDE", "color", SRC_DUOTONE)
	_add_formula("solarize", "SOLARIZE", "color", SRC_SOLARIZE)
	_add_formula("string_pi", "STRING / PI / WARP", "warp", _Lib.SRC_STRING_PI)
	_add_formula("complex_inversion", "COMPLEX / INVERSION", "warp", _Lib.SRC_COMPLEX_INVERSION)
	_add_formula("hyperbolic", "HYPERBOLIC / SINGULARITY", "warp", _Lib.SRC_HYPERBOLIC)
	_add_formula("tangent_fold", "TANGENT / FOLD", "warp", _Lib.SRC_TANGENT_FOLD)
	_add_formula("vector_field", "VECTOR FIELD / FLOW", "warp", _Lib.SRC_VECTOR_FIELD)
	_add_formula("log_spiral", "LOGARITHMIC / SPIRAL", "warp", _Lib.SRC_LOG_SPIRAL)
	_add_formula("mobius", "MOBIUS / COMPLEX MAP", "warp", _Lib.SRC_MOBIUS)
	_add_formula("power_warp", "POWER / RADIAL WARP", "warp", _Lib.SRC_POWER_WARP)
	_add_formula("exponential_warp", "EXPONENTIAL STRETCH", "warp", _Lib.SRC_EXPONENTIAL_WARP)

	

func _add_formula(id: String, display_name: String, kind: String, source: String) -> void:
	formulas[id] = {"id": id, "name": display_name, "kind": kind, "source": source}

const SRC_SWIRL: String = """
uniform float u_strength = 8.0; // @label Twist Strength | @min -40 | @max 40 | @sens 0.5 | @rest 0
uniform float u_radius = 0.7; // @label Radius | @min 0.1 | @max 1.5 | @sens 0.02
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_swirl(vec2 uv) {
	vec2 p = uv - u_center;
	float falloff = 1.0 - smoothstep(0.0, u_radius, length(p));
	float ang = u_strength * falloff * falloff;
	float s = sin(ang);
	float k = cos(ang);
	return vec2(k * p.x - s * p.y, s * p.x + k * p.y) + u_center;
}
"""

const SRC_FISHEYE: String = """
uniform float u_bulge = 2.500; // @label Bulge Strength | @min -6.0 | @max 6 | @sens 0.100 | @rest 0
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_fisheye(vec2 uv) {
	vec2 p = uv - u_center;
	float r2 = dot(p, p);
	return u_center + p * (1.0 + u_bulge * r2 * 4.0);
}
"""

const SRC_RIPPLE: String = """
uniform float u_amount = 0.04; // @label Ripple Amount | @min 0 | @max 0.3 | @sens 0.004 | @rest 0
uniform float u_frequency = 24.0; // @label Frequency | @min 2 | @max 90 | @sens 1
uniform float u_speed = 4.0; // @label Wave Speed | @min 0 | @max 20 | @sens 0.25

vec2 fx_ripple(vec2 uv) {
	vec2 p = uv - vec2(0.5);
	float d = length(p);
	vec2 dir = p / max(d, 0.0001);
	return uv + dir * sin(d * u_frequency - u_time * u_speed) * u_amount;
}
"""

const SRC_PIXELATE: String = """
uniform float u_block = 0.1; // @label Block Size | @min 0 | @max 0.5 | @sens 0.005 | @rest 0

vec2 fx_pixelate(vec2 uv) {
	if (u_block < 0.002) {
		return uv;
	}
	return (floor(uv / u_block) + 0.5) * u_block;
}
"""

const SRC_ZOOM: String = """
uniform float u_zoom = 1.5; // @label Zoom Amount | @min -0.8 | @max 10 | @sens 0.1 | @rest 0
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_zoom(vec2 uv) {
	vec2 p = uv - u_center;
	return u_center + p / max(1.0 + u_zoom, 0.05);
}
"""

const SRC_FLASH: String = """
uniform float u_dip = 1.0; // @label Dip Amount | @min 0 | @max 1 | @sens 0.05 | @rest 0
uniform vec4 u_dip_color : source_color = vec4(0.0, 0.0, 0.0, 1.0); // @label Dip Color | @min 0 | @max 1 | @sens 0.02

vec4 fx_flash(vec4 c, vec2 uv, sampler2D screen) {
	return vec4(mix(c.rgb, u_dip_color.rgb, u_dip), c.a);
}
"""

const SRC_TUNNEL: String = """
uniform float u_pull = 3.5; // @label Tunnel Pull | @min -20 | @max 20 | @sens 0.2 | @rest 0
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_tunnel(vec2 uv) {
	vec2 p = uv - u_center;
	float r = length(p);
	float a = atan(p.y, p.x);
	float new_r = pow(max(r, 0.0001), 1.0 / (1.0 + abs(u_pull) * 0.3));
	if (u_pull < 0.0) {
		new_r = r + (r - new_r);
	}
	return u_center + vec2(cos(a), sin(a)) * new_r;
}
"""

const SRC_SLICE: String = """
uniform float u_amount = 0.25; // @label Slice Amount | @min 0 | @max 1 | @sens 0.02 | @rest 0
uniform float u_bands = 14.0; // @label Band Count | @min 2 | @max 60 | @sens 1
uniform float u_seed = 7.0; // @label Random Seed | @min 0 | @max 100 | @sens 1

float slice_hash(float n) { return fract(sin(n * 12.9898 + u_seed) * 43758.5453); }

vec2 fx_slice(vec2 uv) {
	float band = floor(uv.y * u_bands);
	float off = (slice_hash(band) - 0.5) * u_amount;
	return vec2(uv.x + off, uv.y);
}
"""

const SRC_DISSOLVE: String = """
uniform float u_amount = 1.0; // @label Dissolve Amount | @min 0 | @max 1 | @sens 0.05 | @rest 0
uniform float u_scale = 40.0; // @label Noise Scale | @min 4 | @max 150 | @sens 1

float dissolve_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123); }

vec4 fx_dissolve(vec4 c, vec2 uv, sampler2D screen) {
	float n = dissolve_hash(floor(uv * u_scale));
	float cut = step(n, u_amount);
	return vec4(c.rgb * (1.0 - cut), c.a);
}
"""

const SRC_CHROMA: String = """
uniform float u_shift = 0.02; // @label Channel Shift | @min 0 | @max 0.1 | @sens 0.002 | @rest 0
uniform vec2 u_direction = vec2(1.0, 0.0); // @label Shift Direction | @min -1 | @max 1 | @sens 0.05

vec4 fx_chroma(vec4 c, vec2 uv, sampler2D screen) {
	vec2 off = normalize(u_direction + vec2(0.0001)) * u_shift;
	float r = texture(screen, tatool_mirror(uv + off)).r;
	float b = texture(screen, tatool_mirror(uv - off)).b;
	return vec4(r, c.g, b, c.a);
}
"""

const SRC_PETALS: String = """
uniform float u_amount = 6.0; // @label Petal Warp | @min -20 | @max 20 | @sens 0.25 | @rest 0
uniform float u_petals = 5.0; // @label Petal Count | @min 2 | @max 16 | @sens 1
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_petals(vec2 uv) {
	vec2 p = uv - u_center;
	float r = length(p);
	float a = atan(p.y, p.x);
	float push = sin(a * u_petals) * u_amount * 0.02;
	return u_center + p * (1.0 + push / max(r, 0.05));
}
"""

const SRC_SCANROLL: String = """
uniform float u_amount = 0.06; // @label Roll Amount | @min 0 | @max 0.3 | @sens 0.005 | @rest 0
uniform float u_speed = 6.0; // @label Roll Speed | @min 0 | @max 30 | @sens 0.5

vec2 fx_scanroll(vec2 uv) {
	float wobble = sin(uv.y * 60.0 + u_time * u_speed) * u_amount;
	return vec2(uv.x + wobble * (1.0 - abs(uv.y - 0.5) * 2.0), uv.y);
}
"""

const SRC_INVERT: String = """
uniform float u_amount = 1.0; // @label Invert Amount | @min 0 | @max 1 | @sens 0.05 | @rest 0

vec4 fx_invert(vec4 c, vec2 uv, sampler2D screen) {
	return vec4(mix(c.rgb, vec3(1.0) - c.rgb, u_amount), c.a);
}
"""

const SRC_HUEROTATE: String = """
uniform float u_angle = 180.0; // @label Hue Rotation | @min -360 | @max 360 | @sens 5 | @rest 0

vec3 huerot_rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}
vec3 huerot_hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}
vec4 fx_huerotate(vec4 c, vec2 uv, sampler2D screen) {
	vec3 hsv = huerot_rgb2hsv(c.rgb);
	hsv.x = fract(hsv.x + u_angle / 360.0);
	return vec4(huerot_hsv2rgb(hsv), c.a);
}
"""

const SRC_DUOTONE: String = """
uniform float u_amount = 1.0; // @label Duotone Amount | @min 0 | @max 1 | @sens 0.05 | @rest 0
uniform vec4 u_shadow_color : source_color = vec4(0.05, 0.0, 0.15, 1.0); // @label Shadow Color | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_highlight_color : source_color = vec4(1.0, 0.8, 0.2, 1.0); // @label Highlight Color | @min 0 | @max 1 | @sens 0.02

vec4 fx_duotone(vec4 c, vec2 uv, sampler2D screen) {
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	vec3 toned = mix(u_shadow_color.rgb, u_highlight_color.rgb, lum);
	return vec4(mix(c.rgb, toned, u_amount), c.a);
}
"""

const SRC_SOLARIZE: String = """
uniform float u_amount = 1.0; // @label Solarize Amount | @min 0 | @max 1 | @sens 0.05 | @rest 0

vec4 fx_solarize(vec4 c, vec2 uv, sampler2D screen) {
	float threshold = mix(1.0, 0.35, u_amount);
	float m = max(max(c.r, c.g), c.b);
	vec3 solarized = mix(c.rgb, vec3(1.0) - c.rgb, step(threshold, m));
	return vec4(mix(c.rgb, solarized, u_amount), c.a);
}
"""
