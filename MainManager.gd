extends VBoxContainer

# Layout Structure Modules
var top_status_holder: PanelContainer
var display_row_container: HBoxContainer
var upper_display_area: CenterContainer
var main_layout: VBoxContainer
var control_panel: VBoxContainer

# Dedicated Visual Warning Label for the Safety Valve
var label_safety_alert: Label
var label_perf_monitor: Label
var vram_display_visible: bool = false
var perf_bar: PanelContainer


# --- START MENU HOOKS ---
var menu_overlay_panel: PanelContainer
var menu_list_box: VBoxContainer

# --- OVERLAY LAYERING (menus always paint above the viewports) ---
var ui_canvas_layer: CanvasLayer
var menu_canvas_layer: CanvasLayer
var menu_center_host: CenterContainer

# --- SELECT PASS OVERLAY HOOKS ---
var select_pass_overlay_panel: PanelContainer
var select_pass_list_box: VBoxContainer
const PASS_LABELS: Array = ["PASS 1: BASE PATTERN", "PASS 2: WARPING", "PASS 3: FILTERS", "RESET ALL PARAMETERS"]

# --- UNIFIED MENU STATE (only one overlay + one morphed button at a time) ---
enum MenuKind { NONE, SELECT_PASS, SHADER_MENU }
var active_menu_kind: int = MenuKind.NONE
var btn_select_pass: Button
var btn_shader_menu: Button
var btn_screensaver_stub: Button


# --- ONBOARDING BOOT RIBBON ---
# The actual suppress/release flag lives on control_panel
# (DynamicUI.suppress_status_readout) since that's where label_status
# is owned; this is just the text it shows until then.
const ONBOARDING_TEXT: String = "Please choose an option in the 'Shader Menu'"


# --- TRIPLE PASS VIEWPORT ARCHITECTURE ---
var pass1_viewport: SubViewport
var pass1_rect: ColorRect
var pass1_material: ShaderMaterial

var pass2_viewport: SubViewport
var pass2_rect: ColorRect
var pass2_material: ShaderMaterial

var canvas_container: SubViewportContainer
var pass3_viewport: SubViewport
var pass3_rect: ColorRect
var pass3_material: ShaderMaterial


# Core State Trackers
var current_preset: PatternPreset
var current_time: float = 0.0

# SELECT & START State Trackers
var active_shader_layer: int = 0
var is_menu_open: bool = false
var menu_peek_hidden: bool = false

# --- SHADER LIBRARY PIPELINE STATE ---
# ShaderLibrary.gd is the single source of truth for every menu. Per pass we track which
# recipes are active (stack order), the uniform records of the last assembled shader, and
# a value cache keyed by the final uniform name.
const DEBUG_DUMMY_RECIPES: int = 0 # extra test formulas so long Tier 2 lists can be tested; set to 0 when done
const MENU_PAGE_ROWS: int = 6       # rows visible at once before a menu list scrolls
var library
var pass_stack: Array = [[], [], []]
var pass_records: Array = [[], [], []]
var pass_values: Array = [{}, {}, {}]

func _ready() -> void:
	# 🌟 REGISTER GLOBAL NODE GROUP (Removes fixed-depth path dependencies)
	add_to_group("main_manager")
	
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_PASS
	
	current_preset = load("res://PatternPreset.gd").new()
	setup_three_pass_pipeline()
	setup_interface_layer()
	## performance display
	var perf_layer := CanvasLayer.new()
	perf_layer.layer = 3
	add_child(perf_layer)

	perf_bar = PanelContainer.new()
	var perf_style := StyleBoxFlat.new()
	perf_style.bg_color = Color(0, 0, 0, 0.75)
	perf_style.content_margin_top = 2
	perf_style.content_margin_bottom = 2
	perf_bar.add_theme_stylebox_override("panel", perf_style)
	perf_bar.anchor_left = 0.0
	perf_bar.anchor_right = 1.0
	perf_bar.anchor_top = 1.0
	perf_bar.anchor_bottom = 1.0
	perf_bar.offset_left = 0.0
	perf_bar.offset_right = 0.0
	perf_bar.offset_top = -28.0
	perf_bar.offset_bottom = 0.0
	perf_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	perf_bar.visible = false
	perf_layer.add_child(perf_bar)
	label_perf_monitor = Label.new()
	label_perf_monitor.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_perf_monitor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	perf_bar.add_child(label_perf_monitor)	
	## end of vram performance warning 
	
	load_default_test_shaders()
	
	# Cleaned up container constraints for the compact hardware chassis block
	
	control_panel.custom_minimum_size = Vector2(0, 240)
	control_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	

## Force-closes whatever menu/overlay is currently open, however deep it is. Wired to the button
## that used to toggle the performance readout (see the "vram" button in ControllerLayout.gd) --
## that readout is now automatic (see _check_hardware_gpu_safety()) instead of manually toggled.
func close_any_open_menu() -> void:
	menu_peek_hidden = false
	if control_panel.active_state == control_panel.ControlState.HIDDEN:
		return

	# A reposition session in progress gets reverted rather than left half-applied.
	if control_panel.options_menu and control_panel.options_menu.layout and control_panel.options_menu.layout.editing:
		control_panel.options_menu.layout.edit_cancel()

	# The readme has its own separate panel/open-state, same as the existing PWR-button close path.
	if control_panel.options_menu and control_panel.options_menu.help and control_panel.options_menu.help.is_open:
		control_panel.options_menu.help.close()

	if select_pass_overlay_panel and is_instance_valid(select_pass_overlay_panel):
		select_pass_overlay_panel.queue_free()
		select_pass_overlay_panel = null
	if menu_overlay_panel and is_instance_valid(menu_overlay_panel):
		menu_overlay_panel.queue_free()
		menu_overlay_panel = null
		menu_list_box = null

	menu_center_host.visible = false
	menu_peek_hidden = false
	_update_menu_host_visibility()
	is_menu_open = false
	active_menu_kind = MenuKind.NONE
	control_panel.active_state = control_panel.ControlState.HIDDEN


## Single source of truth for whether the menu panel is actually drawn: it must be both logically
## open (some tier/menu state is active) AND not currently peek-hidden by the "hide menu" button.
func _update_menu_host_visibility() -> void:
	var logically_open: bool = control_panel.active_state != control_panel.ControlState.HIDDEN
	menu_center_host.visible = logically_open and not menu_peek_hidden

## Wired to the button that previously force-closed menus. Hides the menu panel WITHOUT touching
## any menu state -- same tier, same cursor, same everything -- so pressing it again reveals
## exactly what was there. Does nothing if no menu is open.

func toggle_menu_hidden() -> void:
	if control_panel.active_state == control_panel.ControlState.HIDDEN:
		return
	menu_peek_hidden = not menu_peek_hidden
	_update_menu_host_visibility()
	if control_panel.options_menu and control_panel.options_menu.layout:
		control_panel.options_menu.layout.set_hide_button_icon(menu_peek_hidden)


func setup_three_pass_pipeline() -> void:
	display_row_container = HBoxContainer.new()
	display_row_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	display_row_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	display_row_container.alignment = BoxContainer.ALIGNMENT_CENTER
	display_row_container.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(display_row_container)
	
	upper_display_area = CenterContainer.new()
	upper_display_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upper_display_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	upper_display_area.mouse_filter = Control.MOUSE_FILTER_PASS
	display_row_container.add_child(upper_display_area)
	
	var canvas_stack = VBoxContainer.new()
	canvas_stack.alignment = BoxContainer.ALIGNMENT_CENTER
	canvas_stack.mouse_filter = Control.MOUSE_FILTER_PASS
	upper_display_area.add_child(canvas_stack)
	
	# 🌟 STRETCH AUTO-INFLATE: Force the container to expand its textures fully
	canvas_container = SubViewportContainer.new()
	canvas_container.stretch = true
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_stack.add_child(canvas_container)
	
	label_safety_alert = Label.new()
	label_safety_alert.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_safety_alert.text = ""
	label_safety_alert.add_theme_color_override("font_color", Color.RED)
	label_safety_alert.add_theme_font_size_override("font_size", 14)
	canvas_stack.add_child(label_safety_alert)
	
	# 🌟 ADAPTIVE PIXEL METRICS: Query maximum available device screen height
	var max_canvas_resolution: Vector2 = Vector2(DisplayServer.window_get_size().y, DisplayServer.window_get_size().y)
	canvas_container.custom_minimum_size = max_canvas_resolution
	
	# --- PASS 1: GENERATIVE MATH BUFFER ---
	pass1_viewport = SubViewport.new()
	pass1_viewport.size = max_canvas_resolution # 🌟 Auto-inflated to max square
	pass1_viewport.disable_3d = true
	pass1_viewport.transparent_bg = false
	pass1_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	pass1_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(pass1_viewport)
	
	pass1_rect = ColorRect.new()
	pass1_rect.size = max_canvas_resolution
	pass1_rect.custom_minimum_size = max_canvas_resolution
	pass1_viewport.add_child(pass1_rect)
	
	pass1_material = ShaderMaterial.new()
	pass1_rect.material = pass1_material
	
	# --- PASS 2: GEOMETRIC WARPING BUFFER ---
	pass2_viewport = SubViewport.new()
	pass2_viewport.size = max_canvas_resolution # 🌟 Auto-inflated to max square
	pass2_viewport.disable_3d = true
	pass2_viewport.transparent_bg = false
	pass2_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	pass2_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(pass2_viewport)
	
	pass2_rect = ColorRect.new()
	pass2_rect.size = max_canvas_resolution
	pass2_rect.custom_minimum_size = max_canvas_resolution
	pass2_viewport.add_child(pass2_rect)
	
	pass2_material = ShaderMaterial.new()
	pass2_rect.material = pass2_material
	
	# --- PASS 3: POST-PROCESS FILTER BUFFER (VISIBLE SCREEN) ---
	pass3_viewport = SubViewport.new()
	pass3_viewport.size = max_canvas_resolution # 🌟 Auto-inflated to max square
	pass3_viewport.disable_3d = true
	pass3_viewport.transparent_bg = false
	pass3_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	pass3_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	canvas_container.add_child(pass3_viewport)
	
	pass3_rect = ColorRect.new()
	pass3_rect.size = max_canvas_resolution
	pass3_rect.custom_minimum_size = max_canvas_resolution
	pass3_viewport.add_child(pass3_rect)
	
	pass3_material = ShaderMaterial.new()
	pass3_rect.material = pass3_material
	
	# Establish the explicit texture pipeline bindings
	pass2_material.set_shader_parameter("u_pattern_texture", pass1_viewport.get_texture())
	pass3_material.set_shader_parameter("u_warped_texture", pass2_viewport.get_texture())

func setup_interface_layer() -> void:
	ui_canvas_layer = CanvasLayer.new()
	ui_canvas_layer.layer = 1
	add_child(ui_canvas_layer)

	# THE HORIZONTAL LANDSCAPE BASE SPLIT CHASSIS
	var landscape_root = HBoxContainer.new()
	landscape_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	landscape_root.mouse_filter = Control.MOUSE_FILTER_PASS
	ui_canvas_layer.add_child(landscape_root)

	# MAXIMUM VIEWPORT HOST LAYER
	var viewport_host = Control.new()
	viewport_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_host.custom_minimum_size.y = DisplayServer.window_get_size().y
	viewport_host.custom_minimum_size.x = viewport_host.custom_minimum_size.y
	landscape_root.add_child(viewport_host)

	if canvas_container.get_parent():
		canvas_container.get_parent().remove_child(canvas_container)
	viewport_host.add_child(canvas_container)
	canvas_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# THE IN-VIEWPORT TEXT MENU OVERLAY LAYER
	menu_center_host = CenterContainer.new()
	menu_center_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	menu_center_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_center_host.visible = false

	menu_center_host.z_index = 2
	viewport_host.add_child(menu_center_host)

	# MID-LEFT TRENCH: Vertical holder for utility toggles
	var utility_trench = VBoxContainer.new()
	utility_trench.custom_minimum_size = Vector2(96, 0)
	utility_trench.alignment = BoxContainer.ALIGNMENT_CENTER
	landscape_root.add_child(utility_trench)


	# 🌟 OPT Button on BOTTOM
	btn_select_pass = Button.new()
	btn_select_pass.text = "💠\n"
	btn_select_pass.custom_minimum_size = Vector2(96, 96)
	btn_select_pass.size_flags_vertical = Control.SIZE_SHRINK_END
	#btn_select_pass.add_theme_color_override("font_color", Color.CORNFLOWER_BLUE)
	btn_select_pass.add_theme_font_size_override("font_size", 24)
	# 🌟 WIRE RE-CONNECTED: Link OPT button to its handler method
	btn_select_pass.pressed.connect(_on_select_pass_button_pressed)
	utility_trench.add_child(btn_select_pass)
	# Flexible expanding spacer between the two elements
	var util_spacer = Control.new()
	util_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	utility_trench.add_child(util_spacer)
		# 🌟 PWR Button on TOP
	btn_shader_menu = Button.new()
	btn_shader_menu.text = "⚙️\n"
	btn_shader_menu.custom_minimum_size = Vector2(96, 96)
	btn_shader_menu.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	btn_shader_menu.add_theme_color_override("font_color", Color.GOLD)
	btn_shader_menu.add_theme_font_size_override("font_size", 24)
	# 🌟 WIRE RE-CONNECTED: Link PWR button to its handler method
	btn_shader_menu.pressed.connect(_on_shader_menu_button_pressed)
	utility_trench.add_child(btn_shader_menu)



	# RIGHT SIDE CONSOLE CONTROL CHASSIS
	control_panel = load("res://DynamicUI.gd").new()
	control_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	landscape_root.add_child(control_panel)
	control_panel.uniform_changed.connect(_on_ui_uniform_modified)

	active_shader_layer = 0

# FUNCTION END: setup_interface_layer


## Select Pass button is the MENU button which opens or hides the menu system
func _on_select_pass_button_pressed() -> void:

		# A peeked menu is neither "open" nor "closed" as far as the toggle logic below is concerned --
	# it's paused. Any press that would normally open or close something should just reveal it first.
	if menu_peek_hidden:
		menu_peek_hidden = false
		_update_menu_host_visibility()
		if control_panel.options_menu and control_panel.options_menu.layout:
			control_panel.options_menu.layout.set_hide_button_icon(false)
		return
			# 🌟 THE ■ OPT TOGGLE: Handles instant entry and complete exit cleanout
	if control_panel.active_state == control_panel.ControlState.HIDDEN:
		print("■ OPT Tapped: Initializing Overlay Tree -> TIER_1_PASS")
		control_panel.active_state = control_panel.ControlState.TIER_1_PASS
		open_select_pass_menu()
	else:
		print("■ OPT Tapped: Direct Escape Cutoff -> Forcing HIDDEN State")
		control_panel.active_state = control_panel.ControlState.HIDDEN
		
		# WIPE ALL OVERLAYS IMMEDIATELY: Ensure zero transparent blocks linger
		if select_pass_overlay_panel and is_instance_valid(select_pass_overlay_panel):
			select_pass_overlay_panel.queue_free()
			select_pass_overlay_panel = null
		if menu_overlay_panel and is_instance_valid(menu_overlay_panel):
			menu_overlay_panel.queue_free()
			menu_overlay_panel = null
			
		menu_center_host.visible = false
		menu_peek_hidden = false
		_update_menu_host_visibility()

# FUNCTION END: _on_select_pass_button_pressed

func open_select_pass_menu() -> void:
	is_menu_open = true
	active_menu_kind = MenuKind.SELECT_PASS


	menu_center_host.visible = true
	menu_peek_hidden = false
	_update_menu_host_visibility()
	select_pass_overlay_panel = PanelContainer.new()
	select_pass_overlay_panel.custom_minimum_size = Vector2(340, 220)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.04, 0.75)
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.55, 0.0, 0.9)
	style.set_corner_radius_all(8)
	select_pass_overlay_panel.add_theme_stylebox_override("panel", style)
	menu_center_host.add_child(select_pass_overlay_panel)

	var panel_body = VBoxContainer.new()
	panel_body.alignment = BoxContainer.ALIGNMENT_CENTER
	select_pass_overlay_panel.add_child(panel_body)

	select_pass_list_box = VBoxContainer.new()
	select_pass_list_box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel_body.add_child(select_pass_list_box)

	# 🌟 FORCE UNLOCKED: Ensure physical D-pads can drive menu navigation strings
	#control_panel.is_input_blocked = false
	#control_panel.set_dpad_locked(false)
	redraw_select_pass_menu()

func _step_select_pass_highlight(direction: int) -> void:
	# Scroll the cursor variable across the 3 available pipeline layers
	control_panel.last_tier1_index = posmod(control_panel.last_tier1_index + direction, PASS_LABELS.size())
	redraw_select_pass_menu()

# FUNCTION END: _step_select_pass_highlight


func redraw_select_pass_menu() -> void:
	if not select_pass_list_box: return
	for child in select_pass_list_box.get_children(): child.queue_free()

	var label_title = Label.new()
	label_title.text = " 🔄 SELECT RENDERING PASS LAYER "
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.ORANGE)
	select_pass_list_box.add_child(label_title)

	# Determine active states based on whether any formula is active in the pass
	var p2_is_active = pass_stack[1].size() > 0
	var p3_is_active = pass_stack[2].size() > 0
	
	var pass_statuses = [
			"[ACTIVE]",
			"[ACTIVE]" if p2_is_active else "[BYPASS]",
			"[ACTIVE]" if p3_is_active else "[BYPASS]",
			""
		]

	for i in range(PASS_LABELS.size()):
		var lbl = Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# Use your focus memory cache variable (last_tier1_index) to track the cursor row
		if i == control_panel.last_tier1_index:
			lbl.text = " ▶  %s  %s  ◀ " % [PASS_LABELS[i], pass_statuses[i]]
			lbl.add_theme_color_override("font_color", Color.YELLOW)
		else:
			lbl.text = "    %s  %s    " % [PASS_LABELS[i], pass_statuses[i]]
			lbl.add_theme_color_override("font_color", Color.DARK_GRAY)
		select_pass_list_box.add_child(lbl)

# FUNCTION END: redraw_select_pass_menu

func close_select_pass_menu(confirm: bool) -> void:
	if confirm:
		# The cursor row (last_tier1_index) IS the chosen pass. All tweaks route to it from now on.
		active_shader_layer = control_panel.last_tier1_index
		control_panel.uniform_values = pass_values[active_shader_layer]
		control_panel.parsed_uniforms = []
		control_panel.active_recipe_id = ""
		control_panel.active_index = 0
		control_panel.active_sub_channel = 0

	control_panel.update_status_readout()

	is_menu_open = false
	active_menu_kind = MenuKind.NONE
	#btn_select_pass.text = LABEL_SELECT_PASS_IDLE
	menu_center_host.visible = false


	if select_pass_overlay_panel and is_instance_valid(select_pass_overlay_panel):
		select_pass_overlay_panel.queue_free()
		select_pass_overlay_panel = null


# ------------------------------------------------------------------
# SHADER MENU -- the PWR button / system menu below is unchanged.
# ------------------------------------------------------------------
func _on_shader_menu_button_pressed() -> void:
	if menu_peek_hidden:
		menu_peek_hidden = false
		_update_menu_host_visibility()
		if control_panel.options_menu and control_panel.options_menu.layout:
			control_panel.options_menu.layout.set_hide_button_icon(false)
		return
	# 🌟 THE ⏻ PWR TOGGLE: Master handler for the System Main Menu overlay
	if control_panel.active_state == control_panel.ControlState.SYSTEM_MENU:
		print("🟡 Tapped: Direct Escape Cutoff -> Forcing HIDDEN State")
		control_panel.active_state = control_panel.ControlState.HIDDEN
		if menu_overlay_panel and is_instance_valid(menu_overlay_panel):
			menu_overlay_panel.queue_free()
			menu_overlay_panel = null
		menu_center_host.visible = false
		menu_peek_hidden = false
		_update_menu_host_visibility()
		# The readme has its own panel outside menu_overlay_panel, so hiding the shared one above does
		# not close it on its own -- tell it explicitly so its own "am I open" state stays correct
		if control_panel.options_menu and control_panel.options_menu.help and control_panel.options_menu.help.is_open:
			control_panel.options_menu.help.close()
		return

	print("🟡 Tapped: Opening System Main Menu -> SYSTEM_MENU")
	control_panel.active_state = control_panel.ControlState.SYSTEM_MENU
	control_panel.system_menu_index = 0 # Default highlight cursor to row 0 (APP Config options)

	# Clean up any lingering art menus that might be sitting open underneath
	if select_pass_overlay_panel and is_instance_valid(select_pass_overlay_panel):
		select_pass_overlay_panel.queue_free()
		select_pass_overlay_panel = null

	# Also clean up any Tier 2-5 / Options / Presets / Controller Layout / Screensaver Dev panel that
	# might still be open in the SHARED overlay panel, so it doesn't linger underneath the new one
	if menu_overlay_panel and is_instance_valid(menu_overlay_panel):
		menu_overlay_panel.queue_free()
		menu_overlay_panel = null

	# The readme uses its own separate panel rather than the shared one above, so it needs its own check
	if control_panel.options_menu and control_panel.options_menu.help and control_panel.options_menu.help.is_open:
		control_panel.options_menu.help.close()

	# Build a clean, high-contrast text-mode box for System operations
	menu_center_host.visible = true
	menu_peek_hidden = false
	_update_menu_host_visibility()
	menu_overlay_panel = PanelContainer.new()
	menu_overlay_panel.custom_minimum_size = Vector2(340, 220)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.01, 0.01, 0.75) # Distinct deep charcoal-red tint
	style.set_border_width_all(2)
	style.border_color = Color(1.0, 0.2, 0.2, 0.9) # Crimson alert frame
	style.set_corner_radius_all(6)
	menu_overlay_panel.add_theme_stylebox_override("panel", style)
	menu_center_host.add_child(menu_overlay_panel)

	menu_list_box = VBoxContainer.new()
	menu_list_box.alignment = BoxContainer.ALIGNMENT_CENTER
	menu_overlay_panel.add_child(menu_list_box)

	redraw_system_power_menu()

func redraw_system_power_menu() -> void:
	if not menu_list_box: return
	for child in menu_list_box.get_children(): child.queue_free()

	var label_title = Label.new()
	label_title.text = " ⏻ SYSTEM MAIN MENU "
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.RED)
	menu_list_box.add_child(label_title)

	var options = ["⚙ APP CONFIG OPTIONS", "🗂 PRESETS", "▶ START SCREENSAVER", control_panel.dev_menu_label(), "❓ HELP", "⏻ EXIT APPLICATION"]
	for i in range(options.size()):
		var lbl = Label.new()
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if i == control_panel.system_menu_index:
			lbl.text = " ▶  %s  ◀ " % options[i]
			lbl.add_theme_color_override("font_color", Color.YELLOW)
		else:
			lbl.text = "    %s    " % options[i]
			lbl.add_theme_color_override("font_color", Color.DARK_GRAY)
		menu_list_box.add_child(lbl)

# FUNCTION END: _on_shader_menu_button_pressed


# =========================================================================
# SHADER LIBRARY PIPELINE (recipes -> one assembled shader per pass)
# =========================================================================
func _pass_material(p: int) -> ShaderMaterial:
	match p:
		0: return pass1_material
		1: return pass2_material
	return pass3_material

## Rebuild one pass from its active recipe stack, then push every value into the material.
func rebuild_pass(p: int) -> void:
	var built: Dictionary = library.assemble_pass(p, pass_stack[p])
	var new_shader := Shader.new()
	new_shader.code = built["code"]
	var mat: ShaderMaterial = _pass_material(p)
	mat.shader = new_shader
	pass_records[p] = built["uniforms"]
	# Re-bind the texture inputs after a shader swap
	if p == 1:
		mat.set_shader_parameter("u_pattern_texture", pass1_viewport.get_texture())
	elif p == 2:
		mat.set_shader_parameter("u_warped_texture", pass2_viewport.get_texture())
	library.apply_values(mat, pass_records[p], pass_values[p])

## Add a formula to the active pass (single-select formulas replace whatever is there).
func activate_recipe(id: String) -> void:
	var p: int = active_shader_layer
	if pass_stack[p].has(id):
		return
	if library.is_stackable(id):
		pass_stack[p].append(id)
	else:
		pass_stack[p] = [id]
	rebuild_pass(p)

## Turn one formula off and put its values back to defaults so re-adding starts fresh.
func remove_recipe(id: String) -> void:
	var p: int = active_shader_layer
	library.reset_values(pass_records[p], pass_values[p], id)
	pass_stack[p].erase(id)
	rebuild_pass(p)

## Tier 2 RESET: everything in the active pass back to defaults (effect passes go back to bypass).
func reset_active_pass() -> void:
	var p: int = active_shader_layer
	pass_values[p].clear() # cleared in place so control_panel.uniform_values stays linked
	if p != 0:
		pass_stack[p].clear()
	rebuild_pass(p)

## Rows for the Tier 2 menu: [RESET], [GLOBALS], then every formula for the active pass.
func get_formula_rows() -> Array:
	var p: int = active_shader_layer
	var rows: Array = []
	rows.append({"kind": "reset", "label": "[ RESET ALL VALUES ]" if p == 0 else "[ RESET PASS TO BYPASS ]"})
	rows.append({"kind": "globals", "label": "⚙ GLOBAL UNIFORMS"})
	for r in library.recipes_for_pass(p):
		rows.append({"kind": "recipe", "id": r["id"], "label": r["name"], "active": pass_stack[p].has(r["id"])})
	return rows

## Enter Tier 2 with the cursor on the first formula (never on a reset row).
func enter_formula_menu() -> void:
	control_panel.last_tier2_index = mini(2, get_formula_rows().size() - 1)
	open_formula_select_menu()

## Build the Tier 3 list: a formula's own uniforms, or the pass's globals when recipe_id is "".
func prepare_uniform_list(recipe_id: String) -> void:
	var p: int = active_shader_layer
	var list: Array
	if recipe_id == "":
		list = library.global_uniforms(pass_records[p])
	else:
		# Filters out uniforms belonging to a style other than the one currently active, so a master
		# shader with several style variants only shows the controls for the style you're actually on.
		list = library.visible_uniforms(pass_records[p], recipe_id, pass_values[p])
	control_panel.active_recipe_id = recipe_id
	control_panel.parsed_uniforms = list
	control_panel.active_index = 0
	control_panel.last_tier3_index = 1 if not list.is_empty() else 0

## Tier 3 row 0: reset globals / reset a Pass 1 pattern / remove an effect formula.
func tier3_row0_action() -> void:
	var p: int = active_shader_layer
	var rid: String = control_panel.active_recipe_id
	if rid == "":
		for rec in library.global_uniforms(pass_records[p]):
			pass_values[p][rec["name"]] = rec["default"]
		library.apply_values(_pass_material(p), pass_records[p], pass_values[p])
		redraw_fast_travel_menu()
	elif p == 0:
		library.reset_values(pass_records[p], pass_values[p], rid)
		library.apply_values(_pass_material(p), pass_records[p], pass_values[p])
		redraw_fast_travel_menu()
	else:
		remove_recipe(rid)
		control_panel.active_state = control_panel.ControlState.TIER_2_FORMULA
		open_formula_select_menu()

func _tier3_row0_label() -> String:
	if control_panel.active_recipe_id == "":
		return "[ RESET GLOBALS ]"
	if active_shader_layer == 0:
		return "[ RESET TO DEFAULTS ]"
	return "[ REMOVE THIS FORMULA ]"


# =========================================================================
# MENU DRAWING HELPERS
# =========================================================================
## Build (or recycle) the cyan overlay shell shared by Tiers 2 to 5.
func _ensure_cyan_panel() -> void:
	menu_center_host.visible = true
	menu_peek_hidden = false
	_update_menu_host_visibility()
	if is_instance_valid(menu_overlay_panel) and is_instance_valid(menu_list_box):
		for child in menu_list_box.get_children(): child.queue_free()
		return
	if is_instance_valid(menu_overlay_panel):
		menu_overlay_panel.queue_free()

	menu_overlay_panel = PanelContainer.new()
	menu_overlay_panel.custom_minimum_size = Vector2(340, 260)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.04, 0.75)
	style.set_border_width_all(2)
	style.border_color = Color(0.0, 0.85, 1.0, 0.9)
	style.set_corner_radius_all(8)
	menu_overlay_panel.add_theme_stylebox_override("panel", style)
	menu_center_host.add_child(menu_overlay_panel)

	var panel_body = VBoxContainer.new()
	panel_body.alignment = BoxContainer.ALIGNMENT_CENTER
	menu_overlay_panel.add_child(panel_body)

	menu_list_box = VBoxContainer.new()
	menu_list_box.alignment = BoxContainer.ALIGNMENT_CENTER
	panel_body.add_child(menu_list_box)

func _add_menu_row(text: String, selected: bool, hl_color: Color = Color.YELLOW, dim_color: Color = Color.DARK_GRAY) -> void:
	var lbl = Label.new()
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if selected:
		lbl.text = " ▶  %s  ◀ " % text
		lbl.add_theme_color_override("font_color", hl_color)
	else:
		lbl.text = "    %s    " % text
		lbl.add_theme_color_override("font_color", dim_color)
	menu_list_box.add_child(lbl)

func _add_scroll_hint(visible_hint: bool, arrow: String) -> void:
	var lbl = Label.new()
	lbl.text = arrow if visible_hint else " "
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color.DIM_GRAY)
	menu_list_box.add_child(lbl)

## First visible row so the cursor stays inside a MENU_PAGE_ROWS-tall window.
func _window_start(total: int, cursor: int) -> int:
	if total <= MENU_PAGE_ROWS:
		return 0
	return clampi(cursor - int(MENU_PAGE_ROWS * 0.5), 0, total - MENU_PAGE_ROWS)

## Compact number text: 1.1, 0.003, 12
func _fmt(v: float) -> String:
	var s: String = "%.5f" % v
	return s.rstrip("0").rstrip(".")


# =========================================================================
# TIER 2 -- FORMULAS (+ GLOBALS + RESET)
# =========================================================================
func open_formula_select_menu() -> void:
	is_menu_open = true
	active_menu_kind = MenuKind.NONE # Disconnected from legacy toolbar tracking loops safely
	_ensure_cyan_panel()
	redraw_formula_select_menu()

func redraw_formula_select_menu() -> void:
	if not is_instance_valid(menu_list_box): return
	for child in menu_list_box.get_children(): child.queue_free()

	var label_title = Label.new()
	label_title.text = " 🕹️ SELECT MATH RECIPE CARD "
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.CHARTREUSE)
	menu_list_box.add_child(label_title)

	var rows: Array = get_formula_rows()
	var cursor: int = control_panel.last_tier2_index
	var start: int = _window_start(rows.size(), cursor)
	var stop: int = mini(start + MENU_PAGE_ROWS, rows.size())
	var scrolling: bool = rows.size() > MENU_PAGE_ROWS

	if scrolling: _add_scroll_hint(start > 0, "▲")
	for i in range(start, stop):
		var row: Dictionary = rows[i]
		var text: String = row["label"]
		var hl: Color = Color.YELLOW
		var dim: Color = Color.DARK_GRAY
		if row["kind"] == "reset":
			hl = Color.WHITE
			dim = Color.LIGHT_GOLDENROD
		elif row["kind"] == "recipe":
			text = ("● " if row["active"] else "○ ") + text
		_add_menu_row(text, i == cursor, hl, dim)
	if scrolling: _add_scroll_hint(stop < rows.size(), "▼")

func _step_formula_selection(direction: int) -> void:
	var total: int = get_formula_rows().size()
	control_panel.last_tier2_index = posmod(control_panel.last_tier2_index + direction, total)
	redraw_formula_select_menu()


# =========================================================================
# TIER 3 -- UNIFORMS (a formula's own list, or GLOBALS)
# =========================================================================
func open_fast_travel_menu() -> void:
	is_menu_open = true
	active_menu_kind = MenuKind.SHADER_MENU
	_ensure_cyan_panel()
	redraw_fast_travel_menu()

func _step_fast_travel_selection(direction: int) -> void:
	if control_panel.parsed_uniforms.is_empty(): return
	var total: int = control_panel.parsed_uniforms.size() + 1
	control_panel.last_tier3_index = posmod(control_panel.last_tier3_index + direction, total)
	redraw_fast_travel_menu()

func redraw_fast_travel_menu() -> void:
	if not is_instance_valid(menu_list_box): return
	for child in menu_list_box.get_children(): child.queue_free()

	var is_globals: bool = control_panel.active_recipe_id == ""

	# Re-filter by the CURRENT style every time this redraws (not just on first entry), so backing out
	# of Tier 4/5 after changing a style selector immediately shows that style's own uniform list.
	var p: int = active_shader_layer
	if is_globals:
		control_panel.parsed_uniforms = library.global_uniforms(pass_records[p])
	else:
		control_panel.parsed_uniforms = library.visible_uniforms(pass_records[p], control_panel.active_recipe_id, pass_values[p])
	var uniforms_list: Array = control_panel.parsed_uniforms
	control_panel.last_tier3_index = clampi(control_panel.last_tier3_index, 0, uniforms_list.size())

	var label_title = Label.new()
	label_title.text = " ⚙ GLOBAL UNIFORMS " if is_globals else " 🕹️ PARAMETER UNIFORMS LIST "
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.CYAN)
	menu_list_box.add_child(label_title)

	if uniforms_list.is_empty():
		var lbl_empty = Label.new()
		lbl_empty.text = "    [ NO GLOBAL UNIFORMS IN THIS PASS YET ]    "
		lbl_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl_empty.add_theme_color_override("font_color", Color.DARK_GRAY)
		menu_list_box.add_child(lbl_empty)
		return

	var total_rows: int = uniforms_list.size() + 1
	var cursor: int = control_panel.last_tier3_index
	var start: int = _window_start(total_rows, cursor)
	var stop: int = mini(start + MENU_PAGE_ROWS, total_rows)
	var scrolling: bool = total_rows > MENU_PAGE_ROWS

	if scrolling: _add_scroll_hint(start > 0, "▲")
	for i in range(start, stop):
		if i == 0:
			_add_menu_row(_tier3_row0_label(), i == cursor, Color.WHITE, Color.LIGHT_GOLDENROD)
		else:
			var row_rec: Dictionary = uniforms_list[i - 1]
			var row_text: String = String(row_rec["label"]).to_upper()
			if row_rec["is_style"]:
				row_text = "★ " + row_text + "★ "# the style selector stands out from its own group's controls
			_add_menu_row(row_text, i == cursor)
	if scrolling: _add_scroll_hint(stop < total_rows, "▼")

# =========================================================================
# TIER 4 -- PARAMETERS (channels) OF ONE UNIFORM
# =========================================================================
func open_parameter_select_menu() -> void:
	if not is_instance_valid(menu_list_box): return
	for child in menu_list_box.get_children(): child.queue_free()

	var uniforms_list: Array = control_panel.parsed_uniforms
	if uniforms_list.is_empty(): return
	var rec: Dictionary = uniforms_list[control_panel.active_index]

	var label_title = Label.new()
	label_title.text = " 🕹️ %s: SELECT PARAMETER " % String(rec["label"]).to_upper()
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.MAGENTA)
	menu_list_box.add_child(label_title)

	var channel_names: PackedStringArray = rec["channels"]
	var current: Variant = control_panel.uniform_values.get(rec["name"], rec["default"])
	for i in range(channel_names.size()):
		var value_text: String = _fmt(library.get_component(current, rec["type"], i))
		_add_menu_row("%s   [ %s ]" % [channel_names[i], value_text], i == control_panel.last_tier4_index)


# =========================================================================
# TIER 5 -- TWEAK CONSOLE (value, sensitivity, default, recommended sensitivity)
# =========================================================================
func open_live_tweak_console() -> void:
	if not is_instance_valid(menu_list_box): return
	for child in menu_list_box.get_children(): child.queue_free()

	var uniforms_list: Array = control_panel.parsed_uniforms
	if uniforms_list.is_empty(): return

	var rec: Dictionary = uniforms_list[control_panel.active_index]
	var channel_names: PackedStringArray = rec["channels"]
	var idx: int = clampi(control_panel.last_tier4_index, 0, channel_names.size() - 1)
	var raw_val: Variant = control_panel.uniform_values.get(rec["name"], rec["default"])
	var display_value: float = library.get_component(raw_val, rec["type"], idx)
	var is_bool: bool = rec["type"] == "bool"

	var label_title = Label.new()
	label_title.text = " +═ PARAMETER TWEAK CONSOLE ═+ "
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_title.add_theme_color_override("font_color", Color.ORANGE)
	menu_list_box.add_child(label_title)

	var name_text: String = String(rec["label"]).to_upper()
	if channel_names.size() > 1:
		name_text += "  ·  " + channel_names[idx]
	var lbl_name = Label.new()
	lbl_name.text = " ║ NAME: %s " % name_text
	lbl_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_list_box.add_child(lbl_name)

	var value_text: String = ("ON" if display_value > 0.5 else "OFF") if is_bool else _fmt(display_value)
	var lbl_val = Label.new()
	if control_panel.last_tier5_row == 0:
		lbl_val.text = " ▶ ║ VALUE: ◄ [ %s ] ► " % value_text
		lbl_val.add_theme_color_override("font_color", Color.YELLOW)
	else:
		lbl_val.text = "    ║ VALUE:   [ %s ]   " % value_text
		lbl_val.add_theme_color_override("font_color", Color.DARK_GRAY)
	lbl_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_list_box.add_child(lbl_val)

	var lbl_sens = Label.new()
	var sens_text: String = "N/A (TOGGLE)" if is_bool else _fmt(control_panel.sensitivity)
	if control_panel.last_tier5_row == 1:
		lbl_sens.text = " ▶ ║ SENS : ◄ [ %s ] ► " % sens_text
		lbl_sens.add_theme_color_override("font_color", Color.YELLOW)
	else:
		lbl_sens.text = "    ║ SENS :   [ %s ]   " % sens_text
		lbl_sens.add_theme_color_override("font_color", Color.DARK_GRAY)
	lbl_sens.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_list_box.add_child(lbl_sens)

	var blank_spacer = Label.new()
	blank_spacer.text = " ║                            ║ "
	blank_spacer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	blank_spacer.add_theme_color_override("font_color", Color.DARK_GRAY)
	menu_list_box.add_child(blank_spacer)

	var default_text: String = ("ON" if library.default_component(rec, idx) > 0.5 else "OFF") if is_bool else _fmt(library.default_component(rec, idx))
	var lbl_def_val = Label.new()
	lbl_def_val.text = " ║ DEFAULT VAL : [ %s ]   ║ " % default_text
	lbl_def_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_def_val.add_theme_color_override("font_color", Color.DIM_GRAY)
	menu_list_box.add_child(lbl_def_val)

	var lbl_rec_sens = Label.new()
	lbl_rec_sens.text = " ║ RECOMMENDED SENS: [ %s ]   ║ " % ("--" if is_bool else _fmt(rec["sens"]))
	lbl_rec_sens.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_rec_sens.add_theme_color_override("font_color", Color.DIM_GRAY)
	menu_list_box.add_child(lbl_rec_sens)

	var label_footer = Label.new()
	label_footer.text = " +════════════════════════════+ "
	label_footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_footer.add_theme_color_override("font_color", Color.ORANGE)
	menu_list_box.add_child(label_footer)

func _process(delta: float) -> void:
	current_time += delta
	if current_time > 7200.0: current_time = 0.0 # Prevents floating-point precision loss
	
	# Keep all three simulation layers running on the exact same temporal clock ticking rate
	if pass1_material and pass1_material.shader:
		pass1_material.set_shader_parameter("u_time", current_time)
	if pass2_material and pass2_material.shader:
		pass2_material.set_shader_parameter("u_time", current_time)
	if pass3_material and pass3_material.shader:
		pass3_material.set_shader_parameter("u_time", current_time)
		
	# Execute hardware diagnostic checks every processing frame
	_check_hardware_gpu_safety()
	
	
func _check_hardware_gpu_safety() -> void:
	var current_vram_mb = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1024.0 / 1024.0
	var current_fps = Engine.get_frames_per_second()

	perf_bar.visible = control_panel != null and control_panel.active_state != control_panel.ControlState.HIDDEN and not menu_peek_hidden

	if label_perf_monitor:
		label_perf_monitor.text = " FPS: %d  |  VRAM: %.1f MB   " % [current_fps, current_vram_mb]
		if current_fps > 55: label_perf_monitor.add_theme_color_override("font_color", Color.GREEN)
		elif current_fps > 30: label_perf_monitor.add_theme_color_override("font_color", Color.YELLOW)
		else: label_perf_monitor.add_theme_color_override("font_color", Color.RED)

	
	# 3. Mobile Breaker Trip Point
	var vram_safety_trip_point = 1000.0 # 1GB Limit

	if current_vram_mb > vram_safety_trip_point or current_fps < 30.0:
		# The library prefixes formula uniforms as u_<recipe>_<name>
		var detail_key: String = "u_fbm_noise_detail"
		if pass_stack[0].has("fbm") and pass_values[0].has(detail_key):
			var active_detail: float = float(pass_values[0][detail_key])
			if active_detail > 2.0:
				pass_values[0][detail_key] = 2.0
				pass1_material.set_shader_parameter(detail_key, 2.0)
				control_panel.update_status_readout()

				label_safety_alert.text = "⚠️ VRAM/PERFORMANCE OVERLOAD PREVENTED: CLAMPING NOISE DETAIL"
				get_tree().create_timer(4.0).timeout.connect(func(): label_safety_alert.text = "")


func _on_ui_uniform_modified(u_name: String, u_value: Variant) -> void:
	# Route the change to the pass that is currently selected and remember it in that pass's cache
	var mat: ShaderMaterial = _pass_material(active_shader_layer)
	if mat:
		mat.set_shader_parameter(u_name, u_value)
	pass_values[active_shader_layer][u_name] = u_value

	# Cache the modified parameter into your current active preset resource for exports
	current_preset.uniform_values[u_name] = u_value


func save_current_pattern_preset() -> void:
	var active_mat: ShaderMaterial = pass1_material if active_shader_layer == 0 else pass2_material
	if not active_mat or not active_mat.shader: return
	
	var layer_label: String = "PASS 1 (PATTERN GENERATOR)" if active_shader_layer == 0 else "PASS 2 (ANIMATION EFFECTS)"
	var output = "// 🕹️ HANDHELD SHADER CONSOLE EXPORT DATA\n// TARGET LAYER: %s\n\n" % layer_label
	
	var active_params = []
	var params = active_mat.shader.get_shader_uniform_list()
	
	for p in params:
		if p.name == "u_time" or p.name == "u_pattern_texture": continue
		var val = active_mat.get_shader_parameter(p.name)
		if val == null: continue
		active_params.append(p.name)
		
		# --- CLEAN FORMATTING HOOKS ---
		if p.type == TYPE_FLOAT:
			output += "mat.set_shader_parameter('%s', %.3f);\n" % [p.name, val]
		elif p.type == TYPE_VECTOR2:
			output += "mat.set_shader_parameter('%s', vec2(%.3f, %.3f));\n" % [p.name, val.x, val.y]
		elif p.type == TYPE_COLOR:
			output += "mat.set_shader_parameter('%s', Color(%.2f, %.2f, %.2f, %.2f));\n" % [p.name, val.r, val.g, val.b, val.a]
			
	# --- UNTANGLED SYSTEM CLIPBOARD REGISTRATION ---
	output += "\n// --- SOURCE GLSL SHADER CODE CONTEXT ---\n" + active_mat.shader.code
	DisplayServer.clipboard_set(output)
	control_panel.label_status.text = " ✅ COPIED %d PARAMETERS FROM %s TO CLIPBOARD! " % [active_params.size(), layer_label]

func load_default_test_shaders() -> void:
	# Boot: build all three passes from the recipe library. Pass 1 starts on the FBM pattern;
	# Passes 2 and 3 start empty (clear-glass bypass) until a formula is chosen in Tier 2.
	library = load("res://ShaderLibrary.gd").new()
	#if DEBUG_DUMMY_RECIPES > 0:
		#library.add_dummy_recipes(DEBUG_DUMMY_RECIPES)

	pass_stack = [["fbm_master"], [""], []]
	for p in range(3):
		rebuild_pass(p)

	control_panel.uniform_values = pass_values[active_shader_layer]
	
## Live-updates one of pass 1's global camera uniforms (pan/zoom/rotation) and mirrors it into
## pass_values[0], so it's captured correctly if a preset gets saved mid-exploration. Used by the
## mouse/touch pattern-camera controls.
func set_pattern_global(u_name: String, value) -> void:
	pass_values[0][u_name] = value
	if pass1_material and pass1_material.shader:
		pass1_material.set_shader_parameter(u_name, value)

func get_pattern_global(u_name: String, fallback):
	return pass_values[0].get(u_name, fallback)
	
