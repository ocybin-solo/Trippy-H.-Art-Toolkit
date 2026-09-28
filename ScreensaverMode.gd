extends Node
## ScreensaverMode.gd -- "Screensaver Mode" (System Main Menu > START SCREENSAVER)
##
## Runs on its own with no input: it picks a random saved animation preset, holds on it -- for however
## long THAT PRESET's own hold time says (set when it was saved), or TransitionLab.hold_seconds if it
## predates that option -- then picks a random saved TRANSITION preset (from TransitionLab / "Screensaver
## Dev") and uses it to transition to
## another random animation preset, repeating forever. A tap anywhere on screen stops it and restores
## whatever was on screen before it started.
##
## Needs at least 2 saved animation presets and at least 1 saved transition preset; START SCREENSAVER
## shows a message and does nothing if there aren't enough of either yet.

var main         # MainManager
var owner_menu   # OptionsMenu (for .presets and .lab)

var running: bool = false
var _stop_layer: CanvasLayer


var _snapshot_stack: Array = []
var _snapshot_values: Array = []
var _current_file: String = ""
var _current_hold: float = 6.0 # the on-screen preset's own hold time (falls back to FALLBACK_HOLD_SECONDS)
var _hold_timer: SceneTreeTimer = null
const FALLBACK_HOLD_SECONDS: float = 6.0 # only used by a preset saved before per-preset hold times existed
const INTERACT_GRACE: float = 8.0 # seconds the show holds after your last pan/zoom/rotate

var _stop_catcher: Control



func setup(main_manager, owner_options: Object) -> void:
	main = main_manager
	owner_menu = owner_options

	# A full-screen catcher on its own high CanvasLayer, above the display, the controls and every menu,
	# so nothing underneath (grid buttons included) can be pressed mid-run. It doesn't stop on any
	# touch anymore: it hands everything to the pattern camera, which pans/zooms/rotates for drags,
	# pinches and the wheel, and only calls stop() for a still tap or click.
	_stop_layer = CanvasLayer.new()
	_stop_layer.layer = 10
	main.add_child(_stop_layer)
	_stop_catcher = Control.new()
	_stop_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_stop_layer.add_child(_stop_catcher)
	_stop_catcher.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stop_catcher.gui_input.connect(_on_stop_layer_input)
	_stop_layer.visible = false

func _on_stop_layer_input(event: InputEvent) -> void:
	owner_menu.layout.feed_camera_input(event)

## Called by the camera whenever you pan/zoom/rotate during a run, so the show doesn't yank the
## preset away mid-exploration. Re-arms the hold timer to at least INTERACT_GRACE seconds.
func note_interaction() -> void:
	if not running or _hold_timer == null or not is_instance_valid(_hold_timer):
		return
	if _hold_timer.time_left > INTERACT_GRACE - 1.0:
		return # plenty of time left; only re-arm about once a second
	if _hold_timer.timeout.is_connected(_advance):
		_hold_timer.timeout.disconnect(_advance)
	_hold_timer = main.get_tree().create_timer(INTERACT_GRACE)
	_hold_timer.timeout.connect(_advance)


# =========================================================================
# START / STOP
# =========================================================================
func can_start() -> bool:
	return owner_menu.presets._scan().size() >= 2 and not owner_menu.lab._scan_transition_presets().is_empty()

## Called from the main menu. Returns a short reason it couldn't start, or "" if it did.
func start() -> String:
	if running:
		return ""
	if owner_menu.presets._scan().size() < 2:
		return "NEED AT LEAST 2 SAVED PRESETS"
	if owner_menu.lab._scan_transition_presets().is_empty():
		return "SAVE A TRANSITION FIRST (SCREENSAVER DEV)"
	if owner_menu.lab.dev_mode:
		owner_menu.toggle_dev_mode() # the two modes both drive the effect layer; only one runs at a time

	running = true
	_snapshot_stack = main.pass_stack.duplicate(true)
	_snapshot_values = main.pass_values.duplicate(true)
	_current_file = ""
	if not owner_menu.lab.transition_finished.is_connected(_on_transition_finished):
		owner_menu.lab.transition_finished.connect(_on_transition_finished)
	if OS.has_feature("mobile"):
		DisplayServer.screen_set_keep_on(true)
	_stop_layer.visible = true
	_advance()
	return ""

func stop() -> void:
	if not running:
		return
	running = false
	_stop_layer.visible = false
	if OS.has_feature("mobile"):
		DisplayServer.screen_set_keep_on(false)
	if _hold_timer != null and is_instance_valid(_hold_timer) and _hold_timer.timeout.is_connected(_advance):
		_hold_timer.timeout.disconnect(_advance)
	_hold_timer = null
	if owner_menu.lab.transition_finished.is_connected(_on_transition_finished):
		owner_menu.lab.transition_finished.disconnect(_on_transition_finished)
	if owner_menu.lab.running:
		owner_menu.lab._abort()

	# Put back whatever was showing before the screensaver started
	for p in range(3):
		main.pass_stack[p] = _snapshot_stack[p].duplicate()
		main.pass_values[p].clear() # in place, so the menu's link to it stays valid
		main.pass_values[p].merge(_snapshot_values[p])
		main.rebuild_pass(p)


# =========================================================================
# THE LOOP
# =========================================================================
func _on_transition_finished() -> void:
	if not running:
		return
	_hold_timer = main.get_tree().create_timer(_current_hold)
	_hold_timer.timeout.connect(_advance)

## Picks a random next preset (never the one on screen now) and a random transition to reach it.
func _advance() -> void:
	if not running:
		return
	_hold_timer = null # this timer just fired; note_interaction() must not try to extend it
	var entries: Array = owner_menu.presets._scan()
	if entries.size() < 2:
		stop()
		return
	var pool: Array = entries.filter(func(e): return e["file"] != _current_file)
	if pool.is_empty():
		pool = entries
	var target: Dictionary = pool[randi() % pool.size()]
	# -1 means the preset predates the per-preset hold-time feature -- every preset saved by the
	# current save flow always has its own duration_sec, so this only matters for a very old file, if any remain
	var target_hold: float = float(target.get("duration_sec", -1.0))
	_current_hold = target_hold if target_hold > 0.0 else FALLBACK_HOLD_SECONDS

	var transitions: Array = owner_menu.lab._scan_transition_presets()
	if transitions.is_empty():
		stop()
		return
	owner_menu.lab._load_transition_preset(transitions[randi() % transitions.size()])

	if _current_file == "":
		# Nothing on screen yet from this run: show the first preset directly, then start the loop
		owner_menu.presets._load_preset(target)
		_current_file = target["file"]
		_on_transition_finished()
	else:
		_current_file = target["file"]
		owner_menu.lab.run_transition_to(target)
