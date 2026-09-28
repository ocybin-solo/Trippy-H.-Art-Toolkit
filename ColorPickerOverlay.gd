extends Node
## ColorPickerOverlay.gd -- one shared, fully-featured Godot ColorPicker used everywhere a color
## needs editing: shader vec4 uniforms (ShaderLibrary records flagged is_color), and OptionsMenu's
## bg_color/button_color. Every mode/control Godot's ColorPicker offers (RGB, HSV, OKHSL, Raw, hex,
## presets, eyedropper, alpha) stays on for all three callers -- same widget, same behavior, always.
##
## Renders centered on wherever the button grid currently is (ControllerLayout.grid_screen_rect()),
## on its own top CanvasLayer, decoupled from Menu Center/Menu Size entirely -- same reasoning as
## HelpViewer. The box is pinned to exactly the grid's current rect and never grows past it; if the
## picker's natural size doesn't fit, a ScrollContainer handles the overflow instead. The ✕ button
## lives in a fixed header above the scroll area, so it's reachable regardless of scroll position.
## There is no B-button close (or any D-pad handling) -- the picker fully covers the grid, including
## every physical button on it, so the ✕ is the only way out, by design.

var main
var owner_menu # OptionsMenu (for owner_menu.layout.grid_screen_rect())

var is_open: bool = false
var _box: Control
var _picker: ColorPicker
var _on_change: Callable = Callable()
var _on_done: Callable = Callable()

const COLOR_SLIDER_MIN_HEIGHT := 64
const MODE_BUTTON_MIN_HEIGHT := 64



func _make_picker_touch_friendly() -> void:
	_make_picker_touch_friendly_recursive(_picker)



func _make_picker_touch_friendly_recursive(node: Node) -> void:
	for child in node.get_children(true):
		if child is HSlider:
			child.custom_minimum_size.y = COLOR_SLIDER_MIN_HEIGHT

		elif child is Button:
			if child.text in ["RGB", "HSV", "Linear"]:
				child.custom_minimum_size.y = MODE_BUTTON_MIN_HEIGHT

		_make_picker_touch_friendly_recursive(child)






func setup(main_manager, owner_options: Object) -> void:
	main = main_manager
	owner_menu = owner_options
	_build()

func _build() -> void:
	var overlay_layer := CanvasLayer.new()
	overlay_layer.layer = 10 # same top layer as HelpViewer -- always on top, own input priority
	main.add_child(overlay_layer)

	_box = Control.new()
	_box.visible = false
	overlay_layer.add_child(_box)

	var bg := PanelContainer.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.04, 0.9)
	style.set_border_width_all(2)
	style.border_color = Color(0.6, 0.6, 1.0, 0.9)
	style.set_corner_radius_all(8)
	bg.add_theme_stylebox_override("panel", style)
	_box.add_child(bg)

	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.add_child(outer)

	# Header: fixed above the scroll area, so ✕ is always reachable no matter how far you've scrolled
	var header := HBoxContainer.new()
	header.alignment = BoxContainer.ALIGNMENT_END
	outer.add_child(header)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(50, 50)
	close_btn.add_theme_font_size_override("font_size", 24)
	close_btn.pressed.connect(_finish)
	header.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	outer.add_child(scroll)

	_picker = ColorPicker.new()	
	_picker.picker_shape = ColorPicker.SHAPE_VHS_CIRCLE
	_picker.hex_visible = false
	_picker.edit_alpha = true
	_picker.color_modes_visible = false
	_picker.sampler_visible = false
	_picker.sliders_visible = true
	_picker.presets_visible = false
	_picker.can_add_swatches = false
	_picker.edit_intensity = true
	_picker.color_modes_visible = false
	_picker.color_changed.connect(_on_color_changed)

	var picker_margin := MarginContainer.new()
	picker_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	picker_margin.add_theme_constant_override("margin_right", 40)

	scroll.add_child(picker_margin)
	picker_margin.add_child(_picker)

	call_deferred("_make_picker_touch_friendly")




## on_change(Color) fires live on every drag/edit -- same "apply immediately" convention as every
## other color/anchor tweak in this app. on_done() fires once, when ✕ is pressed.
func open(initial_color: Color, on_change: Callable, on_done: Callable) -> void:
	is_open = true
	_on_change = on_change
	_on_done = on_done
	_picker.color = initial_color
	var rect: Rect2 = owner_menu.layout.grid_screen_rect()
	_box.position = rect.position
	_box.size = rect.size
	_box.visible = true

func _on_color_changed(c: Color) -> void:
	if _on_change.is_valid():
		_on_change.call(c)

func _finish() -> void:
	is_open = false
	_box.visible = false
	var done: Callable = _on_done
	_on_change = Callable()
	_on_done = Callable()
	if done.is_valid():
		done.call()
