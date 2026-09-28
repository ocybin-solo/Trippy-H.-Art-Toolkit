extends RefCounted
## OptionsMenu.gd -- TATOOL app options (System Main Menu > APP CONFIG OPTIONS)
## Colors (background + button colors) and Controller Layout (drag-and-drop button positions, screen flip,
## icon and menu rotation, screen orientation).
## It owns PresetsMenu.gd and ControllerLayout.gd, so DynamicUI only ever talks to this one object.
## Everything is saved to user:// and re-applied at launch.
##
## The menu is driven by TREE. Row kinds:
##   "go"     open the submenu named in "target"
##   (the Controller Layout screens are built on the fly from ControllerLayout: see _rows_for())
##   "color"  edit the color stored under "key" (channel picker, then tweak console)
##   "action" run a named action
## DynamicUI forwards D-pad / A / B to this object while is_active() is true.

const SETTINGS_PATH: String = "user://tatool_settings.cfg"
const SENS_LADDER: Array = [0.002, 0.01, 0.02, 0.1, 0.2] # index 2 is the recommended step
const DEFAULT_SENS_INDEX: int = 2
const BUTTON_STATES: Array = ["normal", "hover", "pressed", "hover_pressed"]

enum Mode { LIST, CHANNEL, TWEAK, REPOSITION, COLOR_PICKER }

const ANCHOR_DEFS: Dictionary = {
	"shader_center": {"label": "SHADER POSITION", "channels": ["X", "Y"]},
	"menu_center": {"label": "MENU POSITION", "channels": ["X", "Y"]},
}

func _def_for(key: String) -> Dictionary:
	return COLOR_DEFS[key] if COLOR_DEFS.has(key) else ANCHOR_DEFS[key]


const TREE: Dictionary = {
	"root": {
		"title": " ⚙ APP CONFIG OPTIONS ",
		"rows": [
			{"label": "COLORS", "kind": "go", "target": "colors"},
			{"label": "CONTROLLER LAYOUT", "kind": "go", "target": "layout"},
		],
	},
	"colors": {
		"title": " 🎨 COLORS ",
		"rows": [
			{"label": "BACKGROUND COLOR", "kind": "color", "key": "bg_color"},
			{"label": "BUTTON COLOR", "kind": "color", "key": "button_color"},
			{"label": "[ RESET COLORS TO DEFAULT ]", "kind": "action", "action": "reset_colors"},
		],
	},
	# "layout", "icons", "icon_actions" and "menu_orient" are built at runtime by _rows_for() / _title_for()
}

 #Background alpha has no visible effect on a window clear color, so it only gets R, G, B.
const COLOR_DEFS: Dictionary = {
	"bg_color": {"label": "BACKGROUND", "channels": ["R", "G", "B"]},
	"button_color": {"label": "BUTTON", "channels": ["R", "G", "B", "A"]},
}

var main # MainManager (owner of the menu panel and drawing helpers)

var settings: Dictionary = {}
var defaults: Dictionary = {}
var custom: Dictionary = {"bg_color": false, "button_color": false}

var is_open: bool = false
var _panel_ref: Object = null
var mode: int = Mode.LIST
var node_stack: Array = []
var cursors: Dictionary = {}
var active_key: String = ""
var channel_idx: int = 0
var tweak_row: int = 0
var sens_idx: int = DEFAULT_SENS_INDEX

var presets # PresetsMenu.gd (System Main Menu > PRESETS)
var lab # TransitionLab.gd (System Main Menu > SCREENSAVER DEV, and the OPT lab menu)
var saver # ScreensaverMode.gd (System Main Menu > START SCREENSAVER)
var help # HelpViewer.gd (System Main Menu > HELP)

var layout # ControllerLayout.gd (button grid, orientation, swaps, screen flip, icons)
var ctx_button: String = "" # the button chosen in the icon list
var picker # ColorPickerOverlay.gd (shared by shader vec4 uniforms and bg_color/button_color)

# =========================================================================
# SETUP / PERSISTENCE
# =========================================================================
func setup(main_manager) -> void:
	main = main_manager
	presets = load("res://PresetsMenu.gd").new()
	presets.setup(main, self)
	# Capture what the app looks like BEFORE any customization so RESET can restore it
	defaults["bg_color"] = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color", Color(0.3, 0.3, 0.3, 1.0))
	defaults["button_color"] = _read_default_button_color()
	settings["bg_color"] = defaults["bg_color"]
	settings["button_color"] = defaults["button_color"]
	_load_settings()
	layout = load("res://ControllerLayout.gd").new()
	layout.setup(main, self) # builds every grid button, incl. the hide-menu one -- must run before _apply_all()
	picker = load("res://ColorPickerOverlay.gd").new()
	picker.setup(main, self)
	_apply_all()
	lab = load("res://TransitionLab.gd").new()
	main.add_child(lab) # a Node, so it can run every frame during a transition
	lab.setup(main, self)
	saver = load("res://ScreensaverMode.gd").new()
	main.add_child(saver)
	saver.setup(main, self)
	help = load("res://HelpViewer.gd").new()
	main.add_child(help)
	help.setup(main, self)

func _read_default_button_color() -> Color:
	var buttons: Array = _collect_buttons(main.ui_canvas_layer)
	if not buttons.is_empty():
		var sb: StyleBox = buttons[0].get_theme_stylebox("normal")
		if sb is StyleBoxFlat:
			return (sb as StyleBoxFlat).bg_color
	return Color(0.1, 0.1, 0.1, 0.6)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for key in ["bg_color", "button_color"]:
		if cfg.get_value("colors", key + "_custom", false):
			var c = cfg.get_value("colors", key, settings[key])
			if c is Color:
				settings[key] = c
				custom[key] = true

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep the sections owned by ControllerLayout and PresetsMenu
	for key in ["bg_color", "button_color"]:
		cfg.set_value("colors", key + "_custom", custom[key])
		cfg.set_value("colors", key, settings[key])
	cfg.save(SETTINGS_PATH)


# =========================================================================
# APPLYING COLORS
# =========================================================================
func _apply_all() -> void:
	_apply_background()
	_apply_buttons()

## Background = the window color behind the whole console (the shader display is unaffected).
func _apply_background() -> void:
	var c: Color = settings["bg_color"]
	RenderingServer.set_default_clear_color(Color(c.r, c.g, c.b, 1.0))

func _collect_buttons(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is Button:
			out.append(child)
		out.append_array(_collect_buttons(child))
	return out

## Hover and pressed are simply shades of the chosen button color.
func _state_color(base: Color, state: String) -> Color:
	match state:
		"hover":
			return base.lightened(0.15)
		"pressed":
			return base.darkened(0.25)
		"hover_pressed":
			return base.darkened(0.15)
	return base

func _apply_buttons() -> void:
	var buttons: Array = _collect_buttons(main.ui_canvas_layer)
	if not custom["button_color"]:
		# Untouched (or reset): only undo styles this menu added, never anything else
		for btn in buttons:
			if btn.has_meta("tatool_styled"):
				for state in BUTTON_STATES:
					btn.remove_theme_stylebox_override(state)
				btn.remove_meta("tatool_styled")
		return

	var base: Color = settings["button_color"]
	for btn in buttons:
		for state in BUTTON_STATES:
			var sb: StyleBoxFlat = null
			if btn.has_theme_stylebox_override(state):
				sb = btn.get_theme_stylebox(state) as StyleBoxFlat
			if sb == null:
				# Start from the button's current style so its shape and margins stay the same
				var src: StyleBox = btn.get_theme_stylebox(state)
				if src is StyleBoxFlat:
					sb = src.duplicate() as StyleBoxFlat
				else:
					sb = StyleBoxFlat.new()
					sb.set_corner_radius_all(4)
				btn.add_theme_stylebox_override(state, sb)
			sb.bg_color = _state_color(base, state)
		btn.set_meta("tatool_styled", true)

func _get_channel(key: String, idx: int) -> float:
	return layout.anchor_value(key, idx)

func _set_channel(key: String, idx: int, v: float) -> void:
	layout.set_anchor_value(key, idx, v)
	
	
func _on_picker_color_changed(c: Color) -> void:
	settings[active_key] = c
	custom[active_key] = true
	if active_key == "bg_color":
		_apply_background()
	else:
		_apply_buttons()
	_save_settings()

func _on_picker_color_done() -> void:
	mode = Mode.LIST
	redraw()

func _default_channel(key: String, idx: int) -> float:
	return layout.anchor_default(key, idx)


func _reset_colors() -> void:
	settings["bg_color"] = defaults["bg_color"]
	settings["button_color"] = defaults["button_color"]
	custom["bg_color"] = false
	custom["button_color"] = false
	_apply_all()
	_save_settings()


## Called by PresetsMenu when the name field loses focus: re-check the layout in case the keyboard resized the window.
func notify_typing_done() -> void:
	if layout != null:
		layout.relayout()


# =========================================================================
# OPEN / STATE
# =========================================================================
func open() -> void:
	is_open = true
	mode = Mode.LIST
	node_stack = ["root"]
	cursors.clear()
	main._ensure_cyan_panel() # recycles the System Menu's panel and clears its rows
	_panel_ref = main.menu_overlay_panel
	redraw()

## True only while our own panel is still the one on screen (PWR/OPT closing it makes this false).
func is_active() -> bool:
	if presets != null and presets.is_active():
		return true
	if lab != null and lab.menu_active():
		return true
	return is_open and is_instance_valid(_panel_ref) and main.menu_overlay_panel == _panel_ref

## System Main Menu > PRESETS
func open_presets() -> void:
	presets.open()

## Screensaver developer mode (see TransitionLab.gd)
func dev_mode() -> bool:
	return lab != null and lab.dev_mode

func toggle_dev_mode() -> void:
	if lab != null:
		lab.toggle_dev_mode()

## D-pad / A / B while developer mode is on and no menu is open. Returns true when it handled the press.
func dev_input(action: String) -> bool:
	return lab != null and lab.dev_input(action)

## System Main Menu > START SCREENSAVER. Returns "" on success, or a short reason it could not start.
func start_screensaver() -> String:
	return saver.start() if saver != null else "NOT READY YET"

## A one-line message appended under whichever menu is currently open (used when a menu action fails).
func flash_menu_message(text: String) -> void:
	if not is_instance_valid(main.menu_list_box):
		return
	var lbl := Label.new()
	lbl.text = " ⚠ %s " % text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.ORANGE)
	main.menu_list_box.add_child(lbl)


# =========================================================================
# INPUT (called by DynamicUI)
# =========================================================================
func handle_vertical(step: int) -> void:
	if presets != null and presets.is_active():
		presets.handle_vertical(step)
		return
	if lab != null and lab.menu_active():
		lab.handle_vertical(step)
		return
	if mode == Mode.REPOSITION or mode == Mode.COLOR_PICKER:
		return
	match mode:
		Mode.LIST:
			var node_id: String = node_stack.back()
			var total: int = _rows_for(node_id).size()
			cursors[node_id] = posmod(int(cursors.get(node_id, 0)) + step, total)
		Mode.CHANNEL:
			channel_idx = posmod(channel_idx + step, _def_for(active_key)["channels"].size())
		Mode.TWEAK:
			tweak_row = posmod(tweak_row + step, 2)
	redraw()

func handle_horizontal(step: int) -> void:
	if presets != null and presets.is_active():
		presets.handle_horizontal(step)
		return
	if lab != null and lab.menu_active():
		lab.handle_horizontal(step)
		return
	

	if mode == Mode.LIST and node_stack.back() == "layout":
		var rows: Array = _rows_for("layout")
		var row: Dictionary = rows[clampi(int(cursors.get("layout", 0)), 0, rows.size() - 1)]
		if row["kind"] == "shader_size":
			layout.cycle_shader_size(step)
			redraw()
		elif row["kind"] == "menu_size":
			layout.cycle_menu_size(step)
			redraw()
		elif row["kind"] == "grid_size":
			layout.cycle_grid_size(step)
			redraw()
		return
	if mode != Mode.TWEAK:
		return
	if tweak_row == 0:
		var current: float = _get_channel(active_key, channel_idx)
		_set_channel(active_key, channel_idx, current + float(step) * float(SENS_LADDER[sens_idx]))
	else:
		sens_idx = clampi(sens_idx + step, 0, SENS_LADDER.size() - 1)
	redraw()

func handle_a() -> void:
	if presets != null and presets.is_active():
		presets.handle_a()
		return
	if lab != null and lab.menu_active():
		lab.handle_a()
		return
	if mode == Mode.REPOSITION:
		return
	if mode == Mode.COLOR_PICKER:
		return
	match mode:
		Mode.LIST:
			var node_id: String = node_stack.back()
			var rows: Array = _rows_for(node_id)
			var row: Dictionary = rows[clampi(int(cursors.get(node_id, 0)), 0, rows.size() - 1)]
			var orient: int = layout.current_orient() # layout settings apply to the orientation you are in
			match row["kind"]:
				"go":
					node_stack.append(row["target"])
					cursors[row["target"]] = 0
				"reposition":
					layout.begin_edit()
					mode = Mode.REPOSITION
				"shader_size":
					layout.cycle_shader_size(1)
				"orient_mode":
					layout.set_orient_mode((layout.orient_mode + 1) % 3)
				"reset_layout":
					layout.reset(orient)
				"icon_go":
					ctx_button = row["button"]
					node_stack.append("icon_actions")
					cursors["icon_actions"] = 0
				"icon_flip":
					layout.flip_icon(ctx_button)
				"icon_rotate":
					layout.rotate_icon(ctx_button)
				"menu_flip":
					layout.flip_menu()
				"menu_rotate":
					layout.rotate_menu()
				"color":
					active_key = row["key"]
					mode = Mode.COLOR_PICKER
					picker.open(settings[active_key], _on_picker_color_changed, _on_picker_color_done)
				"anchor":
					active_key = row["key"]
					channel_idx = 0
					mode = Mode.CHANNEL
				"action":
					if row["action"] == "reset_colors":
						_reset_colors()
		Mode.CHANNEL:
			tweak_row = 0
			sens_idx = DEFAULT_SENS_INDEX
			mode = Mode.TWEAK
		Mode.TWEAK:
			return
	redraw()

## Steps back one level. Returns true when the options menu itself is closed
## (the caller then redraws the System Main Menu).
func handle_b() -> bool:
	if presets != null and presets.is_active():
		return presets.handle_b()
	if lab != null and lab.menu_active():
		return lab.handle_b()
	if mode == Mode.REPOSITION or mode == Mode.COLOR_PICKER:
		return false
	match mode:
		Mode.TWEAK:
			mode = Mode.CHANNEL
		Mode.CHANNEL:
			mode = Mode.LIST
		Mode.LIST:
			if node_stack.size() > 1:
				node_stack.pop_back()
			else:
				is_open = false
				_panel_ref = null
				return true
	redraw()
	return false

## Called by ControllerLayout when a Reposition session ends (A tapped: accepted, B tapped: cancelled).
func reposition_finished(_accepted: bool) -> void:
	mode = Mode.LIST
	redraw()


# =========================================================================
# MENU CONTENT: fixed screens come from TREE, the Controller Layout screens are built from ControllerLayout
# =========================================================================
func _rows_for(node_id: String) -> Array:
	match node_id:
		"layout":
			return _layout_rows()
		"icons":
			return _icon_list_rows()
		"icon_actions":
			return _icon_action_rows()
		"menu_orient":
			return _menu_orient_rows()
	return TREE[node_id]["rows"]

func _title_for(node_id: String) -> String:
	match node_id:
		"layout":
			var shape: String = "PORTRAIT" if layout.current_orient() == 1 else "LANDSCAPE"
			return " 🎮 CONTROLLER LAYOUT (%s) " % shape
		"icons":
			return " ROTATE / FLIP BUTTON ICONS "
		"icon_actions":
			return " %s ICON " % layout.button_name(ctx_button)
		"menu_orient":
			return " ROTATE / FLIP MENU "
	return TREE[node_id]["title"]

func _layout_rows() -> Array:
	return [
		{"label": "ROTATE / FLIP BUTTON ICONS", "kind": "go", "target": "icons"},
		{"label": "ROTATE / FLIP MENU  [%s]" % layout.menu_state_text(), "kind": "go", "target": "menu_orient"},
		{"label": "SHADER SIZE  [%d%%]  ◄ ►" % int(round(layout.shader_size() * 100.0)), "kind": "shader_size"},
		{"label": "MENU SIZE  [%d%%]  ◄ ►" % int(round(layout.menu_scale() * 100.0)), "kind": "menu_size"},
		{"label": "GRID SIZE  [%d%%]  ◄ ►" % int(round(layout.grid_scale() * 100.0)), "kind": "grid_size"},		
		{"label": "MOVE SHADER", "kind": "anchor", "key": "shader_center"},
		{"label": "MOVE MENU", "kind": "anchor", "key": "menu_center"},
		{"label": "REPOSITION BUTTONS", "kind": "reposition"},
		{"label": "SCREEN ORIENTATION  [%s]" % layout.ORIENT_MODE_NAMES[layout.orient_mode], "kind": "orient_mode"},
		{"label": "[ RESET LAYOUT TO DEFAULT ]", "kind": "reset_layout"},
	]

## Icon settings are shared across both orientations now, so this list needs no orient argument --
## rotating a button's icon here fixes it in landscape and portrait at once.
func _icon_list_rows() -> Array:
	var rows: Array = []
	for id in layout.ALL_IDS:
		rows.append({"label": "%s  [%s]" % [layout.button_name(id), layout.icon_state_text(id)],
				"kind": "icon_go", "button": id})
	return rows

func _icon_action_rows() -> Array:
	return [
		{"label": "FLIP ICON  [%s]" % ("ON" if layout.icon_flipped(ctx_button) else "OFF"), "kind": "icon_flip"},
		{"label": "ROTATE ICON 90°  [%d°]" % layout.icon_rotation(ctx_button), "kind": "icon_rotate"},
	]

func _menu_orient_rows() -> Array:
	return [
		{"label": "FLIP MENU  [%s]" % ("ON" if layout.menu_flip else "OFF"), "kind": "menu_flip"},
		{"label": "ROTATE MENU 90°  [%d°]" % (layout.menu_rot * 90), "kind": "menu_rotate"},
	]


# =========================================================================
# DRAWING (uses MainManager's menu helpers so it looks like the other menus)
# =========================================================================
func redraw() -> void:
	if not is_instance_valid(main.menu_list_box):
		return
	for child in main.menu_list_box.get_children():
		child.queue_free()
	match mode:
		Mode.LIST:
			_draw_list()
		Mode.CHANNEL:
			_draw_channels()
		Mode.TWEAK:
			_draw_tweak()
		Mode.REPOSITION:
			_draw_reposition()
		Mode.COLOR_PICKER:
			pass # the picker draws itself in its own overlay; the list underneath stays frozen

func _add_label(text: String, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", color)
	main.menu_list_box.add_child(lbl)

func _add_swatch(c: Color) -> void:
	var sw := ColorRect.new()
	sw.custom_minimum_size = Vector2(0, 16)
	sw.color = c
	main.menu_list_box.add_child(sw)

func _draw_list() -> void:
	var node_id: String = node_stack.back()
	_add_label(_title_for(node_id), Color.RED)

	var rows: Array = _rows_for(node_id)
	var cursor: int = clampi(int(cursors.get(node_id, 0)), 0, rows.size() - 1)
	var start: int = main._window_start(rows.size(), cursor)
	var stop: int = mini(start + main.MENU_PAGE_ROWS, rows.size())
	var scrolling: bool = rows.size() > main.MENU_PAGE_ROWS

	if scrolling: main._add_scroll_hint(start > 0, "▲")
	for i in range(start, stop):
		var row: Dictionary = rows[i]
		var gold: bool = row["kind"] == "action" or row["kind"] == "reset_layout"
		var hl: Color = Color.WHITE if gold else Color.YELLOW
		var dim: Color = Color.LIGHT_GOLDENROD if gold else Color.DARK_GRAY
		main._add_menu_row(row["label"], i == cursor, hl, dim)
	if scrolling: main._add_scroll_hint(stop < rows.size(), "▼")
	if node_id == "icon_actions" or node_id == "menu_orient":
		_add_label(" PRESS A TO APPLY ", Color.DIM_GRAY)

func _draw_reposition() -> void:
	_add_label(" ✥ REPOSITION BUTTONS ", Color.CYAN)
	_add_label(" PRESS AND HOLD A BUTTON TO DRAG ", Color.WHITE)
	_add_label(" DRAG ⊕ (SHADER) OR ◇ (MENU) FREELY ", Color.WHITE)
	_add_label(" TAP A TO ACCEPT LAYOUT ", Color.LIME_GREEN)
	_add_label(" TAP B TO CANCEL CHANGES ", Color.TOMATO)
	_add_label(" PRESS AND HOLD EMPTY SPACE TO SLIDE GRID ", Color.WHITE)

func _draw_channels() -> void:
	var def: Dictionary = ANCHOR_DEFS[active_key]
	_add_label(" ◈ %s ◈ SELECT PARAMETER " % def["label"], Color.MAGENTA)
	var names: Array = def["channels"]
	for i in range(names.size()):
		var value_text: String = main._fmt(_get_channel(active_key, i))
		main._add_menu_row("%s   [ %s ]" % [names[i], value_text], i == channel_idx)

func _draw_tweak() -> void:
	var def: Dictionary = ANCHOR_DEFS[active_key]
	var names: Array = def["channels"]
	var value: float = _get_channel(active_key, channel_idx)
	var default_value: float = _default_channel(active_key, channel_idx)
	var sens_now: float = SENS_LADDER[sens_idx]

	_add_label(" +═ TWEAK CONSOLE ═+ ", Color.ORANGE)
	_add_label(" ║ NAME: %s  ·  %s " % [def["label"], names[channel_idx]], Color.WHITE)

	if tweak_row == 0:
		_add_label(" ▶ ║ VALUE: ◄ [ %s ] ► " % main._fmt(value), Color.YELLOW)
		_add_label("    ║ SENS :   [ %s ]   " % main._fmt(sens_now), Color.DARK_GRAY)
	else:
		_add_label("    ║ VALUE:   [ %s ]   " % main._fmt(value), Color.DARK_GRAY)
		_add_label(" ▶ ║ SENS : ◄ [ %s ] ► " % main._fmt(sens_now), Color.YELLOW)

	_add_label(" ║                            ║ ", Color.DARK_GRAY)
	_add_label(" ║ DEFAULT VAL : [ %s ]   ║ " % main._fmt(default_value), Color.DIM_GRAY)
	_add_label(" ║ RECOMMENDED SENS: [ %s ]   ║ " % main._fmt(SENS_LADDER[DEFAULT_SENS_INDEX]), Color.DIM_GRAY)
	_add_label(" +════════════════════════════+ ", Color.ORANGE)

func _opaque_if_background(key: String) -> Color:
	var c: Color = settings[key]
	if key == "bg_color":
		return Color(c.r, c.g, c.b, 1.0)
	return c
	
