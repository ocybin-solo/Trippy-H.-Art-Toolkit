extends VBoxContainer


signal uniform_changed(name: String, value: Variant)
# 🌟 THE SEQUENTIAL HANDHELD 5-TIER ARCHITECTURE ENGINE STATES
enum ControlState { 
	HIDDEN, 
	TIER_1_PASS, 
	TIER_2_FORMULA,
	TIER_3_UNIFORM,
	TIER_4_PARAMETER,
	TIER_5_TWEAK,
	TIER_5_COLOR,     # Tier 5 equivalent for a color uniform: the shared ColorPickerOverlay instead
	SYSTEM_MENU,
	HELP_VIEW
}

var active_state: int = ControlState.HIDDEN

# Cursor focus memory caches to remember selections when popping backwards with Button B
var last_tier1_index: int = 0  # Remembers focused Pass Layer Row
var last_tier2_index: int = 0  # Remembers focused Formula/Recipe Row
var last_tier3_index: int = 0  # Remembers focused Uniform Row (Index 0 = RESET ROW)
var last_tier4_index: int = 0  # Remembers focused Parameter/Channel Sub-Axis Row
var last_tier5_row: int = 0    # 0 = VALUE Row, 1 = SENSITIVITY Row

# System Power Menu cursor memory tracker
var system_menu_index: int = 0 # 0=APP CONFIG OPTIONS, 1=PRESETS, 2=START SCREENSAVER, 3=SCREENSAVER DEV, 4=HELP, 5=EXIT
var options_menu # OptionsMenu.gd instance (System Menu > APP CONFIG OPTIONS), created right after boot

# FUNCTION END: state_declarations


# Uniform records for the list shown in Tier 3, built by MainManager from ShaderLibrary.
# Record keys: name, type, label, default, min, max, sens, channels, is_global, recipe
var parsed_uniforms: Array = []
var active_recipe_id: String = ""   # formula whose uniforms Tier 3 shows ("" = the pass's GLOBALS list)
var active_index: int = 0
var sensitivity: float = 1.0
var current_sens_index: int = 2     # step in the per-uniform sensitivity ladder (2 = recommended)
var sens_index_memory: Dictionary = {}  # remembers the sensitivity step chosen for each uniform
var active_sub_channel: int = 0
# Shared BY REFERENCE with MainManager.pass_values[active pass]
var uniform_values: Dictionary = {}
#var is_input_blocked: bool = false

# 🌟 STRICT INPUT ISOLATION: while a menu overlay is open, MainManager
# calls set_dpad_locked(true) and both physical D-pad clusters go
# fully inert — clicking them does nothing, menu nav is driven only
# by the overlay's own ▲/▼ buttons.
var btn_param_up: Button
var btn_param_down: Button
var btn_channel_prev: Button
var btn_channel_next: Button
var btn_value_up: Button
var btn_value_down: Button
var btn_sens_left: Button
var btn_sens_right: Button

# Onboarding boot ribbon: true until the user's first real SHADER MENU
# use, so live D-pad taps before that don't overwrite the boot message.
var suppress_status_readout: bool = true

# Dictionary cache linking variable names directly to their parsed comments
var uniform_descriptions: Dictionary = {}

# Node Layout references
var label_status: Label
var label_sens_indicator: Label # Your verified thumb indicator label
var input_row_container: HBoxContainer
var btn_channel: Button

func _ready() -> void:
	setup_ui_layout()
	_setup_hold_repeat()
	# Deferred so MainManager has finished building the trench buttons and menu helpers first
	call_deferred("_boot_options_menu")

# =========================================================================
# HOLD TO REPEAT (D-pad left / right)
# A tap fires at once (these buttons now act when pressed, not when released). Holding past a short delay then
# repeats, so a value can be stepped without tapping over and over.
# To add repeat to another button, add one _make_repeating() line in _setup_hold_repeat().
# =========================================================================
const REPEAT_DELAY_MSEC: int = 400    # how long to hold before repeating starts
const REPEAT_INTERVAL_MSEC: int = 90  # time between repeats once it has started

var _repeat_button: BaseButton = null
var _repeat_handler: Callable = Callable()
var _repeat_next_msec: int = 0

func _setup_hold_repeat() -> void:
	set_process(false)
	_make_repeating(btn_param_up, _on_dpad_up)
	_make_repeating(btn_param_down, _on_dpad_down)
	_make_repeating(btn_channel_prev, _on_dpad_left)
	_make_repeating(btn_channel_next, _on_dpad_right)

func _make_repeating(btn: BaseButton, handler: Callable) -> void:
	btn.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS # the existing pressed connection now fires on press
	btn.button_down.connect(_start_repeat.bind(btn, handler))
	btn.button_up.connect(_stop_repeat)

func _start_repeat(btn: BaseButton, handler: Callable) -> void:
	if active_state == ControlState.HIDDEN and options_menu and options_menu.dev_mode():
		return # no turbo in screensaver developer mode
	_repeat_button = btn
	_repeat_handler = handler
	_repeat_next_msec = Time.get_ticks_msec() + REPEAT_DELAY_MSEC
	set_process(true)

func _stop_repeat() -> void:
	_repeat_button = null
	_repeat_handler = Callable()
	set_process(false)

func _process(_delta: float) -> void:
	if _repeat_button == null or not is_instance_valid(_repeat_button):
		_stop_repeat()
		return
	# button_up is not sent if the button loses focus mid-hold, so also make sure it is still held down
	var draw_mode: int = _repeat_button.get_draw_mode()
	if draw_mode != BaseButton.DRAW_PRESSED and draw_mode != BaseButton.DRAW_HOVER_PRESSED:
		_stop_repeat()
		return
	var now: int = Time.get_ticks_msec()
	if now >= _repeat_next_msec:
		_repeat_next_msec = now + REPEAT_INTERVAL_MSEC
		_repeat_handler.call()


## First row of the main menu (MainManager.redraw_system_power_menu asks for this text).
func dev_menu_label() -> String:
	return "🧪 SCREENSAVER DEV [%s]" % ("ON" if options_menu != null and options_menu.dev_mode() else "OFF")

func _boot_options_menu() -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager: return
	options_menu = load("res://OptionsMenu.gd").new()
	options_menu.setup(main_manager)

func setup_ui_layout() -> void:
	# THE COMPACT HARDWARE CONTROL CONTAINER
	var chassis_stack = VBoxContainer.new()
	chassis_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	chassis_stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chassis_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(chassis_stack)

	# HIGH ROW: Centered horizontal box for A and B buttons
	var action_row = HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	chassis_stack.add_child(action_row)

	# A Button (✔ ACCEPT)
	btn_channel = Button.new()
	btn_channel.text = "✔️"
	btn_channel.custom_minimum_size = Vector2(96, 96)
	btn_channel.add_theme_font_size_override("font_size", 20)
	btn_channel.add_theme_color_override("font_color", Color.GREEN)
	btn_channel.pressed.connect(_on_action_button_a) # Wired to Accept logic
	action_row.add_child(btn_channel)

	# Perfect visual axis alignment gap matching the structural width of the D-pad cross center
	var button_gap = Control.new()
	button_gap.custom_minimum_size = Vector2(96, 0)
	action_row.add_child(button_gap)

	# B Button (❌ BACK)
	btn_sens_left = Button.new()
	btn_sens_left.text = "❌"
	btn_sens_left.custom_minimum_size = Vector2(96, 96)
	btn_sens_left.add_theme_font_size_override("font_size", 20)
	btn_sens_left.add_theme_color_override("font_color", Color.RED)
	btn_sens_left.pressed.connect(_on_action_button_b) # Wired to Exit/Back logic
	action_row.add_child(btn_sens_left)

	# THE LEFT SHIFT FILTER: Adding a small layout spacer on the right side of the row 
	var left_shift_spacer = Control.new()
	left_shift_spacer.custom_minimum_size = Vector2(100, 0)
	action_row.add_child(left_shift_spacer)

	# PUSH DPAD DOWN: Increased vertical separation gap between rows
	var vertical_spacer = Control.new()
	vertical_spacer.custom_minimum_size = Vector2(0, 0)
	chassis_stack.add_child(vertical_spacer)

	# LOW ROW: Singular 3x3 D-Pad Cross Grid
	var dpad_grid = GridContainer.new()
	dpad_grid.columns = 3
	chassis_stack.add_child(dpad_grid)

	# Row 1: Dead Space | UP | Dead Space
	dpad_grid.add_child(Control.new())
	btn_param_up = Button.new()
	btn_param_up.text = "▴"
	btn_param_up.custom_minimum_size = Vector2(96, 96)
	btn_param_up.add_theme_font_size_override("font_size", 56)
	btn_param_up.pressed.connect(_on_dpad_up) # Wired to Navigate Up
	dpad_grid.add_child(btn_param_up)
	dpad_grid.add_child(Control.new())

	# Row 2: LEFT | CENTER DISPLAY INDEX | RIGHT
	btn_channel_prev = Button.new()
	btn_channel_prev.text = "◂"
	btn_channel_prev.custom_minimum_size = Vector2(96, 96)
	btn_channel_prev.add_theme_font_size_override("font_size", 56)
	btn_channel_prev.pressed.connect(_on_dpad_left) # Wired to Cycle Left
	dpad_grid.add_child(btn_channel_prev)

	# Central informational readout node block
	label_sens_indicator = Label.new()
	label_sens_indicator.text = "" 
	label_sens_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_sens_indicator.custom_minimum_size = Vector2(96, 96)
	dpad_grid.add_child(label_sens_indicator)

	btn_channel_next = Button.new()
	btn_channel_next.text = "▸"
	btn_channel_next.custom_minimum_size = Vector2(96, 96)
	btn_channel_next.add_theme_font_size_override("font_size", 56)
	btn_channel_next.pressed.connect(_on_dpad_right) # Wired to Cycle Right
	dpad_grid.add_child(btn_channel_next)

	# Row 3: Dead Space | DOWN | Dead Space
	dpad_grid.add_child(Control.new())
	btn_param_down = Button.new()
	btn_param_down.text = "▾"
	btn_param_down.custom_minimum_size = Vector2(96, 96)
	btn_param_down.add_theme_font_size_override("font_size", 56)
	btn_param_down.pressed.connect(_on_dpad_down) # Wired to Navigate Down
	dpad_grid.add_child(btn_param_down)
	dpad_grid.add_child(Control.new())


func _on_dpad_up() -> void:
	_nav_vertical(-1)

func _on_dpad_down() -> void:
	_nav_vertical(1)

func _nav_vertical(step: int) -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	# Screensaver developer mode: with no menu open, up / down cycle the transition time
	if active_state == ControlState.HIDDEN and options_menu and options_menu.dev_input("up" if step < 0 else "down"): return
	if not main_manager or active_state == ControlState.HIDDEN: return

	match active_state:
		ControlState.SYSTEM_MENU:
			if options_menu and options_menu.is_active():
				options_menu.handle_vertical(step)
				return
			system_menu_index = posmod(system_menu_index + step, 6)
			main_manager.redraw_system_power_menu()
		ControlState.HELP_VIEW:
			if options_menu and options_menu.help:
				options_menu.help.scroll(step)
		ControlState.TIER_1_PASS:
			if main_manager.active_menu_kind == main_manager.MenuKind.SELECT_PASS:
				main_manager._step_select_pass_highlight(step)
		ControlState.TIER_2_FORMULA:
			main_manager._step_formula_selection(step)
		ControlState.TIER_3_UNIFORM:
			if main_manager.active_menu_kind == main_manager.MenuKind.SHADER_MENU:
				main_manager._step_fast_travel_selection(step)
		ControlState.TIER_4_PARAMETER:
			if parsed_uniforms.is_empty(): return
			var max_channels: int = parsed_uniforms[active_index]["channels"].size()
			last_tier4_index = posmod(last_tier4_index + step, max_channels)
			main_manager.open_parameter_select_menu()
		ControlState.TIER_5_TWEAK:
			last_tier5_row = posmod(last_tier5_row + step, 2)
			main_manager.open_live_tweak_console()

# FUNCTION END: vertical_dpad_handlers


func _on_dpad_left() -> void:
	_nav_horizontal(-1)

func _on_dpad_right() -> void:
	_nav_horizontal(1)

func _nav_horizontal(step: int) -> void:
	# Screensaver developer mode: with no menu open, left / right run a transition to the previous / next preset
	if active_state == ControlState.HIDDEN and options_menu and options_menu.dev_input("left" if step < 0 else "right"): return
	if active_state == ControlState.SYSTEM_MENU and options_menu and options_menu.is_active():
		options_menu.handle_horizontal(step)
		return
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager or active_state != ControlState.TIER_5_TWEAK: return

	if last_tier5_row == 0:
		modify_active_value(float(step))
	else:
		_step_sensitivity(step, main_manager)
	main_manager.open_live_tweak_console()

## Move along the sensitivity ladder built around this uniform's recommended value.
func _step_sensitivity(step: int, main_manager) -> void:
	if parsed_uniforms.is_empty(): return
	var rec: Dictionary = parsed_uniforms[active_index]
	var ladder: Array = main_manager.library.sens_ladder(rec)
	current_sens_index = clampi(current_sens_index + step, 0, ladder.size() - 1)
	sensitivity = ladder[current_sens_index]
	sens_index_memory[rec["name"]] = current_sens_index

func enter_tweak_context() -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager or parsed_uniforms.is_empty(): return
	var rec: Dictionary = parsed_uniforms[active_index]
	var lib = main_manager.library
	var ladder: Array = lib.sens_ladder(rec)
	var start_idx: int = lib.recommended_sens_index(rec)
	current_sens_index = clampi(int(sens_index_memory.get(rec["name"], start_idx)), 0, ladder.size() - 1)
	sensitivity = ladder[current_sens_index]
	last_tier5_row = 0
	active_state = ControlState.TIER_5_TWEAK
	main_manager.open_live_tweak_console()

## Enter the shared color picker for the selected uniform (a vec4 flagged is_color) instead of the
## usual Tier 4/5 channel console. Always returns straight to TIER_3_UNIFORM when done -- colors
## never visit Tier 4 in either direction.
func enter_color_picker_context() -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager or parsed_uniforms.is_empty(): return
	active_state = ControlState.TIER_5_COLOR
	var rec: Dictionary = parsed_uniforms[active_index]
	var current: Color = uniform_values.get(rec["name"], rec["default"])
	options_menu.picker.open(current, _on_uniform_color_changed, _on_uniform_color_done)

func _on_uniform_color_changed(c: Color) -> void:
	if parsed_uniforms.is_empty(): return
	var u_name: String = parsed_uniforms[active_index]["name"]
	uniform_values[u_name] = c
	uniform_changed.emit(u_name, c)

func _on_uniform_color_done() -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager: return
	active_state = ControlState.TIER_3_UNIFORM
	main_manager.open_fast_travel_menu()

func _on_action_button_b() -> void:
	# 5-TIER POP BACKWARDS ROUTER
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager: return
	if active_state == ControlState.HIDDEN and options_menu and options_menu.dev_input("b"): return # aborts a running transition

	match active_state:
		ControlState.SYSTEM_MENU:
			if options_menu and options_menu.is_active():
				if options_menu.handle_b():
					main_manager.redraw_system_power_menu()
				return
			print("⚙️ System: Closing Main Power Menu overlay")
			active_state = ControlState.HIDDEN
			if main_manager.menu_overlay_panel and is_instance_valid(main_manager.menu_overlay_panel):
				main_manager.menu_overlay_panel.queue_free()
				main_manager.menu_overlay_panel = null
			main_manager.menu_center_host.visible = false
			main_manager.menu_peek_hidden = false
			main_manager._update_menu_host_visibility()

		ControlState.HELP_VIEW:
			if options_menu and options_menu.help:
				options_menu.help.close_and_return()
				
		ControlState.TIER_5_COLOR:
			return # no B-close: the picker covers every physical button, including this one

		ControlState.TIER_5_TWEAK:
			# Single-parameter uniforms skipped Tier 4 on the way in, so skip it on the way out too
			if not parsed_uniforms.is_empty() and parsed_uniforms[active_index]["channels"].size() == 1:
				print("🎮 Hierarchy Pop: TIER_5_TWEAK -> TIER_3_UNIFORM")
				active_state = ControlState.TIER_3_UNIFORM
				main_manager.open_fast_travel_menu()
			else:
				print("🎮 Hierarchy Pop: TIER_5_TWEAK -> TIER_4_PARAMETER")
				active_state = ControlState.TIER_4_PARAMETER
				main_manager.open_parameter_select_menu()

		ControlState.TIER_4_PARAMETER:
			print("🎮 Hierarchy Pop: TIER_4_PARAMETER -> TIER_3_UNIFORM")
			active_state = ControlState.TIER_3_UNIFORM
			main_manager.open_fast_travel_menu()

		ControlState.TIER_3_UNIFORM:
			print("🎮 Hierarchy Pop: TIER_3_UNIFORM -> TIER_2_FORMULA")
			active_state = ControlState.TIER_2_FORMULA
			main_manager.open_formula_select_menu()

		ControlState.TIER_2_FORMULA:
			print("🎮 Hierarchy Pop: TIER_2_FORMULA -> TIER_1_PASS")
			# Delete the cyan container frame completely before restoring Tier 1's unique orange frame
			if main_manager.menu_overlay_panel and is_instance_valid(main_manager.menu_overlay_panel):
				main_manager.menu_overlay_panel.queue_free()
				main_manager.menu_overlay_panel = null
				main_manager.menu_list_box = null

			active_state = ControlState.TIER_1_PASS
			main_manager.open_select_pass_menu()

		ControlState.TIER_1_PASS:
			print("Keep App Open: Collapsing overlay display to hidden dashboard frame")
			active_state = ControlState.HIDDEN
			if main_manager.select_pass_overlay_panel and is_instance_valid(main_manager.select_pass_overlay_panel):
				main_manager.select_pass_overlay_panel.queue_free()
				main_manager.select_pass_overlay_panel = null
			main_manager.menu_center_host.visible = false
			main_manager.menu_peek_hidden = false
			main_manager._update_menu_host_visibility()

		ControlState.HIDDEN:
			return

# FUNCTION END: _on_action_button_b


## Tier 1 > RESET ALL PARAMETERS: turn off every formula in Pass 2 and Pass 3 (back to clear-glass bypass) and
## forget their values, so anything added later starts from its defaults. Pass 1's pattern is left alone.
func _reset_effect_passes(main_manager) -> void:
	for p in [1, 2]:
		main_manager.pass_stack[p].clear()
		main_manager.pass_values[p].clear() # cleared in place so any link to it stays valid
		main_manager.rebuild_pass(p)
	main_manager.redraw_select_pass_menu() # the pass list now shows Pass 2 and Pass 3 as [BYPASS]

func _on_action_button_a() -> void:
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager: return
	if active_state == ControlState.HIDDEN and options_menu and options_menu.dev_input("a"): return

	match active_state:
		ControlState.HIDDEN:
			return

		ControlState.SYSTEM_MENU:
			if options_menu and options_menu.is_active():
				options_menu.handle_a()
				return
			match system_menu_index:
				0:
					if options_menu:
						options_menu.open()
				1:
					if options_menu:
						options_menu.open_presets()
				2:
					# START SCREENSAVER: runs with no menu on screen; any tap anywhere stops it
					if options_menu:
						var problem: String = options_menu.start_screensaver()
						if problem == "":
							active_state = ControlState.HIDDEN
							if main_manager.menu_overlay_panel and is_instance_valid(main_manager.menu_overlay_panel):
								main_manager.menu_overlay_panel.queue_free()
								main_manager.menu_overlay_panel = null
							main_manager.menu_peek_hidden = false
							main_manager._update_menu_host_visibility()
						else:
							options_menu.flash_menu_message(problem)
				3:
					# SCREENSAVER DEV: switch the mode on / off; the menu stays open until B is pressed
					if options_menu:
						options_menu.toggle_dev_mode()
						main_manager.redraw_system_power_menu()
				4:
					# HELP: shows README.md; the main menu closes, and ✔️ returns to normal
					if options_menu and options_menu.help:
						options_menu.help.open()
						active_state = ControlState.HELP_VIEW
						main_manager.menu_peek_hidden = false
						if main_manager.menu_overlay_panel and is_instance_valid(main_manager.menu_overlay_panel):
							main_manager.menu_overlay_panel.queue_free()
							main_manager.menu_overlay_panel = null
				5: get_tree().quit()

		ControlState.TIER_1_PASS:
			# The last row is RESET ALL PARAMETERS: it clears the effect passes instead of opening a pass
			if last_tier1_index == main_manager.PASS_LABELS.size() - 1:
				_reset_effect_passes(main_manager)
				return
			print("🎮 Hierarchy Push: TIER_1_PASS -> TIER_2_FORMULA")
			active_state = ControlState.TIER_2_FORMULA
			main_manager.close_select_pass_menu(true) # locks in last_tier1_index as the active pass
			main_manager.enter_formula_menu()

		ControlState.TIER_2_FORMULA:
			var rows: Array = main_manager.get_formula_rows()
			if last_tier2_index >= rows.size(): return
			var row: Dictionary = rows[last_tier2_index]
			match row["kind"]:
				"reset":
					print("🧹 Hardware Trigger: Resetting the active pass")
					main_manager.reset_active_pass()
					main_manager.redraw_formula_select_menu()
				"globals":
					print("🎮 Hierarchy Push: TIER_2_FORMULA -> TIER_3_UNIFORM (GLOBALS)")
					main_manager.prepare_uniform_list("")
					active_state = ControlState.TIER_3_UNIFORM
					main_manager.open_fast_travel_menu()
				"recipe":
					print("🎮 Hierarchy Push: TIER_2_FORMULA -> TIER_3_UNIFORM (%s)" % row["id"])
					main_manager.activate_recipe(row["id"])
					main_manager.prepare_uniform_list(row["id"])
					active_state = ControlState.TIER_3_UNIFORM
					main_manager.open_fast_travel_menu()

		ControlState.TIER_3_UNIFORM:
			if last_tier3_index == 0:
				main_manager.tier3_row0_action()
				return
			if parsed_uniforms.is_empty() or last_tier3_index - 1 >= parsed_uniforms.size(): return
			active_index = last_tier3_index - 1
			last_tier4_index = 0
			var rec: Dictionary = parsed_uniforms[active_index]
			if rec.get("is_color", false):
				print("🎮 Hierarchy Push: TIER_3_UNIFORM -> TIER_5_COLOR (color picker)")
				enter_color_picker_context()
			# A uniform with a single parameter has nothing to choose in Tier 4: jump straight to Tier 5
			elif rec["channels"].size() == 1:
				print("🎮 Hierarchy Push: TIER_3_UNIFORM -> TIER_5_TWEAK (single parameter)")
				enter_tweak_context()
			else:
				print("🎮 Hierarchy Push: TIER_3_UNIFORM -> TIER_4_PARAMETER")
				active_state = ControlState.TIER_4_PARAMETER
				main_manager.open_parameter_select_menu()

		ControlState.TIER_4_PARAMETER:
			print("🎮 Hierarchy Push: TIER_4_PARAMETER -> TIER_5_TWEAK")
			enter_tweak_context()

		ControlState.TIER_5_TWEAK:
			return
		ControlState.TIER_5_COLOR:
			return # the picker's own ✕ button is the only way out, by design

# FUNCTION END: _on_action_button_a


func _on_channel_toggle_pressed() -> void:
	if parsed_uniforms.is_empty(): return
	var u_type = parsed_uniforms[active_index]["type"]
	if u_type == "vec2": active_sub_channel = posmod(active_sub_channel + 1, 2)
	elif u_type == "vec4": active_sub_channel = posmod(active_sub_channel + 1, 4)
	else: active_sub_channel = 0
	update_status_readout()

func _on_channel_back() -> void:
	if parsed_uniforms.is_empty(): return
	var u_type = parsed_uniforms[active_index]["type"]
	if u_type == "vec2": active_sub_channel = posmod(active_sub_channel - 1, 2)
	elif u_type == "vec4": active_sub_channel = posmod(active_sub_channel - 1, 4)
	else: active_sub_channel = 0
	update_status_readout()
	
	
func modify_active_value(direction_multiplier: float) -> void:
	if parsed_uniforms.is_empty(): return
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if not main_manager: return
	var lib = main_manager.library

	var rec: Dictionary = parsed_uniforms[active_index]
	var u_name: String = rec["name"]
	var u_type: String = rec["type"]
	var idx: int = clampi(last_tier4_index, 0, rec["channels"].size() - 1)

	# Start from the cached value, or the shader's own default if this uniform was never touched
	var current: Variant = uniform_values.get(u_name, rec["default"])
	var new_comp: float = lib.get_component(current, u_type, idx) + direction_multiplier * sensitivity

	# Snap away float drift (0.1 + 0.2 = 0.30000000000000004), but on a grid finer than this uniform's
	# smallest step -- a fixed 0.000001 grid would round tiny @sens values away entirely.
	var ladder: Array = lib.sens_ladder(rec)
	var snap: float = minf(0.000001, float(ladder[0]) * 0.1)
	if snap <= 0.0:
		snap = 0.000001
	new_comp = snappedf(lib.clamp_component(rec, new_comp), snap)

	uniform_values[u_name] = lib.set_component(current, u_type, idx, new_comp)
	uniform_changed.emit(u_name, uniform_values[u_name])
	update_status_readout()

# FUNCTION END: modify_active_value


func get_sub_channel_name(u_type: String) -> String:
	if u_type == "vec2": return " [X]" if active_sub_channel == 0 else " [Y]"
	elif u_type == "vec4":
		var channels = [" [RED]", " [GREEN]", " [BLUE]", " [ALPHA]"]
		return channels[active_sub_channel]
	return ""

func update_status_readout() -> void:
	if suppress_status_readout or label_status == null: return
	if parsed_uniforms.is_empty(): return
	var active = parsed_uniforms[active_index]
	var u_type = active["type"]
	if u_type == "float": btn_channel.text = "FLOAT"
	else: btn_channel.text = "CH: %d" % active_sub_channel
	
	var p_name = active["name"]
	var sub_ch = get_sub_channel_name(u_type)
	var val_str = str(uniform_values.get(p_name, active["default"]))
	var sens_str = str(sensitivity)
	var desc_str = uniform_descriptions.get(p_name, "Adjustable hardware matrix parameter.")
	
	# Query the registered global group to dynamically find our current active pass layer index
	var layer_header: String = "[PASS 1: PATTERN]"
	var main_manager = get_tree().get_first_node_in_group("main_manager")
	if main_manager:
		match main_manager.get("active_shader_layer"):
			0: layer_header = "[PASS 1: PATTERN]"
			1: layer_header = "[PASS 2: WARP]"
			2: layer_header = "[PASS 3: FILTERS]"
	
	# --- UPGRADED REAL-TIME HUD STATUS STRING CONCATENATION ---
	label_status.text = "  %s  •  PARAM: %s (%s)%s  •  VALUE: %s  •  SENSITIVITY: %s  \nℹ️  %s  " % [
		layer_header, p_name, u_type, sub_ch, val_str, sens_str, desc_str
	]
	
	if label_sens_indicator:
		label_sens_indicator.text = sens_str
		
func refresh_menu_context_labels(_menu_is_active: bool) -> void:
	# 🌟 Safe Empty Stub: Stripped legacy text swapping to protect the single-thumb layout
	pass
