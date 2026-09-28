extends Control
## PatternCameraLayer.gd -- mouse + touch control for exploring a pattern's math space.
##
## Mouse: wheel zooms about the cursor, left-drag pans, right-drag rotates about where you pressed,
## double-click hides/shows the button grid.
## Touch: one finger pans; two fingers pan (midpoint), zoom (pinch) and rotate (twist) together,
## anchored on the fingers; double-tap hides/shows the button grid.
##
## Everything drives the same pass-1 globals the GLOBALS menu edits (u_global_offset, u_global_zoom,
## u_master_rotation), so exploring by hand saves/loads with the preset like any other setting.
## The math assumes the warp/filter passes aren't moving the picture around (their defaults).
##
## Sits as the FIRST child of ControllerLayout's canvas so the shader, grid and menus take input
## priority over their own footprint; this layer gets whatever falls through to empty screen.

const ZOOM_MIN: float = 0.002
const ZOOM_MAX: float = 20.0
const OFFSET_LIMIT: float = 40.0     # matches u_global_offset's @min/@max in ShaderLibrary.gd
const ZOOM_STEP: float = 1.1         # per wheel notch
const ROTATE_SENS: float = 0.01      # radians per pixel of right-drag
const TWIST_DEADZONE: float = 0.14   # radians (~8 deg) of twist ignored before rotation engages
const TAP_MOVE_PX: float = 24.0      # a touch that moves further than this is a drag, not a tap
const TAP_MAX_MS: int = 250          # a touch held longer than this is not a tap
const DOUBLE_TAP_MS: int = 350       # max gap between the two taps
const DOUBLE_TAP_PX: float = 60.0    # max distance between the two taps
const HINT_SECONDS: float = 2.0
const DEBUG_TOUCH: bool = true       # temporary prints for on-device testing; set false when happy
const SAVER_TAP_MAX_MS: int = 1500   # screensaver: a still touch held this long still counts as "tap to stop"
var _mouse_down_pos: Vector2 = Vector2.ZERO
var _mouse_moved: bool = false


var main
var layout # ControllerLayout.gd

# --- mouse state
var _panning: bool = false
var _rotating: bool = false
var _last_mouse: Vector2 = Vector2.ZERO
var _rot_pivot: Vector2 = Vector2.ZERO

# --- touch state
var _touches: Dictionary = {}        # finger index -> screen position
var _pan_active: bool = false
var _pan_last: Vector2 = Vector2.ZERO
var _down_pos: Vector2 = Vector2.ZERO
var _down_ms: int = 0
var _tap_candidate: bool = false     # true while this touch could still turn out to be a plain tap
var _last_tap_ms: int = -100000
var _last_tap_pos: Vector2 = Vector2.ZERO
var _two_mid: Vector2 = Vector2.ZERO
var _two_dist: float = 0.0
var _two_angle: float = 0.0
var _twist_accum: float = 0.0
var _twist_engaged: bool = false

# --- "double-tap to show buttons" hint
var _hint: Label
var _hint_tween: Tween


func setup(main_manager, controller_layout) -> void:
	main = main_manager
	layout = controller_layout
	mouse_filter = Control.MOUSE_FILTER_STOP
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	resized.connect(func() -> void: _dbg("camera layer size is now %s" % str(size)))
	gui_input.connect(_on_gui_input)
	_build_hint()

func _dbg(msg: String) -> void:
	if DEBUG_TOUCH:
		print("📱 camera: ", msg)

## Camera gestures stay live in ordinary menus (you can pan/zoom while tuning a value), but step aside
## whenever something else has its own use for the pointer.
func _camera_blocked() -> bool:
	var om = main.control_panel.options_menu
	if om == null:
		return false
	if om.picker != null and om.picker.is_open:
		return true
	if layout.editing:
		return true
	if om.help != null and om.help.is_open:
		return true
	if (om.presets != null and om.presets.typing) or (om.lab != null and om.lab.typing):
		return true
	return false

func _saver():
	var om = main.control_panel.options_menu
	return om.saver if om != null else null

func _saver_running() -> bool:
	var s = _saver()
	return s != null and s.running

func _ping_saver() -> void:
	var s = _saver()
	if s != null and s.running:
		s.note_interaction()

func _cancel_all() -> void:
	_touches.clear()
	_pan_active = false
	_tap_candidate = false
	_panning = false
	_rotating = false

## The screensaver's full-screen catcher hands its events here so the camera keeps working while it runs.
func handle_external_input(event: InputEvent) -> void:
	_on_gui_input(event)

func _on_gui_input(event: InputEvent) -> void:
	if _camera_blocked():
		_cancel_all()
		return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		_handle_mouse_motion(event)


# ------------------------------------------------------------------
# COORDINATES
# ------------------------------------------------------------------
func _to_screen(local_pos: Vector2) -> Vector2:
	return get_global_transform() * local_pos

## Screen pixels -> shader space: (0,0) is the middle of the shader, edges are +-0.5.
func _to_shader_space(screen_pos: Vector2) -> Vector2:
	var r: Rect2 = layout.shader_screen_rect()
	if r.size.x < 1.0 or r.size.y < 1.0:
		return Vector2.ZERO
	return (screen_pos - r.get_center()) / r.size


# ------------------------------------------------------------------
# THE CAMERA (reads/writes pass 1's existing globals)
# ------------------------------------------------------------------
func _get_zoom() -> float:
	return float(main.get_pattern_global("u_global_zoom", 1.0))

func _get_offset() -> Vector2:
	return main.get_pattern_global("u_global_offset", Vector2.ZERO)

func _get_rot() -> float:
	return float(main.get_pattern_global("u_master_rotation", 0.0))

func _set_zoom(v: float) -> void:
	main.set_pattern_global("u_global_zoom", clampf(v, ZOOM_MIN, ZOOM_MAX))

func _set_offset(v: Vector2) -> void:
	main.set_pattern_global("u_global_offset", Vector2(
		clampf(v.x, -OFFSET_LIMIT, OFFSET_LIMIT), clampf(v.y, -OFFSET_LIMIT, OFFSET_LIMIT)))

func _set_rot(v: float) -> void:
	main.set_pattern_global("u_master_rotation", wrapf(v, -PI, PI)) # the menu range is +-pi

## Drag the picture by a pixel amount, 1:1 under the finger/cursor.
func _pan_pixels(delta_px: Vector2) -> void:
	var r: Rect2 = layout.shader_screen_rect()
	if r.size.x < 1.0 or r.size.y < 1.0:
		return
	_set_offset(_get_offset() - _get_zoom() * (delta_px / r.size))
	_ping_saver()

## factor > 1 magnifies. The point at `pivot` (shader space) stays put.
func _zoom_about(pivot: Vector2, factor: float) -> void:
	var z: float = _get_zoom()
	var z2: float = clampf(z / factor, ZOOM_MIN, ZOOM_MAX)
	_set_offset(_get_offset() + (z - z2) * pivot)
	_set_zoom(z2)
	_ping_saver()

## delta_ang changes the shader's rotation angle; the point at `pivot` stays put.
func _rotate_about(pivot: Vector2, delta_ang: float) -> void:
	var z: float = _get_zoom()
	var v: Vector2 = z * pivot + _get_offset()
	_set_offset(v.rotated(-delta_ang) - z * pivot)
	_set_rot(_get_rot() + delta_ang)
	_ping_saver()


# ------------------------------------------------------------------
# MOUSE
# ------------------------------------------------------------------
func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var p: Vector2 = _to_screen(event.position)
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click and not _saver_running():
					_panning = false
					_toggle_buttons(false)
					return
				_mouse_down_pos = p
				_mouse_moved = false
			elif _panning and _saver_running() and not _mouse_moved:
				_panning = false
				_saver().stop() # a clean click wakes the screensaver; a drag never does
				return
			_panning = event.pressed
			_last_mouse = p
		MOUSE_BUTTON_RIGHT:
			_rotating = event.pressed
			_last_mouse = p
			_rot_pivot = _to_shader_space(p)
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_about(_to_shader_space(p), ZOOM_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_about(_to_shader_space(p), 1.0 / ZOOM_STEP)

func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var p: Vector2 = _to_screen(event.position)
	if _panning:
		if p.distance_to(_mouse_down_pos) > TAP_MOVE_PX:
			_mouse_moved = true
		_pan_pixels(p - _last_mouse)
	elif _rotating:
		_rotate_about(_rot_pivot, (p.x - _last_mouse.x) * ROTATE_SENS)
	else:
		return
	_last_mouse = p


# ------------------------------------------------------------------
# TOUCH
# ------------------------------------------------------------------
func _handle_touch(event: InputEventScreenTouch) -> void:
	var p: Vector2 = _to_screen(event.position)
	if event.pressed:
		var first_finger: bool = _touches.is_empty()
		_touches[event.index] = p
		_pan_active = false
		if first_finger:
			_down_pos = p
			_down_ms = Time.get_ticks_msec()
			_tap_candidate = true
		else:
			_tap_candidate = false # a second finger makes this a gesture, never a tap
		if _touches.size() == 2:
			_reset_two_finger_baseline()
		_dbg("finger down, %d on screen" % _touches.size())
	else:
		if not _touches.has(event.index):
			return
		_touches.erase(event.index)
		_dbg("finger up, %d left" % _touches.size())
		if _touches.is_empty():
			_finish_sequence(p)
		elif _touches.size() == 1:
			# One finger of a two-finger gesture lifted: the other carries on as a plain pan
			_pan_last = _touches.values()[0]
			_pan_active = true
		elif _touches.size() == 2:
			_reset_two_finger_baseline()
	accept_event()

func _handle_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		return
	var p: Vector2 = _to_screen(event.position)
	_touches[event.index] = p
	if _touches.size() == 1:
		_update_single(p)
	elif _touches.size() == 2:
		_update_two_finger()
	accept_event() # three or more fingers: tracked, but no gesture is applied

func _update_single(p: Vector2) -> void:
	if not _pan_active:
		if p.distance_to(_down_pos) <= TAP_MOVE_PX:
			return # still within tap slop -- don't nudge the picture
		_tap_candidate = false
		_pan_active = true
		_pan_last = p
		return
	_pan_pixels(p - _pan_last)
	_pan_last = p

func _two_finger_metrics() -> Dictionary:
	var pts: Array = _touches.values()
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	return {"mid": (a + b) * 0.5, "dist": a.distance_to(b), "angle": (b - a).angle()}

func _reset_two_finger_baseline() -> void:
	var m: Dictionary = _two_finger_metrics()
	_two_mid = m["mid"]
	_two_dist = m["dist"]
	_two_angle = m["angle"]
	_twist_accum = 0.0
	_twist_engaged = false

func _update_two_finger() -> void:
	var m: Dictionary = _two_finger_metrics()
	# 1) the midpoint drags the picture
	_pan_pixels(m["mid"] - _two_mid)
	var pivot: Vector2 = _to_shader_space(m["mid"])
	# 2) pinch zooms about the fingers
	if _two_dist > 1.0 and m["dist"] > 1.0:
		_zoom_about(pivot, m["dist"] / _two_dist)
	# 3) twist rotates about the fingers, once it clears a small dead-zone so an ordinary pinch
	#    doesn't wobble the picture. The picture turns WITH the fingers, hence the minus sign.
	var dphi: float = wrapf(m["angle"] - _two_angle, -PI, PI)
	if _twist_engaged:
		_rotate_about(pivot, -dphi)
	else:
		_twist_accum += dphi
		if absf(_twist_accum) >= TWIST_DEADZONE:
			_twist_engaged = true
			_dbg("twist engaged")
	_two_mid = m["mid"]
	_two_dist = m["dist"]
	_two_angle = m["angle"]

func _finish_sequence(p: Vector2) -> void:
	_pan_active = false
	_dbg("gesture over -- zoom %.4f  offset %s  rot %.3f" % [_get_zoom(), str(_get_offset()), _get_rot()])
	if not _tap_candidate:
		return
	_tap_candidate = false
	var now: int = Time.get_ticks_msec()

	if _saver_running():
		# A still touch wakes the screensaver; drags, pinches and twists never do
		if now - _down_ms <= SAVER_TAP_MAX_MS:
			_saver().stop()
		return
	if now - _down_ms > TAP_MAX_MS:
		return
	if now - _last_tap_ms <= DOUBLE_TAP_MS and p.distance_to(_last_tap_pos) <= DOUBLE_TAP_PX:
		_last_tap_ms = -100000
		_dbg("double-tap")
		_toggle_buttons(true)
	else:
		_last_tap_ms = now
		_last_tap_pos = p


# ------------------------------------------------------------------
# BUTTON-GRID TOGGLE + HINT
# ------------------------------------------------------------------
func _toggle_buttons(from_touch: bool) -> void:
	layout.toggle_buttons_hidden()
	if layout.buttons_hidden:
		_show_hint("DOUBLE-TAP TO SHOW BUTTONS" if from_touch else "DOUBLE-CLICK TO SHOW BUTTONS")
	else:
		_hide_hint()

func _build_hint() -> void:
	var hint_layer := CanvasLayer.new()
	hint_layer.layer = 5 # above the perf bar, below Help and the color picker
	add_child(hint_layer)

	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.visible = false
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_color_override("font_color", Color.WHITE)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.05, 0.85)
	style.set_corner_radius_all(8)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_hint.add_theme_stylebox_override("normal", style)
	hint_layer.add_child(_hint)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hint.offset_bottom = -40.0

func _show_hint(text: String) -> void:
	_hint.text = text
	_hint.modulate.a = 1.0
	_hint.visible = true
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint_tween = create_tween()
	_hint_tween.tween_interval(HINT_SECONDS)
	_hint_tween.tween_property(_hint, "modulate:a", 0.0, 0.6)
	_hint_tween.tween_callback(func() -> void: _hint.visible = false)

func _hide_hint() -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint.visible = false
