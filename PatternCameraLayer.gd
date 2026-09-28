extends Control
## PatternCameraLayer.gd -- mouse (touch coming next) control for exploring a pattern's math space:
## click+drag pans, scroll wheel zooms, right-click+drag left/right rotates, double-click hides the
## whole button grid so nothing steals the drag or pops a menu open underneath your finger.
##
## Drives the exact same pass-1 global camera uniforms (u_global_offset, u_global_zoom,
## u_master_rotation) the GLOBALS menu already edits via D-pad -- dragging and dialing are just two
## input methods for the same numbers, so exploring by hand saves/loads with the preset for free.
##
## Sits as the FIRST child of ControllerLayout's canvas, so the shader, the grid, and any open menu
## (all added after it) take input priority over their own footprint; this layer only ever receives
## whatever falls through all of them onto genuinely empty screen. It still explicitly checks
## active_state itself rather than relying on that coverage alone -- an open menu's own panel is much
## smaller than the whole screen, and would otherwise leave gestures live all around it.

const ZOOM_STEP: float = 1.1        # multiplicative, per scroll-wheel notch
const ROTATE_SENS: float = 0.01     # radians per pixel of RMB drag

var main
var layout # ControllerLayout.gd

var _panning: bool = false
var _rotating: bool = false
var _last_mouse: Vector2 = Vector2.ZERO

func setup(main_manager, controller_layout) -> void:
	main = main_manager
	layout = controller_layout
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	gui_input.connect(_on_gui_input)

func _menu_open() -> bool:
	return main.control_panel.active_state != main.control_panel.ControlState.HIDDEN

func _on_gui_input(event: InputEvent) -> void:
	if _menu_open():
		return
	if event is InputEventMouseButton:
		_handle_button(event)

	elif event is InputEventMouseMotion:
		_handle_motion(event)


func _handle_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.double_click:
			layout.toggle_buttons_hidden()
			_panning = false
			return
		_panning = event.pressed
		_last_mouse = event.position
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		_rotating = event.pressed
		_last_mouse = event.position
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom(1.0 / ZOOM_STEP)
	elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom(ZOOM_STEP)

func _handle_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		var zoom: float = float(main.get_pattern_global("u_global_zoom", 1.0))
		var win: Vector2 = size
		var offset: Vector2 = main.get_pattern_global("u_global_offset", Vector2.ZERO)
		offset -= (event.position - _last_mouse) / win * zoom
		main.set_pattern_global("u_global_offset", offset)
		_last_mouse = event.position
	elif _rotating:
		var rot: float = float(main.get_pattern_global("u_master_rotation", 0.0))
		rot += (event.position.x - _last_mouse.x) * ROTATE_SENS
		main.set_pattern_global("u_master_rotation", rot)
		_last_mouse = event.position

func _zoom(factor: float) -> void:
	var zoom: float = float(main.get_pattern_global("u_global_zoom", 1.0))
	main.set_pattern_global("u_global_zoom", clampf(zoom * factor, 0.002, 20.0))
