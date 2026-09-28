extends RefCounted
## ControllerLayout.gd -- TATOOL controller layout engine (whole-canvas model)
##
## The whole window is one canvas. Three things live on it, each positioned independently:
##   1. The SHADER -- a floating square, pinned to a freely-draggable "Shader Center" anchor (a
##      fraction of the window, not a grid cell), sized by "Shader Size" (a fraction of its natural
##      full size, min(window width, window height)). It can run past the window's edges.
##   2. The BUTTON GRID -- a fixed 7 x 7 grid spanning the whole window (cell index = row * 7 + col),
##      scaled as a whole to fit. Buttons snap to cells; they can sit anywhere, including on top of
##      or beside the shader.
##   3. MENUS -- every menu (Tier 1-5, Options, Presets, etc.) centers on a second freely-draggable
##      anchor, "Menu Center", independent of where the shader sits, so menus never have to fight
##      the shader for space. This is done by moving and resizing MainManager's existing
##      `menu_center_host` so ITS OWN center always sits on that anchor -- no other file needs to
##      know menus moved.
##
## In "Reposition Buttons" mode a transparent overlay (GridEditOverlay.gd) covers the whole canvas:
##   - press and hold a BUTTON to drag it; drop it on an empty cell to move it, a taken cell to swap
##   - press and drag either ANCHOR MARKER (Shader Center: crosshair: Menu Center: diamond) to move
##     it freely -- anchors do NOT snap to the grid
##   - tap A to accept the layout, tap B to cancel the changes
##
## Your own button code (icons, sizes, colors, wiring) is not touched. At startup the existing buttons
## are moved into grid cells and the old layout containers are discarded. Every cell is a plain
## Control, not a Container, because Containers reset a child's rotation and scale, which icon
## rotate/flip needs.
##
## Saved per orientation (landscape / portrait, picked from the window's current shape, no menu gate):
##   pos            button id -> cell index
##   shader_center  fraction of the window (Vector2, 0..1 each axis)
##   menu_center    fraction of the window (Vector2, 0..1 each axis)
##   shader_size    fraction of the shader's natural full size
## Saved once, shared across both orientations:
##   icon_settings  per button [quarter turns 0..3, mirrored] -- a button's icon means the same thing
##                  whichever orientation you're in, so rotating it once fixes it everywhere
##   orient_mode (Auto / Landscape / Portrait), and the menu's own rotation and mirroring


const SETTINGS_PATH: String = "user://tatool_settings.cfg"
const MENU_SIZE_CHOICES: Array = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.3]
const GRID_SIZE_CHOICES: Array = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3]
const COLUMNS: int = 5	
const ROWS: int = 5
const GRID_GAP: int = 4 # pixels between cells
const GRID_PAN_STEP: float = 0.05 # fraction of available slack moved per D-pad tap
const ALL_IDS: Array = ["a", "b", "quick", "main", "up", "down", "left", "right", "vram"]
const BUTTON_NAMES: Dictionary = {
	"a": "A BUTTON", "b": "B BUTTON", "quick": "QUICK MENU BUTTON", "main": "MAIN MENU BUTTON",
	"up": "UP BUTTON", "down": "DOWN BUTTON", "left": "LEFT BUTTON", "right": "RIGHT BUTTON",
	"vram": "HIDE MENU BUTTON",
}
# Landscape default: the old cluster look, shifted into the right third of the wider grid.
const DEFAULT_POS_LANDSCAPE: Dictionary = {
	"a": 7, "quick": 9, "b": 17, "main": 19, "up": 8, "left": 12, "right": 14, "down": 18, "vram": 13,
}
# Portrait default: the same cluster, narrower and shifted to the bottom rows.
const DEFAULT_POS_PORTRAIT: Dictionary = {
	"a": 11, "quick": 21, "b": 13, "main": 23, "up": 12, "left": 16, "right": 18, "down": 22, "vram": 17,
}
const DEFAULT_SHADER_CENTER_LANDSCAPE: Vector2 = Vector2(0.31, 0.5)
const DEFAULT_SHADER_CENTER_PORTRAIT: Vector2 = Vector2(0.5, 0.26)
const DEFAULT_MENU_CENTER_LANDSCAPE: Vector2 = Vector2(0.31, 0.48)
const DEFAULT_MENU_CENTER_PORTRAIT: Vector2 = Vector2(0.5, 0.27)
const DEFAULT_SHADER_SIZE_LANDSCAPE: float = 1.0
const DEFAULT_SHADER_SIZE_PORTRAIT: float = 0.9
const DEFAULT_MENU_SCALE_LANDSCAPE: float = 1.0
const DEFAULT_MENU_SCALE_PORTRAIT: float = 1.0
const DEFAULT_GRID_PAN_LANDSCAPE: float = 0.88
const DEFAULT_GRID_PAN_PORTRAIT: float = 0.82

const ORIENT_MODE_NAMES: Array = ["AUTO", "LANDSCAPE", "PORTRAIT"]
const GRID_FIT_MARGIN: float = 0.95  # shrink the fit slightly so the grid never touches the edges
const GRID_MIN_SCALE: float = 0.30   # smallest the grid will shrink to on a very small window
const GRID_MAX_SCALE: float = 2.50   # largest it will grow to on a large window/tablet
const SHADER_SIZE_CHOICES: Array = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4,1.5,1.6,1.7,1.8,1.9,2.0]
const MENU_BOX_SIZE: float = 760.0 # generous fixed box menu_center_host is given, just to center within
const ANCHOR_HIT_RADIUS: float = 28.0 # grid-local units; how close a press must be to grab an anchor

var main         # MainManager
var owner_menu   # OptionsMenu

var ready_ok: bool = false
var configs: Array = []             # [landscape config, portrait config]
var icon_settings: Dictionary = {}  # shared across both orientations: id -> [turns 0..3, mirrored]
var orient_mode: int = 0            # 0 auto (follow the device), 1 landscape, 2 portrait
var menu_rot: int = 0                # menu quarter turns, clockwise
var menu_flip: bool = false          # menu mirrored left-right
var editing: bool = false

var _buttons: Dictionary = {} # id -> Button
var _holders: Array = []      # the 25 grid cells
var _cell: Vector2 = Vector2(96, 96)
var _canvas: Control          # one full-window Control everything lives on
var _cp                       # the controls panel (DynamicUI) -- kept alive in the tree, no visual role
var _host                     # square host of the shader display; now freely positioned, not in a container
var _overlay                  # GridEditOverlay
var _spare_label              # the old center readout, kept alive but out of the tree
var _edit_orient: int = 0
var _edit_snapshot: Dictionary = {}

# Grid scaling: the grid keeps its tuned proportions and just scales as a whole to fit the window,
# so it never runs off-screen on a small window and grows to fill a large one.
var _wrapper: Control
var _camera_layer: Control = null
var _grid_natural_size: Vector2 = Vector2.ZERO
var _hide_btn: Button = null
var buttons_hidden: bool = false

## Hides the ENTIRE button grid -- every button, including OPT/PWR -- so the whole screen is free
## for camera drag/scroll/rotate with nothing intercepting it or popping a menu open by accident.
## There is deliberately no button-based way back, since every button is itself hidden: the only
## way out is the same gesture that hid it (see PatternCameraLayer.gd's double-click handling).
func toggle_buttons_hidden() -> void:
	buttons_hidden = not buttons_hidden
	if _wrapper != null:
		_wrapper.visible = not buttons_hidden

func _default_config(portrait: bool) -> Dictionary:
	return {
		"pos": (DEFAULT_POS_PORTRAIT if portrait else DEFAULT_POS_LANDSCAPE).duplicate(),
		"shader_center": DEFAULT_SHADER_CENTER_PORTRAIT if portrait else DEFAULT_SHADER_CENTER_LANDSCAPE,
		"menu_center": DEFAULT_MENU_CENTER_PORTRAIT if portrait else DEFAULT_MENU_CENTER_LANDSCAPE,
		"shader_size": DEFAULT_SHADER_SIZE_PORTRAIT if portrait else DEFAULT_SHADER_SIZE_LANDSCAPE,
		"menu_scale": DEFAULT_MENU_SCALE_PORTRAIT if portrait else DEFAULT_MENU_SCALE_LANDSCAPE,
		"grid_pan": DEFAULT_GRID_PAN_PORTRAIT if portrait else DEFAULT_GRID_PAN_LANDSCAPE,
		"grid_scale": 1.0,
	}

# =========================================================================
# SETUP: move the existing buttons onto the canvas
# =========================================================================
func setup(main_manager, owner_options: Object) -> void:
	main = main_manager
	
	owner_menu = owner_options
	configs = [_default_config(false), _default_config(true)]
	_capture()
	if not ready_ok:
		return
	load_settings()
	main.get_window().size_changed.connect(_on_window_resized)
	_apply_orient_mode()
	_apply_menu_orient()

	relayout()

## Lets the screensaver's full-screen catcher (above everything while it runs) hand its input to the
## pattern camera, so panning/zooming works without stopping the screensaver.
func feed_camera_input(event: InputEvent) -> void:
	if _camera_layer != null:
		_camera_layer.handle_external_input(event)



func _capture() -> void:
	var cp = main.control_panel
	var found: Dictionary = {
		"a": cp.btn_channel, "b": cp.btn_sens_left,
		"quick": main.btn_select_pass, "main": main.btn_shader_menu,
		"up": cp.btn_param_up, "down": cp.btn_param_down,
		"left": cp.btn_channel_prev, "right": cp.btn_channel_next,
		"vram": _make_vram_button(),
	}
	for id in found:
		if found[id] == null:
			push_warning("ControllerLayout: button '%s' not found; layout options disabled" % id)
			return

	var old_root = cp.get_parent()
	var host = main.canvas_container.get_parent()
	var old_trench = main.btn_shader_menu.get_parent()
	var old_chassis = cp.btn_channel.get_parent().get_parent()
	var menu_host = main.menu_center_host
	if old_root == null or host == null or old_trench == null or old_chassis == null or menu_host == null:
		push_warning("ControllerLayout: existing layout containers not found; layout options disabled")
		return

	_buttons = found
	_cp = cp
	_host = host

	# Cells are as big as the biggest button (96 x 96 in your layout)
	_cell = Vector2.ZERO
	for id in _buttons:
		var m: Vector2 = _buttons[id].custom_minimum_size
		_cell = Vector2(maxf(_cell.x, m.x), maxf(_cell.y, m.y))
	if _cell.x <= 0.0 or _cell.y <= 0.0:
		_cell = Vector2(96, 96)

	# One full-window Control everything lives on
	_canvas = Control.new()
	main.ui_canvas_layer.add_child(_canvas)

	
	_camera_layer = load("res://PatternCameraLayer.gd").new()
	_camera_layer.setup(main, self)
	_canvas.add_child(_camera_layer) # first child: sits behind the shader, grid, and any menu
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# The shader host is freely positioned (see relayout()), not inside any container
	if host.get_parent() != null:
		host.get_parent().remove_child(host)
	_canvas.add_child(host)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.canvas_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.set_anchors_preset(Control.PRESET_TOP_LEFT, false)

	# The grid: a plain Control holding the grid AND the edit overlay. Positioned manually in
	# relayout() (same approach as the shader host and menu host) so it can be panned off-center.
	var grid_size := Vector2(COLUMNS * _cell.x + (COLUMNS - 1) * GRID_GAP, ROWS * _cell.y + (ROWS - 1) * GRID_GAP)
	var wrapper := Control.new()
	wrapper.custom_minimum_size = grid_size
	wrapper.size = grid_size
	wrapper.pivot_offset = grid_size * 0.5 # scale around its own center, so it stays centered at any scale
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrapper.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	_canvas.add_child(wrapper)
	_wrapper = wrapper
	_grid_natural_size = grid_size
	var grid := GridContainer.new()
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", GRID_GAP)
	grid.add_theme_constant_override("v_separation", GRID_GAP)
	wrapper.add_child(grid)
	grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for i in range(COLUMNS * ROWS):
		var holder := Control.new()
		holder.custom_minimum_size = _cell
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		grid.add_child(holder)
		_holders.append(holder)

	_overlay = load("res://GridEditOverlay.gd").new()
	wrapper.add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.setup(self)

	# Buttons out of the old containers and into cells (real positions are set by relayout())
	for i in range(ALL_IDS.size()):
		_place(_buttons[ALL_IDS[i]], _holders[i])

	# menu_center_host moves to the canvas too, given last so it paints on top of the grid and shader.
	# Its own CenterContainer behavior is untouched -- relayout() just moves and resizes the BOX it
	# centers within, so every existing menu-drawing function keeps working with no changes anywhere else.
	if menu_host.get_parent() != null:
		menu_host.get_parent().remove_child(menu_host)
	_canvas.add_child(menu_host)
	menu_host.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.canvas_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The old center readout is no longer needed. It is kept alive (DynamicUI still holds a reference to it)
	# but taken out of the tree.
	_spare_label = cp.label_sens_indicator
	if _spare_label != null and _spare_label.get_parent() != null:
		_spare_label.get_parent().remove_child(_spare_label)

	# cp itself (DynamicUI) still needs to live in the tree -- it holds the app's state and its own
	# _ready()/signals -- but it no longer visually contains anything, since its buttons all moved
	# into grid cells above. Park it on the canvas with no footprint.
	if cp.get_parent() != null:
		cp.get_parent().remove_child(cp)
	_canvas.add_child(cp)
	cp.custom_minimum_size = Vector2.ZERO
	cp.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The old spacers, rows, grid and PWR/OPT trench are now empty shells
	old_chassis.queue_free()
	old_trench.queue_free()
	old_root.queue_free()

	# Moving the display's nodes can drop their texture links, so re-bind them
	main.pass2_material.set_shader_parameter("u_pattern_texture", main.pass1_viewport.get_texture())
	main.pass3_material.set_shader_parameter("u_warped_texture", main.pass2_viewport.get_texture())
	ready_ok = true

## Hides the menu panel in place (same tier/state, just invisible) rather than closing it; press
## again to reveal it exactly as it was. The performance readout is automatic now -- see
## MainManager._check_hardware_gpu_safety().

func _make_vram_button() -> Button:
	var btn := Button.new()
	btn.text = "🙉"
	btn.custom_minimum_size = Vector2(96, 96)
	btn.add_theme_font_size_override("font_size", 24)
	btn.pressed.connect(main.toggle_menu_hidden)
	_hide_btn = btn
	return btn

## Called by MainManager whenever the menu peek-hide state changes, so this button's own icon
## always shows whether the menu it controls is currently hidden (🙈) or visible (🙉).
func set_hide_button_icon(hidden: bool) -> void:
	if _hide_btn != null:
		_hide_btn.text = "🙈" if hidden else "🙉"

func _place(btn: Control, holder: Control) -> void:
	if btn.get_parent() == holder:
		return
	if btn.get_parent() != null:
		btn.get_parent().remove_child(btn)
	holder.add_child(btn)
	btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.pivot_offset = _cell * 0.5 # rotate and flip around the button's center


# =========================================================================
# SCREEN ORIENTATION
# =========================================================================
func current_orient() -> int:
	var s: Vector2i = DisplayServer.window_get_size()
	return 1 if s.y > s.x else 0

func set_orient_mode(mode: int) -> void:
	orient_mode = clampi(mode, 0, 2)
	_apply_orient_mode()
	relayout()
	save()

## Auto lets the device's sensor decide (on a phone). Landscape / Portrait force it. On desktop there is no
## sensor, so Auto leaves the window alone and the other two swap its width and height.
func _apply_orient_mode() -> void:
	if OS.has_feature("mobile"):
		match orient_mode:
			0:
				DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR)
			1:
				DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)
			2:
				DisplayServer.screen_set_orientation(DisplayServer.SCREEN_PORTRAIT)
	elif orient_mode != 0:
		var size_now: Vector2i = DisplayServer.window_get_size()
		if (size_now.y > size_now.x) != (orient_mode == 2):
			main.get_window().size = Vector2i(size_now.y, size_now.x)
	# When the window changes shape, _on_window_resized() re-fits everything

func _on_window_resized() -> void:
	if owner_menu != null and ((owner_menu.presets != null and owner_menu.presets.typing) or (owner_menu.lab != null and owner_menu.lab.typing)):
		return # the on-screen keyboard can resize the window; re-check once typing ends
	#if editing:
		#edit_cancel() # the window changed shape mid-edit: put the layout back and leave edit mode
	relayout()


# =========================================================================
# RELAYOUT: arrange everything for the window's CURRENT shape (tall = portrait)
# =========================================================================
func relayout() -> void:
	if not ready_ok:
		return
	var win_size: Vector2i = DisplayServer.window_get_size()
	var win: Vector2 = Vector2(win_size)
	var portrait: bool = win_size.y > win_size.x
	var cfg: Dictionary = configs[1 if portrait else 0]

	_update_grid_scale(win, cfg, portrait)

	# Buttons into their cells, with their (shared) icon rotation / mirroring
	for id in ALL_IDS:
		_place(_buttons[id], _holders[int(cfg["pos"][id])])
		var st: Array = _icon_state(id)
		_buttons[id].rotation_degrees = 90.0 * int(st[0])
		_buttons[id].scale = Vector2(-1.0 if bool(st[1]) else 1.0, 1.0)

	# The shader: a floating square pinned to Shader Center, sized by Shader Size
	var side: float = minf(win.x, win.y) * float(cfg["shader_size"])
	_host.custom_minimum_size = Vector2(side, side)
	_host.size = Vector2(side, side)
	_host.position = _anchor_window_point(cfg["shader_center"], win) - Vector2(side, side) * 0.5
	main.canvas_container.custom_minimum_size = Vector2(side, side)
	# (pass 3 sits inside the stretching SubViewportContainer, which sizes it by itself)
	for vp in [main.pass1_viewport, main.pass2_viewport]:
		vp.size = Vector2i(side, side)
	for rect in [main.pass1_rect, main.pass2_rect, main.pass3_rect]:
		rect.custom_minimum_size = Vector2(side, side)
		rect.size = Vector2(side, side)

	# Menus: move & resize the SAME menu_center_host every menu already draws into, so its own
	# CenterContainer centering lands on Menu Center. Nothing about how a menu draws itself changes.
	var host = main.menu_center_host
	host.size = Vector2(MENU_BOX_SIZE, MENU_BOX_SIZE)
	host.position = _anchor_window_point(cfg["menu_center"], win) - host.size * 0.5
	_apply_menu_orient() # re-applies scale/flip/rotation now that position/size are current

func _anchor_window_point(frac: Vector2, win: Vector2) -> Vector2:
	return Vector2(frac.x * win.x, frac.y * win.y)

## Scales the grid to fit the window, then positions it: centered on the axis that has no slack,
## and shifted along the axis that does (the "long" axis for this orientation) by the saved pan
## amount. pan 0.5 = dead center (today's behavior); 0 / 1 = slid all the way to one end.

func _update_grid_scale(win: Vector2, cfg: Dictionary, portrait: bool) -> void:
	if _wrapper == null or _grid_natural_size.x <= 0.0 or _grid_natural_size.y <= 0.0:
		return
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var s: float = minf(win.x / _grid_natural_size.x, win.y / _grid_natural_size.y) * GRID_FIT_MARGIN
	s = clampf(s, GRID_MIN_SCALE, GRID_MAX_SCALE)
	s *= float(cfg.get("grid_scale", 1.0))
	_wrapper.scale = Vector2(s, s)

	var scaled_size: Vector2 = _grid_natural_size * s
	var target_center: Vector2 = win * 0.5
	var pan: float = float(cfg.get("grid_pan", 0.5))
	if portrait:
		var slack_y: float = maxf(win.y - scaled_size.y, 0.0)
		target_center.y += (pan - 0.5) * slack_y
	else:
		var slack_x: float = maxf(win.x - scaled_size.x, 0.0)
		target_center.x += (pan - 0.5) * slack_x
	_wrapper.position = target_center - _wrapper.pivot_offset

func _icon_state(id: String) -> Array:
	return icon_settings.get(id, [0, false])


# =========================================================================
# GRID GEOMETRY AND CONTENTS (used by the edit overlay)
# =========================================================================
func cell_size() -> Vector2:
	return _cell

func cell_rect(cell: int) -> Rect2:
	var pitch: Vector2 = _cell + Vector2(GRID_GAP, GRID_GAP)
	var col: int = cell % COLUMNS
	var row: int = floori(float(cell) / float(COLUMNS))
	return Rect2(Vector2(col * pitch.x, row * pitch.y), _cell)

## The cell under a point in grid-local coordinates, or -1 outside the grid.
func cell_at(pos: Vector2) -> int:
	if pos.x < 0.0 or pos.y < 0.0:
		return -1
	var pitch: Vector2 = _cell + Vector2(GRID_GAP, GRID_GAP)
	var col: int = int(pos.x / pitch.x)
	var row: int = int(pos.y / pitch.y)
	if col >= COLUMNS or row >= ROWS:
		return -1
	return row * COLUMNS + col

func _active_cfg() -> Dictionary:
	return configs[_edit_orient] if editing else configs[current_orient()]

func button_at(cell: int) -> String:
	if cell < 0:
		return ""
	var pos: Dictionary = _active_cfg()["pos"]
	for id in pos:
		if int(pos[id]) == cell:
			return id
	return ""

func cell_of(id: String) -> int:
	return int(_active_cfg()["pos"][id])

## A see-through copy of a button that follows the finger during a drag (no signals, so it can never fire).
func make_ghost(id: String) -> Control:
	var g: Control = _buttons[id].duplicate(0)
	g.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	g.size = _cell
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	g.modulate = Color(1, 1, 1, 0.8)
	return g

func set_button_dim(id: String, dim: bool) -> void:
	_buttons[id].modulate = Color(1, 1, 1, 0.3 if dim else 1.0)


# =========================================================================
# ANCHORS (Shader Center / Menu Center) -- grid-local <-> window-fraction conversions the
# overlay uses to draw and drag the two markers, plus live preview while dragging
# =========================================================================
## Grid-local position of an anchor ("shader_center" or "menu_center") right now.
func anchor_local_pos(key: String) -> Vector2:
	var cfg: Dictionary = _active_cfg()
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	return _window_to_grid_local(_anchor_window_point(cfg[key], win))

func _window_to_grid_local(window_point: Vector2) -> Vector2:
	if _wrapper == null or _wrapper.scale.x == 0.0:
		return window_point
	return (window_point - _wrapper.global_position) / _wrapper.scale

func _grid_local_to_window_fraction(local_point: Vector2) -> Vector2:
	var window_point: Vector2 = _wrapper.global_position + local_point * _wrapper.scale
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	if win.x <= 0.0 or win.y <= 0.0:
		return Vector2(0.5, 0.5)
	return Vector2(clampf(window_point.x / win.x, 0.0, 1.0), clampf(window_point.y / win.y, 0.0, 1.0))

## Live-updates an anchor while it is being dragged (called every drag frame, and once on drop).
func preview_anchor(key: String, local_point: Vector2) -> void:
	if not editing:
		return
	configs[_edit_orient][key] = _grid_local_to_window_fraction(local_point)
	relayout()


# =========================================================================
# REPOSITION SESSION
# =========================================================================

## Called by the overlay while dragging an EMPTY cell to pan the grid. px_delta is the raw pointer
## movement in real screen pixels since the last call (global, not grid-local -- see note below).
## Only the axis with slack for this orientation moves (Y in portrait, X in landscape); the other
## component of px_delta is ignored. Not saved until edit_accept() (A) runs.
func pan_grid_drag(px_delta: Vector2) -> void:
	if not editing:
		return
	var portrait: bool = _edit_orient == 1
	var win: Vector2 = Vector2(DisplayServer.window_get_size())
	var scaled_size: Vector2 = _grid_natural_size * _wrapper.scale.x
	var cfg: Dictionary = configs[_edit_orient]
	var delta: float = px_delta.y if portrait else px_delta.x
	var slack: float = maxf((win.y if portrait else win.x) - (scaled_size.y if portrait else scaled_size.x), 0.0)
	if slack <= 0.0:
		return
	cfg["grid_pan"] = clampf(float(cfg["grid_pan"]) + delta / slack, 0.0, 1.0)
	relayout()



func begin_edit() -> void:
	if not ready_ok or editing:
		return
	_edit_orient = current_orient()
	_edit_snapshot = configs[_edit_orient].duplicate(true)
	editing = true
	_overlay.reset_interaction()
	_overlay.visible = true
	_overlay.queue_redraw()

## Drop: the button takes the cell; a button already there takes the vacated cell (a swap).
func edit_move(id: String, target: int) -> void:
	if not editing:
		return
	var pos: Dictionary = configs[_edit_orient]["pos"]
	var source: int = int(pos[id])
	var occupant: String = button_at(target)
	pos[id] = target
	if occupant != "" and occupant != id:
		pos[occupant] = source
	relayout()
	_overlay.queue_redraw()

func edit_accept() -> void:
	if not editing:
		return
	_end_edit()
	save()
	relayout()
	owner_menu.reposition_finished(true)

func edit_cancel() -> void:
	if not editing:
		return
	configs[_edit_orient] = _edit_snapshot
	_end_edit()
	relayout()
	owner_menu.reposition_finished(false)

func _end_edit() -> void:
	editing = false
	_overlay.reset_interaction()
	_overlay.visible = false


# =========================================================================
# EDITING (called by the options menu; every change applies at once and is saved)
# =========================================================================

## The grid's current on-screen bounding box, in real window pixels -- used by things (like the
## color picker) that render "on top of the grid," wherever it currently is (position, pan, scale).
func grid_screen_rect() -> Rect2:
	if _wrapper == null:
		return Rect2()
	var xform: Transform2D = _wrapper.get_global_transform()
	var a: Vector2 = xform * Vector2.ZERO
	var b: Vector2 = xform * _grid_natural_size
	return Rect2(a, b - a)

## The shader display's current on-screen rect in real window pixels. Gestures use this (not the
## window size) to turn finger movement into shader-space movement, so a drag is 1:1 under the
## finger even when the shader isn't filling the window.
func shader_screen_rect() -> Rect2:
	if _host == null:
		return Rect2()
	return Rect2(_host.get_global_position(), _host.size)


func button_name(id: String) -> String:
	return BUTTON_NAMES.get(id, id)

func shader_size() -> float:
	return float(configs[current_orient()]["shader_size"])

func cycle_shader_size(step: int) -> void:
	var orient: int = current_orient()
	var idx: int = SHADER_SIZE_CHOICES.find(configs[orient]["shader_size"])
	if idx == -1:
		idx = SHADER_SIZE_CHOICES.find(1.0)
	idx = clampi(idx + step, 0, SHADER_SIZE_CHOICES.size() - 1)
	configs[orient]["shader_size"] = SHADER_SIZE_CHOICES[idx]
	relayout()
	save()
	
func menu_scale() -> float:
	return float(configs[current_orient()]["menu_scale"])

func cycle_menu_size(step: int) -> void:
	var orient: int = current_orient()
	var idx: int = MENU_SIZE_CHOICES.find(configs[orient]["menu_scale"])
	if idx == -1:
		idx = MENU_SIZE_CHOICES.find(1.0)
	idx = clampi(idx + step, 0, MENU_SIZE_CHOICES.size() - 1)
	configs[orient]["menu_scale"] = MENU_SIZE_CHOICES[idx]
	relayout()
	save()
	
func grid_scale() -> float:
	return float(configs[current_orient()]["grid_scale"])

func cycle_grid_size(step: int) -> void:
	var orient: int = current_orient()
	var idx: int = GRID_SIZE_CHOICES.find(configs[orient]["grid_scale"])
	if idx == -1:
		idx = GRID_SIZE_CHOICES.find(1.0)
	idx = clampi(idx + step, 0, GRID_SIZE_CHOICES.size() - 1)
	configs[orient]["grid_scale"] = GRID_SIZE_CHOICES[idx]
	relayout()
	save()

## Read one component (0=X, 1=Y) of an anchor fraction for the options menu's tweak console.
func anchor_value(key: String, idx: int) -> float:
	var v: Vector2 = configs[current_orient()][key]
	return v[idx]

## Write one component of an anchor fraction; applies and saves immediately, same as a color tweak.
func set_anchor_value(key: String, idx: int, value: float) -> void:
	var orient: int = current_orient()
	var v: Vector2 = configs[orient][key]
	v[idx] = clampf(value, 0.0, 1.0)
	configs[orient][key] = v
	relayout()
	save()

## The un-customized fraction for this orientation, for the tweak console's "DEFAULT VAL" line.
func anchor_default(key: String, idx: int) -> float:
	return _default_config(current_orient() == 1)[key][idx]

## Icon settings are shared across both orientations -- rotating a button's icon once fixes it
## everywhere, rather than needing to be redone per orientation.
func icon_rotation(id: String) -> int:
	return int(_icon_state(id)[0]) * 90

func icon_flipped(id: String) -> bool:
	return bool(_icon_state(id)[1])

func icon_state_text(id: String) -> String:
	return "%d°%s" % [icon_rotation(id), " FLIPPED" if icon_flipped(id) else ""]

## Rotate the icon a quarter turn clockwise, as seen on screen.
func rotate_icon(id: String) -> void:
	var st: Array = _icon_state(id)
	icon_settings[id] = [(int(st[0]) + 1) % 4, bool(st[1])]
	relayout()
	save()

## Mirror the icon left-right, as seen on screen (a mirror also reverses the direction of any turn).
func flip_icon(id: String) -> void:
	var st: Array = _icon_state(id)
	icon_settings[id] = [(4 - int(st[0])) % 4, not bool(st[1])]
	relayout()
	save()

## Puts one orientation back to its default arrangement (positions, anchors, shader size).
## Icon settings are shared, so they are left as they are -- this only resets layout, not look.
func reset(orient: int) -> void:
	configs[orient] = _default_config(orient == 1)
	relayout()
	save()

# The menu overlay turns and mirrors the same way the icons do (one setting for both orientations)
func menu_state_text() -> String:
	return "%d°%s" % [menu_rot * 90, " FLIPPED" if menu_flip else ""]

func rotate_menu() -> void:
	menu_rot = (menu_rot + 1) % 4
	_apply_menu_orient()
	save()

func flip_menu() -> void:
	menu_rot = (4 - menu_rot) % 4
	menu_flip = not menu_flip
	_apply_menu_orient()
	save()

## The menu host is a square box, so quarter turns map it exactly onto itself.
func _apply_menu_orient() -> void:
	var host = main.menu_center_host
	if host == null:
		return
	var s: float = float(configs[current_orient()]["menu_scale"])
	host.pivot_offset = host.size * 0.5
	host.rotation_degrees = 90.0 * menu_rot
	host.scale = Vector2((-1.0 if menu_flip else 1.0) * s, s)


# =========================================================================
# PERSISTENCE (same file as the colors and presets settings; other sections are preserved)
# =========================================================================
func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("layout", "orient_mode", orient_mode)
	cfg.set_value("layout", "menu_rot", menu_rot)
	cfg.set_value("layout", "menu_flip", menu_flip)
	cfg.set_value("layout", "icon_settings", icon_settings)
	for i in range(2):
		var section: String = "grid_%d" % i
		cfg.set_value(section, "pos", configs[i]["pos"])
		cfg.set_value(section, "shader_center", configs[i]["shader_center"])
		cfg.set_value(section, "menu_center", configs[i]["menu_center"])
		cfg.set_value(section, "shader_size", configs[i]["shader_size"])
		cfg.set_value(section, "grid_pan", configs[i]["grid_pan"])
		cfg.set_value(section, "menu_scale", configs[i]["menu_scale"])
		cfg.set_value(section, "grid_scale", configs[i]["grid_scale"])
	cfg.save(SETTINGS_PATH)

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	orient_mode = clampi(int(cfg.get_value("layout", "orient_mode", -1)), -1, 2)
	if orient_mode == -1:
		# An older version saved a forced orientation as 0 / 1 plus a "chosen" flag
		var forced: bool = bool(cfg.get_value("layout", "orientation_custom", false))
		orient_mode = 1 + clampi(int(cfg.get_value("layout", "orientation", 0)), 0, 1) if forced else 0
	menu_rot = clampi(int(cfg.get_value("layout", "menu_rot", 0)), 0, 3)
	menu_flip = bool(cfg.get_value("layout", "menu_flip", false))

	var saved_icons = cfg.get_value("layout", "icon_settings", {})
	if saved_icons is Dictionary:
		for id in saved_icons:
			var st = saved_icons[id]
			if _buttons.has(id) and st is Array and st.size() == 2:
				icon_settings[id] = [clampi(int(st[0]), 0, 3), bool(st[1])]

	for i in range(2):
		var section: String = "grid_%d" % i
		# A save from before Shader Center existed has nothing meaningful to migrate -- start that
		# orientation fresh from its new defaults rather than mixing old and new data.
		if not cfg.has_section_key(section, "shader_center"):
			continue
		var c: Dictionary = _default_config(i == 1)
		var pos = cfg.get_value(section, "pos", {})
		if _valid_positions(pos):
			c["pos"] = pos.duplicate()
		var sc = cfg.get_value(section, "shader_center", null)
		if sc is Vector2:
			c["shader_center"] = Vector2(clampf(sc.x, 0.0, 1.0), clampf(sc.y, 0.0, 1.0))
		var mc = cfg.get_value(section, "menu_center", null)
		if mc is Vector2:
			c["menu_center"] = Vector2(clampf(mc.x, 0.0, 1.0), clampf(mc.y, 0.0, 1.0))
		var sz = cfg.get_value(section, "shader_size", -1.0)
		if SHADER_SIZE_CHOICES.has(sz):
			c["shader_size"] = sz
		configs[i] = c
		var pan = cfg.get_value(section, "grid_pan", 0.5)
		if pan is float or pan is int:
			c["grid_pan"] = clampf(float(pan), 0.0, 1.0)
		var msz = cfg.get_value(section, "menu_scale", -1.0)
		if MENU_SIZE_CHOICES.has(msz):
			c["menu_scale"] = msz
		var gsz = cfg.get_value(section, "grid_scale", -1.0)
		if GRID_SIZE_CHOICES.has(gsz):
			c["grid_scale"] = gsz

## A saved arrangement is only trusted if every button appears once, each in its own valid cell.
func _valid_positions(p) -> bool:
	if not (p is Dictionary) or p.size() != ALL_IDS.size():
		return false
	var used: Array = []
	for id in ALL_IDS:
		if not p.has(id):
			return false
		var cell = p[id]
		if not (cell is int) or cell < 0 or cell >= COLUMNS * ROWS or used.has(cell):
			return false
		used.append(cell)
	return true
