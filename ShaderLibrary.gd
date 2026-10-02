extends RefCounted
## ShaderLibrary.gd -- T.H.A.T. recipe registry + per-pass shader assembler (first-build skeleton)
##
## TAG FORMAT: a comment after a uniform line, fields separated by |
##   uniform float u_segments = 6.0; // @label Slides | @min 1 | @max 32 | @sens 1
##   @label    text shown in the menus
##   @min/@max allowed range (used for clamping and to derive a fallback sensitivity)
##   @sens     recommended sensitivity (Tier 5 "recommended" row) -- ignored for bool, which just toggles
##   @channels comma list overriding the default channel names (X,Y / X,Y,Z / R,G,B,A)
##   @global   shared by the whole pass: declared once, value survives formula changes
##   @style N  (int uniform only) this uniform only shows in the menu when the recipe's @is_style
##             uniform currently equals N. Comma-separate several: "@style 0,2". No @style tag = always shown.
##   @is_style marks an int uniform as the one Tier 3 reads to decide which @style N group is visible.
##             One per recipe; give it real names via @label, e.g. "0=Ramp,1=Cosine,2=Chrono,3=Cyber".
##	 @raw      If a shader parameter is vec4 for some reason and IS NOT a color, then use this tag at the end
##
## RECIPE CONVENTIONS (function must be named fx_<id>; helper functions should start with <id>_):
##   Pass 1 (pattern):  vec4 fx_<id>(vec2 uv)   single-select
##   Pass 2 (warp):     vec2 fx_<id>(vec2 uv)   stackable, chained in the order added
##   Pass 3 (filter):   vec4 fx_<id>(vec2 uv)   single-select for now, may sample u_warped_texture
## Recipes may read u_time. Never declare samplers or u_time; the assembler adds them.
## Supported uniform types: float, int, bool, vec2, vec3, vec4 (vec4, IF NOT a color needs to use the @raw tag). int and
## bool are REAL GLSL int/bool uniforms in the assembled shader -- write "int mode = ..." directly
## in your recipe's function body and compare it against real integers; no more float-into-int hacks
## like int(floor(u_render_mode + 0.05)).

const PASS_PATTERN: int = 0
const PASS_WARP: int = 1
const PASS_FILTER: int = 2
## One fixed 1-5 ladder shared by every uniform's tweak console, from very fine to coarse.
const SENS_STEPS: Array = [0.000001, 0.000005, 0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005,
		0.01, 0.05, 0.1, 0.5, 1.0, 5.0]

# id -> recipe dictionary. Insertion order is the menu order.
var recipes: Dictionary = {}

var _re_uniform: RegEx


func _init() -> void:
	_re_uniform = RegEx.new()
	# groups: 1 type, 2 name, 3 hint (e.g. source_color), 4 default literal, 5 comment tags
	_re_uniform.compile("^\\s*uniform\\s+(float|int|bool|vec2|vec3|vec4)\\s+(\\w+)\\s*(?::\\s*([^=;]+?))?\\s*=\\s*([^;]+);\\s*(?://(.*))?$")
	_register_builtin_recipes()


# =========================================================================
# REGISTRY
# =========================================================================
func _register(id: String, pass_index: int, display_name: String, source: String, stackable: bool) -> void:
	recipes[id] = {
		"id": id,
		"pass": pass_index,
		"name": display_name,
		"source": source,
		"stackable": stackable,
	}

## Recipes for one pass, in menu order (Tier 2 rows).
func recipes_for_pass(pass_index: int) -> Array:
	var out: Array = []
	for id in recipes:
		if recipes[id]["pass"] == pass_index:
			out.append(recipes[id])
	return out

func is_stackable(id: String) -> bool:
	return recipes.has(id) and recipes[id]["stackable"]

## Debug helper for testing long-list scrolling: adds N harmless Pass 2 recipes.
func add_dummy_recipes(count: int) -> void:
	for i in range(count):
		var id: String = "dummy_%02d" % (i + 1)
		var src: String = "uniform float u_amount = 0.5; // @label Amount | @min 0 | @max 1 | @sens 0.05\n"
		src += "vec2 fx_%s(vec2 uv) {\n" % id
		src += "\treturn uv + vec2(sin(uv.y * 10.0 + u_time), 0.0) * u_amount * 0.02;\n"
		src += "}\n"
		_register(id, PASS_WARP, "TEST FORMULA %02d" % (i + 1), src, true)


# =========================================================================
# ASSEMBLER: active recipe ids (in stacking order) -> one shader for the pass
# Returns {"code": String, "uniforms": Array of uniform records}
# =========================================================================
func assemble_pass(pass_index: int, active_ids: Array) -> Dictionary:
	var decl_lines: PackedStringArray = PackedStringArray()
	var func_blocks: PackedStringArray = PackedStringArray()
	var records: Array = []
	var seen_globals: Dictionary = {}
	var used_ids: Array = []

	# 1) pass-level globals that belong to the pass itself (always present)
	for line in _template_globals(pass_index).split("\n"):
		var trec: Dictionary = _parse_uniform_line(line, "")
		if trec.is_empty():
			continue
		trec["is_global"] = true
		seen_globals[trec["base_name"]] = true
		records.append(trec)
		decl_lines.append(_decl_line(trec))

	# 2) active recipes, in the order they were added
	for id in active_ids:
		if not recipes.has(id):
			continue
		used_ids.append(id)
		var renames: Dictionary = {}
		var body: PackedStringArray = PackedStringArray()
		for line in String(recipes[id]["source"]).split("\n"):
			var rec: Dictionary = _parse_uniform_line(line, id)
			if rec.is_empty():
				body.append(line)
				continue
			if rec["is_global"]:
				if seen_globals.has(rec["base_name"]):
					continue # already declared for this pass; share that one
				seen_globals[rec["base_name"]] = true
			else:
				# formula-specific: prefix with the recipe id so stacked formulas never collide
				rec["name"] = "u_%s_%s" % [id, String(rec["base_name"]).trim_prefix("u_")]
				renames[rec["base_name"]] = rec["name"]
			records.append(rec)
			decl_lines.append(_decl_line(rec))
		var body_text: String = "\n".join(body)
		for base in renames:
			body_text = _rename_word(body_text, base, renames[base])
		func_blocks.append(body_text)

	var code: String = "shader_type canvas_item;\n"
	code += _pass_header(pass_index) + "\n"
	code += "\n".join(decl_lines) + "\n\n"
	code += "\n".join(func_blocks) + "\n\n"
	code += _pass_fragment(pass_index, used_ids)
	return {"code": code, "uniforms": records}


func _pass_header(pass_index: int) -> String:
	match pass_index:
		PASS_PATTERN:
			return "uniform float u_time;"
		PASS_WARP:
			return "uniform sampler2D u_pattern_texture : filter_linear;\nuniform float u_time;"
	return "uniform sampler2D u_warped_texture : filter_linear;\nuniform float u_time;"


# Uniforms owned by the pass itself (shown under Tier 2 > GLOBALS). Tag format as above.
func _template_globals(pass_index: int) -> String:
	match pass_index:
		PASS_PATTERN:
			var g1: String = "uniform float u_global_zoom = 1.0; // @label Master Pattern Scale | @min 0.0001 | @max 100.0 | @sens 0.05 | @global\n"
			g1 += "uniform vec2 u_global_offset = vec2(0.0, 0.0); // @label Master Pan | @min -40.0 | @max 40.0 | @sens 0.01 | @global\n"
			g1 += "uniform float u_rotation_speed = 0.0; // @label Rotation Speed | @min -2 | @max 2 | @sens 0.05 | @global\n"
			g1 += "uniform float u_master_rotation = 0.0; // @label Master Canvas Spin | @min -3.1416 | @max 3.1416 | @sens 0.05 | @global\n"
			return g1
		PASS_WARP:
			var g2: String = "uniform float u_warp_master_mix = 1.0; // @label Warp Dry/Wet Mix | @min 0.0 | @max 1.0 | @sens 0.01 | @global\n"
			g2 += "uniform float u_global_speed_mod = 1.0; // @label ?? Does nothing ?? | @min 0.0 | @max 3.0 | @sens 0.05 | @global\n"
			g2 += "uniform float u_rotation_speed = 0.0; // @label Rotation Effects | @min -2 | @max 2 | @sens 0.05 | @global\n"
			return g2
		PASS_FILTER:
			var g3: String = "uniform float u_master_brightness = 1.0; // @label Master Brightness | @min 0.5 | @max 2.0 | @sens 0.02 | @global\n"
			g3 += "uniform float u_master_saturation = 1.0; // @label Master Saturation | @min 0.0 | @max 2.0 | @sens 0.02 | @global\n"
			g3 += "uniform float u_master_rotation = 0.0; // @label Master Canvas Spin | @min -3.1416 | @max 3.1416 | @sens 0.05 | @global\n"
			return g3
	return ""

func _pass_fragment(pass_index: int, ids: Array) -> String:
	var f: String = ""
	match pass_index:
		PASS_PATTERN:
			f += "void fragment() {\n"
			f += "\tfloat ang = u_time * u_rotation_speed + u_master_rotation;\n"
			f += "\t// Apply universal Pan and Zoom globals to space first\n"
			f += "\tvec2 uv = (UV - 0.5) * u_global_zoom + u_global_offset;\n"
			#f += "\tfloat ang = u_time * u_rotation_speed;\n"
			f += "\tuv = vec2(cos(ang) * uv.x - sin(ang) * uv.y, sin(ang) * uv.x + cos(ang) * uv.y) + 0.5;\n"
			if ids.is_empty():
				f += "\tCOLOR = vec4(0.0, 0.0, 0.0, 1.0);\n"
			else:
				f += "\tCOLOR = fx_%s(uv);\n" % ids[0]
			f += "}\n"
			
		PASS_WARP:
			f += "vec2 tatool_mirror(vec2 x) {\n"
			f += "\treturn abs(mod(x + 1.0, 2.0) - 1.0);\n"
			f += "}\n\n"
			f += "void fragment() {\n"
			f += "\tvec2 original_uv = UV;\n"
			f += "\tvec2 uv = UV;\n"
			for id in ids:
				f += "\tuv = fx_%s(uv);\n" % id
			f += "\t// Globally blend between unwarped and warped space based on Dry/Wet knob\n"
			f += "\tvec2 final_uv = mix(original_uv, uv, u_warp_master_mix);\n"
			f += "\tCOLOR = texture(u_pattern_texture, tatool_mirror(final_uv));\n"
			f += "}\n"
			
		PASS_FILTER, _:
			f += "void fragment() {\n"
			f += "\t// Universal Master Rotation for the entire incoming viewport\n"
			f += "\tvec2 rotated_uv = UV - 0.5;\n"
			f += "\tfloat master_ang = u_master_rotation;\n"
			f += "\trotated_uv = vec2(cos(master_ang) * rotated_uv.x - sin(master_ang) * rotated_uv.y, sin(master_ang) * rotated_uv.x + cos(master_ang) * rotated_uv.y) + 0.5;\n"
			f += "\t\n"
			f += "\tvec4 scene_color;\n"
			if ids.is_empty():
				f += "\tscene_color = texture(u_warped_texture, rotated_uv);\n"
			else:
				f += "\tscene_color = fx_%s(rotated_uv);\n" % ids
			
			f += "\t// Apply Master Brightness Global override\n"
			f += "\tscene_color.rgb *= u_master_brightness;\n"
			f += "\t\n"
			f += "\t// Calculate grayscale luminance for Saturation Global blend\n"
			f += "\tfloat luma = dot(scene_color.rgb, vec3(0.299, 0.587, 0.114));\n"
			f += "\tscene_color.rgb = mix(vec3(luma), scene_color.rgb, u_master_saturation);\n"
			f += "\t\n"
			f += "\tCOLOR = scene_color;\n"
			f += "}\n"
			
	return f



func _rename_word(text: String, from_name: String, to_name: String) -> String:
	var re: RegEx = RegEx.new()
	re.compile("\\b%s\\b" % from_name)
	return re.sub(text, to_name, true)


func _decl_line(rec: Dictionary) -> String:
	var hint: String = ""
	if rec["hint"] != "":
		hint = " : %s" % rec["hint"]
	var literal: String = rec["literal"]
	if rec["type"] == "int":
		literal = str(int(round(float(rec["default"]))))
	elif rec["type"] == "bool":
		literal = "true" if bool(rec["default"]) else "false"
	return "uniform %s %s%s = %s;" % [rec["type"], rec["name"], hint, literal]


# =========================================================================
# PARSER: one uniform line -> uniform record (empty Dictionary if not a uniform line)
# =========================================================================
func _parse_uniform_line(line: String, recipe_id: String) -> Dictionary:
	var m: RegExMatch = _re_uniform.search(line)
	if m == null:
		return {}
	var type: String = m.get_string(1)
	var base: String = m.get_string(2)
	var literal: String = m.get_string(4).strip_edges()
	var tags: Dictionary = _parse_tags(m.get_string(5))

	var mn: float = float(tags["min"]) if tags.has("min") else -INF
	var mx: float = float(tags["max"]) if tags.has("max") else INF
	var sens: float = 0.01
	if tags.has("sens"):
		sens = float(tags["sens"])
	elif not is_inf(mn) and not is_inf(mx):
		sens = (mx - mn) / 100.0

	var is_color: bool = type == "vec4" and not tags.has("raw")

	var channels: PackedStringArray = PackedStringArray(["VALUE"])
	if type == "vec2":
		channels = PackedStringArray(["X", "Y"])
	elif type == "vec3":
		channels = PackedStringArray(["X", "Y", "Z"])
	elif type == "vec4":
		channels = PackedStringArray(["R", "G", "B", "A"]) if is_color else PackedStringArray(["X", "Y", "Z", "W"])
	if tags.has("channels"):
		channels = PackedStringArray()
		for c in String(tags["channels"]).split(","):
			channels.append(c.strip_edges())

	return {
		"recipe": recipe_id,
		"base_name": base,
		"name": base,
		"type": type,
		"hint": m.get_string(3).strip_edges(),
		"literal": literal,
		"default": _parse_literal(type, literal),
		"label": str(tags.get("label", base.trim_prefix("u_").replace("_", " ").capitalize())),
		"min": mn,
		"max": mx,
		"sens": sens,
		"channels": channels,
		"is_global": tags.has("global"),
		"is_style": tags.has("is_style"),
		"is_color": is_color,   # vec4 that opens the shared color picker instead of Tier 4/5
		"styles": _parse_styles(tags),
	}


## "@style 0,2" -> [0, 2]. No @style tag -> [] (always shown).
func _parse_styles(tags: Dictionary) -> Array:
	if not tags.has("style"):
		return []
	var out: Array = []
	for s in String(tags["style"]).split(","):
		if s.strip_edges().is_valid_int():
			out.append(int(s.strip_edges()))
	return out

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
	if type == "int":
		return int(round(float(t))) if t.is_valid_float() or t.is_valid_int() else 0
	if type == "bool":
		return t == "true"
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
	if type == "vec3":
		if nums.size() == 1:
			for _i in range(2): nums.append(nums[0])
		while nums.size() < 3:
			nums.append(0.0)
		return Vector3(nums[0], nums[1], nums[2])
	if nums.size() == 1:
		return Color(nums[0], nums[0], nums[0], nums[0])
	while nums.size() < 4:
		nums.append(0.0 if nums.size() < 3 else 1.0)
	return Color(nums[0], nums[1], nums[2], nums[3])


# =========================================================================
# VALUE HELPERS (the menus and the tweak console read these)
# =========================================================================
## Number of Tier 4 parameters (channels) for a uniform. 1 means Tier 3 can jump straight to Tier 5.
func channel_count(rec: Dictionary) -> int:
	return rec["channels"].size()

func get_component(value: Variant, type: String, idx: int) -> float:
	match type:
		"vec2":
			var v2: Vector2 = value
			return v2[idx]
		"vec3":
			var v3: Vector3 = value
			return v3[idx]
		"vec4":
			var c4: Color = value
			return c4[idx]
		"bool":
			return 1.0 if bool(value) else 0.0
	return float(value)

func set_component(value: Variant, type: String, idx: int, v: float) -> Variant:
	match type:
		"vec2":
			var v2: Vector2 = value
			v2[idx] = v
			return v2
		"vec3":
			var v3: Vector3 = value
			v3[idx] = v
			return v3
		"vec4":
			var c4: Color = value
			c4[idx] = v
			return c4
		"int":
			return int(round(v))
		"bool":
			return v > 0.5 # a toggle should call this with 1.0/0.0; a stepped +/- also flips it either way
	return v

func clamp_component(rec: Dictionary, v: float) -> float:
	if rec["type"] == "bool":
		return 1.0 if v > 0.5 else 0.0
	return clampf(v, rec["min"], rec["max"])

## Default value of one channel (Tier 5 "default" row).
func default_component(rec: Dictionary, idx: int) -> float:
	return get_component(rec["default"], rec["type"], idx)

## The steps the tweak console can pick from for this uniform: the shared ladder above, plus the
## uniform's own recommended @sens slotted in as an extra rung if it isn't already one of them.
func sens_ladder(rec: Dictionary) -> Array:
	var ladder: Array = SENS_STEPS.duplicate()
	var s: float = float(rec["sens"])
	if s > 0.0:
		var found: bool = false
		for v in ladder:
			if absf(float(v) - s) <= s * 0.001:
				found = true
				break
		if not found:
			ladder.append(s)
			ladder.sort()
	return ladder
	
## Which rung is the recommended step, i.e. where the console starts on a uniform you haven't tuned.
func recommended_sens_index(rec: Dictionary) -> int:
	var ladder: Array = sens_ladder(rec)
	var s: float = float(rec["sens"])
	var best: int = 0
	var best_d: float = INF
	for i in range(ladder.size()):
		var d: float = absf(float(ladder[i]) - s)
		if d < best_d:
			best_d = d
			best = i
	return best

## Seed missing values with defaults and push everything into the material.
## Pass in the per-pass value cache (keyed by final uniform name).
func apply_values(mat: ShaderMaterial, records: Array, values: Dictionary) -> void:
	for rec in records:
		var n: String = rec["name"]
		if not values.has(n):
			values[n] = rec["default"]
		mat.set_shader_parameter(n, values[n])

## Put values back to defaults. recipe_id == "" resets everything (pass-level RESET);
## a recipe id resets only that formula (Tier 3 row 0). Call apply_values afterwards.
func reset_values(records: Array, values: Dictionary, recipe_id: String = "") -> void:
	for rec in records:
		if recipe_id != "" and rec["recipe"] != recipe_id:
			continue
		values[rec["name"]] = rec["default"]

## Tier 3 list for a formula.
func uniforms_for_recipe(records: Array, recipe_id: String) -> Array:
	var out: Array = []
	for rec in records:
		if rec["recipe"] == recipe_id and not rec["is_global"]:
			out.append(rec)
	return out

## Tier 3 list for the GLOBALS row.
func global_uniforms(records: Array) -> Array:
	var out: Array = []
	for rec in records:
		if rec["is_global"]:
			out.append(rec)
	return out

## Tier 3 list for a formula, but with any @style-gated uniform hidden unless it belongs to the
## formula's CURRENT style (read from its @is_style uniform in `values`). A formula with no
## @is_style uniform behaves exactly like uniforms_for_recipe() -- nothing is filtered out.
func visible_uniforms(records: Array, recipe_id: String, values: Dictionary) -> Array:
	var all: Array = uniforms_for_recipe(records, recipe_id)
	var style_val: int = _current_style(all, values)
	if style_val == -1:
		return all # no @is_style uniform in this recipe: nothing to filter
	var out: Array = []
	for rec in all:
		if rec["styles"].is_empty() or rec["styles"].has(style_val):
			out.append(rec)
	return out

## The current value of a recipe's @is_style uniform, or -1 if it does not have one.
func _current_style(recipe_uniforms: Array, values: Dictionary) -> int:
	for rec in recipe_uniforms:
		if rec["is_style"]:
			return int(values.get(rec["name"], rec["default"]))
	return -1



func _register_builtin_recipes() -> void:

	## PASS 1  (Patterns)

	_register("fbm_master", PASS_PATTERN, "FBM", SRC_FBM_MASTER, false)
	_register("cyber_veins", PASS_PATTERN, "GYROID", SRC_CYBER_VEINS, false)
	_register("plasma_master", PASS_PATTERN, "PLASMAS", SRC_PLASMA_MASTER, false)    
	_register("fractal_unfolding", PASS_PATTERN, "FRACTALS", SRC_FRACTAL_UNFOLDING, false)
	_register("truchet_master", PASS_PATTERN, "TRUCHETS", SRC_TRUCHET_MASTER, false)
	_register("spiro_master", PASS_PATTERN, "KALEIDOSCOPES", SRC_SPIRO_MASTER, false)
	#shaders I had some part in actually designing...
	_register("voronoi_chaos", PASS_PATTERN, "VORONOI", SRC_VORONOI_CHAOS, false)
	_register( "fluid_glitch", PASS_PATTERN, "UNSTABLE FLOW", SRC_FLUID_GLITCH, false)	
	_register("fluid_glitch_v2",PASS_PATTERN,"WEIRD ART PIECE",SRC_FLUID_GLITCH_V2, false)
	_register("golden_fabric", PASS_PATTERN, "FABRIC ORBS", SRC_GOLDEN_FABRIC, false)
	_register("constructed_star", PASS_PATTERN, "STAR GEOMETRY", SRC_CONSTRUCTED_STAR, false)
	_register("fractal_6d", PASS_PATTERN, "FRACTAL / 6D Z-C-X SPACE", SRC_FRACTAL_6D, false)
	_register("complex_log_lab", PASS_PATTERN, "MATH LAB / COMPLEX LOG", SRC_COMPLEX_LOG_LAB, false)
	_register("complex_tangent", PASS_PATTERN, "MATH LAB / COMPLEX TANGENT", SRC_COMPLEX_TANGENT, false)
	_register("complex_mobius", PASS_PATTERN, "MATH LAB / COMPLEX MOBIUS", SRC_COMPLEX_MOBIUS, false)
	_register("complex_power", PASS_PATTERN, "MATH LAB / COMPLEX POWER", SRC_COMPLEX_POWER_LAB, false)
	_register("complex_self_power", PASS_PATTERN, "MATH LAB / COMPLEX SELF-POWER", SRC_COMPLEX_SELF_POWER, false)
	_register("reciprocal_feedback", PASS_PATTERN, "MATH LAB / RECIPROCAL FEEDBACK", SRC_RECIPROCAL_FEEDBACK, false)
	_register("quaternion_lab", PASS_PATTERN, "MATH LAB / QUATERNION SPACE", SRC_QUATERNION_LAB, false)
	_register("quaternion_lab_2", PASS_PATTERN, "MATH LAB / QUAT ROTATION", SRC_QUATERNION_LAB_2, false)
	_register("octonion_g2", PASS_PATTERN, "MATH LAB / OCTONION / G2", SRC_OCTONION_G2_LAB, false)
	
	#######  PASS 2 ########### (Warp Modules) - This Pass alone lets you add more than one at a time!
	_register("kaleidoscope", PASS_WARP, "KALEIDO REFLECT", SRC_KALEIDOSCOPE, true)
	_register("swirl", PASS_WARP, "RADIAL SWIRL", SRC_SWIRL, true)
	_register("polar_map", PASS_WARP, "POLAR TUNNEL MAP", SRC_POLAR_MAP, true) 
	_register("chromatic_ripple", PASS_WARP, "RIPPLE LENS", SRC_CHROMATIC_RIPPLE, true)
	_register("droste_spiral", PASS_WARP, "DROSTE SPIRAL", SRC_DROSTE_SPIRAL, true) 
	_register("polar_kaleidoscope", PASS_WARP, "POLAR KALEIDO", SRC_POLAR_KALEIDOSCOPE, true)
	_register("field_shift", PASS_WARP, "VECTOR MELT", SRC_FIELD_SHIFT, true)
	_register("FISHEYE", PASS_WARP, "FISHEYE", SRC_FISHEYE, true)
	_register("mirror_tile", PASS_WARP, "MIRROR TILE", SRC_MIRROR_TILE, true)
	_register("folding_kaleidoscope", PASS_WARP, "FOLD KALEIDO", SRC_FOLDING_KALEIDOSCOPE, true) 
	_register( "string_pi", PASS_WARP, "STRING / PI / WARP", SRC_STRING_PI, true )
	_register("iterated_inversion", PASS_WARP, "ITERATED / INVERSION", SRC_ITERATED_INVERSION, true )
	_register("complex_inversion", PASS_WARP, "COMPLEX / INVERSION", SRC_COMPLEX_INVERSION, true )	
	_register("hyperbolic", PASS_WARP, "HYPERBOLIC / SINGULARITY", SRC_HYPERBOLIC, true )
	_register("tangent_fold", PASS_WARP, "TANGENT / FOLD", SRC_TANGENT_FOLD, true )
	_register("vector_field", PASS_WARP, "VECTOR FIELD / FLOW", SRC_VECTOR_FIELD, true )
	_register("log_spiral", PASS_WARP, "LOGARITHMIC / SPIRAL", SRC_LOG_SPIRAL, true )
	_register("mobius", PASS_WARP, "MOBIUS / COMPLEX MAP", SRC_MOBIUS, true )
	_register("power_warp", PASS_WARP, "POWER / RADIAL WARP", SRC_POWER_WARP, true )
	_register("exponential_warp", PASS_WARP, "EXPONENTIAL STRETCH", SRC_EXPONENTIAL_WARP,true)
	_register("chaotic_map", PASS_WARP, "ITERATIVE / CHAOTIC MAP", SRC_CHAOTIC_MAP, true )
	
	#########  Pass 3 ###########   - filters
	_register("edge_glow", PASS_FILTER, "ANALOG EDGE GLOW", SRC_EDGE_GLOW, false)
	_register("crt_screen", PASS_FILTER, "📺 CRT MONITOR SIMULATOR", SRC_CRT_SCREEN, false)
	_register("vhs_glitch", PASS_FILTER, "📼 VHS TAPE GLITCH", SRC_VHS_GLITCH, false)
	_register("pixel_crusher", PASS_FILTER, "🕹️ PIXELATION", SRC_PIXEL_CRUSHER, false)
	_register("vignette_blur", PASS_FILTER, "🎬 CINEMATIC VIGNETTE BLUR", SRC_VIGNETTE_BLUR, false)
	_register("god_rays", PASS_FILTER, "☀️ VOLUMETRIC LIGHT STREAKS", SRC_GOD_RAYS, false)
	_register("halftone_dots", PASS_FILTER, "🎨 HALFTONE DOT MATRIX", SRC_HALFTONE_DOTS, false)
	_register("ascii_art", PASS_FILTER, "📟 ASCII CHARACTER TERMINAL", SRC_ASCII_ART, false)
	_register("oil_painting", PASS_FILTER, "🖌️ OIL PAINTING CANVAS", SRC_OIL_PAINTING, false)
	_register("neon_blur", PASS_FILTER, "🔮 NEON GLOW BLUR", SRC_NEON_BLUR, false)
	_register("fxaa_filter", PASS_FILTER, "✨ FXAA ANTI-ALIASING LENS", SRC_FXAA_FILTER, false)


const SRC_OCTONION_G2_LAB: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.00001 | @max 150.0 | @sens 0.0001
uniform float u_pan_x = 0.0; // @label Pan X | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_pan_y = 0.0; // @label Pan Y | @min -100.0 | @max 100.0 | @sens 0.001

uniform float u_q3 = 0.0; // @label Q3 | @min -100.0 | @max 100.0 | @sens 0.0001
uniform float u_q4 = 0.0; // @label Q4 | @min -100.0 | @max 100.0 | @sens 0.0001
uniform float u_q5 = 0.0; // @label Q5 | @min -100.0 | @max 100.0 | @sens 0.0001
uniform float u_q6 = 0.0; // @label Q6 | @min -100.0 | @max 100.0 | @sens 0.0001
uniform float u_q7 = 0.0; // @label Q7 | @min -100.0 | @max 100.0 | @sens 0.0001

uniform float u_c0 = 0.0; // @label C Real | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c1 = 0.0; // @label C1 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c2 = 0.0; // @label C2 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c3 = 0.0; // @label C3 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c4 = 0.0; // @label C4 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c5 = 0.0; // @label C5 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c6 = 0.0; // @label C6 | @min -100.0 | @max 100.0 | @sens 0.001
uniform float u_c7 = 0.0; // @label C7 | @min -100.0 | @max 100.0 | @sens 0.001

uniform float u_g2_a = 0.0; // @label G2 A | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_b = 0.0; // @label G2 B | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_c = 0.0; // @label G2 C | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_d = 0.0; // @label G2 D | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_e = 0.0; // @label G2 E | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_f = 0.0; // @label G2 F | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_g = 0.0; // @label G2 G | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_h = 0.0; // @label G2 H | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_i = 0.0; // @label G2 I | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_j = 0.0; // @label G2 J | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_k = 0.0; // @label G2 K | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_l = 0.0; // @label G2 L | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_m = 0.0; // @label G2 M | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_n = 0.0; // @label G2 N | @min -20.0 | @max 20.0 | @sens 0.0001

uniform float u_g2_strength = 0.15; // @label G2 Strength | @min -20.0 | @max 20.0 | @sens 0.0001
uniform float u_g2_steps = 3.0; // @label G2 Steps | @min 1.0 | @max 12.0 | @sens 1.0
uniform float u_c_motion = 0.0; // @label C Motion | @min -10.0 | @max 10.0 | @sens 0.001
uniform float u_feedback = 1.250; // @label Feedback | @min 0.0 | @max 10.0 | @sens 0.001
uniform float u_strength = 4.0; // @label Equation Strength | @min -10.0 | @max 10.0 | @sens 0.001
uniform float u_iterations = 12.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 0.1

uniform float u_color_field = 3.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.00001 | @max 20.0 | @sens 0.001
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -10.0 | @max 10.0 | @sens 0.001

uniform vec3 u_color_1 = vec3(0.02,0.01,0.08); // @label Color 1
uniform vec3 u_color_2 = vec3(0.05,0.3,1.0); // @label Color 2
uniform vec3 u_color_3 = vec3(0.8,0.05,0.7); // @label Color 3
uniform vec3 u_color_4 = vec3(1.0,0.8,0.05); // @label Color 4

vec3 oct_g2_color(float x) {
    x=fract(x);
    if(x<0.3333) return mix(u_color_1,u_color_2,smoothstep(0.0,0.3333,x));
    if(x<0.6666) return mix(u_color_2,u_color_3,smoothstep(0.3333,0.6666,x));
    return mix(u_color_3,u_color_4,smoothstep(0.6666,1.0,x));
}

vec4 fx_octonion_g2(vec2 uv) {
    vec2 p=(uv-vec2(0.5))/u_zoom+vec2(u_pan_x,u_pan_y);

    float t=u_time*u_c_motion;

    float q0=0.0;
    float q1=p.x;
    float q2=p.y;
    float q3=u_q3;
    float q4=u_q4;
    float q5=u_q5;
    float q6=u_q6;
    float q7=u_q7;

    float c0=u_c0+t;
    float c1=u_c1+t;
    float c2=u_c2+t;
    float c3=u_c3+t;
    float c4=u_c4;
    float c5=u_c5;
    float c6=u_c6;
    float c7=u_c7;

    float trap=0.0;
    float radius=0.0;
    float iter=0.0;

    for(int n=0;n<60;n++) {
        if(float(n)>=u_iterations) break;

        float rr=q1*q1+q2*q2+q3*q3+q4*q4+q5*q5+q6*q6+q7*q7;

        float next0=q0*q0-rr;
        float next1=2.0*q0*q1;
        float next2=2.0*q0*q2;
        float next3=2.0*q0*q3;
        float next4=2.0*q0*q4;
        float next5=2.0*q0*q5;
        float next6=2.0*q0*q6;
        float next7=2.0*q0*q7;

        q0=mix(q0,next0*u_strength+c0,u_feedback);
        q1=mix(q1,next1*u_strength+c1,u_feedback);
        q2=mix(q2,next2*u_strength+c2,u_feedback);
        q3=mix(q3,next3*u_strength+c3,u_feedback);
        q4=mix(q4,next4*u_strength+c4,u_feedback);
        q5=mix(q5,next5*u_strength+c5,u_feedback);
        q6=mix(q6,next6*u_strength+c6,u_feedback);
        q7=mix(q7,next7*u_strength+c7,u_feedback);

        int steps=int(clamp(u_g2_steps,1.0,12.0));
        float hstep=u_g2_strength/float(steps);

        for(int s=0;s<12;s++) {
            if(s>=steps) break;

            float d1=
                u_g2_c*q2-u_g2_b*q3+
                u_g2_e*q4-u_g2_d*q5-
                u_g2_g*q6+(u_g2_f-u_g2_m)*q7;

            float d2=
                -u_g2_c*q1+u_g2_a*q3+
                u_g2_f*q4+(-u_g2_g+u_g2_n)*q5+
                (u_g2_d-u_g2_k)*q6+
                (-u_g2_e-u_g2_l)*q7;

            float d3=
                u_g2_b*q1-u_g2_a*q2-
                u_g2_n*q4+u_g2_m*q5+
                u_g2_l*q6-u_g2_k*q7;

            float d4=
                -u_g2_e*q1-u_g2_f*q2+
                u_g2_n*q3+(-u_g2_a+u_g2_h)*q5+
                (-u_g2_b+u_g2_i)*q6+
                (u_g2_c-u_g2_j)*q7;

            float d5=
                u_g2_d*q1+(u_g2_g-u_g2_n)*q2-
                u_g2_m*q3+(u_g2_a-u_g2_h)*q4+
                u_g2_j*q6+u_g2_i*q7;

            float d6=
                u_g2_g*q1+(u_g2_k-u_g2_d)*q2-
                u_g2_l*q3+(u_g2_b-u_g2_i)*q4-
                u_g2_j*q5-u_g2_h*q7;

            float d7=
                (-u_g2_f+u_g2_m)*q1+
                (u_g2_e+u_g2_l)*q2+
                u_g2_k*q3+(-u_g2_c+u_g2_j)*q4-
                u_g2_i*q5+u_g2_h*q6;

            q1+=d1*hstep;
            q2+=d2*hstep;
            q3+=d3*hstep;
            q4+=d4*hstep;
            q5+=d5*hstep;
            q6+=d6*hstep;
            q7+=d7*hstep;

            float old_len=sqrt(
                q1*q1+q2*q2+q3*q3+
                q4*q4+q5*q5+q6*q6+q7*q7
            );

            if(old_len>0.000001) {
                float inv_len=1.0/old_len;
                q1*=inv_len;
                q2*=inv_len;
                q3*=inv_len;
                q4*=inv_len;
                q5*=inv_len;
                q6*=inv_len;
                q7*=inv_len;
            }
        }

        radius=sqrt(
            q0*q0+q1*q1+q2*q2+q3*q3+
            q4*q4+q5*q5+q6*q6+q7*q7
        );

        trap+=abs(q0)+abs(q1)+abs(q2)+abs(q3);
        trap+=abs(q4)+abs(q5)+abs(q6)+abs(q7);

        iter=float(n);

        if(radius>u_escape) break;
    }

    float field=0.0;

    if(u_color_field<0.5)
        field=iter/max(u_iterations,1.0);
    else if(u_color_field<1.5)
        field=log(1.0+radius)*u_color_scale;
    else if(u_color_field<2.5)
        field=atan(q2,q1)/6.2831853+0.5;
    else if(u_color_field<3.5)
        field=q0*u_color_scale;
    else
        field=sqrt(q1*q1+q2*q2+q3*q3)*u_color_scale;

    field+=trap*0.01+u_time*u_color_cycle;

    return vec4(oct_g2_color(field),1.0);
}
"""


const SRC_QUATERNION_LAB_2: String = """
uniform float u_zoom = 2.9; // @label Zoom | @min 0.00001 | @max 200.0 | @sens 0.02
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_q_z = 0.0; // @label Q Z Slice | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_q_w = 0.0; // @label Q W Slice | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_q_motion_z = 0.0; // @label Z Slice Motion | @min -10.0 | @max 10.0 | @sens 0.00001
uniform float u_q_motion_w = 0.0; // @label W Slice Motion | @min -10.0 | @max 10.0 | @sens 0.00001

uniform float u_c_x = 0.0; // @label C X | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_c_y = 0.0; // @label C Y | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_c_z = 0.0; // @label C Z | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_c_w = 0.0; // @label C W | @min -50.0 | @max 50.0 | @sens 0.00001
uniform float u_c_motion_x = 0.0; // @label C X Motion | @min -10.0 | @max 10.0 | @sens 0.00001
uniform float u_c_motion_y = 0.0; // @label C Y Motion | @min -10.0 | @max 10.0 | @sens 0.00001
uniform float u_c_motion_z = 0.0; // @label C Z Motion | @min -10.0 | @max 10.0 | @sens 0.00001
uniform float u_c_motion_w = 0.0; // @label C W Motion | @min -10.0 | @max 10.0 | @sens 0.00001

uniform float u_a_x = 1.0; // @label A X | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_a_y = 0.0; // @label A Y | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_a_z = 0.0; // @label A Z | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_a_w = 0.0; // @label A W | @min -20.0 | @max 20.0 | @sens 0.00001

uniform float u_b_x = 1.0; // @label B X | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_b_y = 0.0; // @label B Y | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_b_z = 0.0; // @label B Z | @min -20.0 | @max 20.0 | @sens 0.00001
uniform float u_b_w = 0.0; // @label B W | @min -20.0 | @max 20.0 | @sens 0.00001

uniform float u_operator_mix = 0.0; // @label A-Q-B Mix | @min -5.0 | @max 5.0 | @sens 0.00001

uniform float u_rot_x = 1.0; // @label Rotation X | @min -5.0 | @max 5.0 | @sens 0.00001
uniform float u_rot_y = 0.0; // @label Rotation Y | @min -5.0 | @max 5.0 | @sens 0.00001
uniform float u_rot_z = 0.0; // @label Rotation Z | @min -5.0 | @max 5.0 | @sens 0.00001
uniform float u_rot_w = 0.0; // @label Rotation W | @min -5.0 | @max 5.0 | @sens 0.00001
uniform float u_rotation_strength = 1.0; // @label Quaternion Rotation Strength | @min -5.0 | @max 5.0 | @sens 0.01

uniform float u_strength = 1.0; // @label Quaternion Strength | @min -10.0 | @max 10.0 | @sens 0.00001
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 10.0 | @sens 0.00001
uniform float u_iterations = 12.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_field = 1.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.00001
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.00001

uniform vec4 u_color_1 : source_color = vec4(0.02,0.0,0.08,1.0); // @label Color 1
uniform vec4 u_color_2 : source_color = vec4(0.0,0.3,1.0,1.0); // @label Color 2
uniform vec4 u_color_3 : source_color = vec4(1.0,0.1,0.7,1.0); // @label Color 3
uniform vec4 u_color_4 : source_color = vec4(1.0,0.8,0.1,1.0); // @label Color 4

vec4 quat_mul_q(vec4 a,vec4 b) {
    return vec4(
        a.x*b.x-a.y*b.y-a.z*b.z-a.w*b.w,
        a.x*b.y+a.y*b.x+a.z*b.w-a.w*b.z,
        a.x*b.z-a.y*b.w+a.z*b.x+a.w*b.y,
        a.x*b.w+a.y*b.z-a.z*b.y+a.w*b.x
    );
}

vec4 quat_conj_q(vec4 q) {
    return vec4(q.x,-q.y,-q.z,-q.w);
}

vec4 quat_rotate_q(vec4 q,vec4 r) {
    r=normalize(r);
    return quat_mul_q(quat_mul_q(r,q),quat_conj_q(r));
}

vec3 quat_palette_q(float x) {
    x = fract(x);
    if (x < 0.3333) return mix(u_color_1.rgb,u_color_2.rgb,x*3.0);
    if (x < 0.6666) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.3333)*3.0);
    return mix(u_color_3.rgb,u_color_4.rgb,(x-0.6666)*3.0);
}

vec4 fx_quaternion_lab_2(vec2 uv) {
	float a=u_master_rotation;
    float cs=cos(a);
    float sn=sin(a);
    vec2 p=(uv-vec2(0.5))*u_zoom+vec2(u_pan_x,u_pan_y);
    p=mat2(vec2(cs,sn),vec2(-sn,cs))*p;

    float t=u_time;

    vec4 q=vec4(
        p.x,
        p.y,
        u_q_z+t*u_q_motion_z,
        u_q_w+t*u_q_motion_w
    );

    vec4 c=vec4(
        u_c_x+t*u_c_motion_x,
        u_c_y+t*u_c_motion_y,
        u_c_z+t*u_c_motion_z,
        u_c_w+t*u_c_motion_w
    );

    vec4 A=vec4(u_a_x,u_a_y,u_a_z,u_a_w);
    vec4 B=vec4(u_b_x,u_b_y,u_b_z,u_b_w);
    vec4 R=vec4(u_rot_x,u_rot_y,u_rot_z,u_rot_w);

    float orbit=0.0;
    float magnitude=0.0;

    for(int i=0;i<60;i++) {
        if(float(i)>=u_iterations) break;

        vec4 square=quat_mul_q(q,q);
        vec4 left_right=quat_mul_q(quat_mul_q(A,q),B);
        vec4 next=mix(square,left_right,u_operator_mix)*u_strength+c;

        if(abs(u_rotation_strength)>0.0001) {
            vec4 rotated=quat_rotate_q(next,R);
            next=mix(next,rotated,clamp(u_rotation_strength,0.0,1.0));
        }

        q=mix(q,next,u_feedback);
        magnitude=dot(q,q);
        orbit+=1.0;

        if(magnitude>u_escape*u_escape) break;
    }

    float field;

    if(u_color_field<0.5)
        field=orbit/u_iterations;
    else if(u_color_field<1.5)
        field=sqrt(magnitude)*u_color_scale;
    else if(u_color_field<2.5)
        field=atan(q.y,q.x)/6.28318*u_color_scale;
    else if(u_color_field<3.5)
        field=q.z*u_color_scale;
    else
        field=q.w*u_color_scale;

    field+=u_color_cycle*t;

    vec3 col=quat_palette_q(field);
    float glow=1.0/(1.0+0.15*sqrt(magnitude));

    return vec4(col*glow,1.0);
}
"""



const SRC_QUATERNION_LAB: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 220.0 | @sens 0.02
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_q_z = 0.0; // @label Q Z Slice | @min -50.0 | @max 50.0 | @sens 0.01
uniform float u_q_w = 0.0; // @label Q W Slice | @min -50.0 | @max 50.0 | @sens 0.01
uniform float u_q_motion_z = 0.0; // @label Z Slice Motion | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_q_motion_w = 0.0; // @label W Slice Motion | @min -10.0 | @max 10.0 | @sens 0.01

uniform float u_c_x = 0.0; // @label C X | @min -50.0 | @max 50.0 | @sens 0.01
uniform float u_c_y = 0.0; // @label C Y | @min -50.0 | @max 50.0 | @sens 0.01
uniform float u_c_z = 0.0; // @label C Z | @min -50.0 | @max 50.0 | @sens 0.01
uniform float u_c_w = 0.0; // @label C W | @min -50.0 | @max 50.0 | @sens 0.01

uniform float u_c_motion_x = 0.0; // @label C X Motion | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Y Motion | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_c_motion_z = 0.0; // @label C Z Motion | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_c_motion_w = 0.0; // @label C W Motion | @min -10.0 | @max 10.0 | @sens 0.01

uniform float u_strength = 1.0; // @label Quaternion Strength | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 10.0 | @sens 0.01
uniform float u_iterations = 12.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_field = 2.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.02,0.0,0.08,1.0); // @label Color 1
uniform vec4 u_color_2 : source_color = vec4(0.0,0.3,1.0,1.0); // @label Color 2
uniform vec4 u_color_3 : source_color = vec4(1.0,0.1,0.7,1.0); // @label Color 3
uniform vec4 u_color_4 : source_color = vec4(1.0,0.8,0.1,1.0); // @label Color 4

vec4 quat_mul(vec4 a, vec4 b) {
    return vec4(
        a.x*b.x-a.y*b.y-a.z*b.z-a.w*b.w,
        a.x*b.y+a.y*b.x+a.z*b.w-a.w*b.z,
        a.x*b.z-a.y*b.w+a.z*b.x+a.w*b.y,
        a.x*b.w+a.y*b.z-a.z*b.y+a.w*b.x
    );
}

vec4 quat_square(vec4 q) {
    return quat_mul(q,q);
}

vec3 quat_palette(float x) {
    x = fract(x);
    if (x < 0.3333) return mix(u_color_1.rgb,u_color_2.rgb,x*3.0);
    if (x < 0.6666) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.3333)*3.0);
    return mix(u_color_3.rgb,u_color_4.rgb,(x-0.6666)*3.0);
}

vec4 fx_quaternion_lab(vec2 uv) {
    vec2 p = (uv-vec2(0.5))*u_zoom+vec2(u_pan_x,u_pan_y);
    float t = u_time;

    vec4 q = vec4(
        p.x,
        p.y,
        u_q_z+t*u_q_motion_z,
        u_q_w+t*u_q_motion_w
    );

    vec4 c = vec4(
        u_c_x+t*u_c_motion_x,
        u_c_y+t*u_c_motion_y,
        u_c_z+t*u_c_motion_z,
        u_c_w+t*u_c_motion_w
    );

    float orbit = 0.0;
    float magnitude = 0.0;
    float field = 0.0;

    for (int i=0;i<60;i++) {
        if (float(i)>=u_iterations) break;

        vec4 next = quat_square(q)*u_strength+c;
        q = mix(q,next,u_feedback);
        magnitude = dot(q,q);
        orbit += 1.0;

        if (magnitude>u_escape*u_escape) break;
    }

    if (u_color_field<0.5)
        field = orbit/u_iterations;
    else if (u_color_field<1.5)
        field = sqrt(magnitude)*u_color_scale;
    else if (u_color_field<2.5)
        field = atan(q.y,q.x)/6.28318*u_color_scale;
    else if (u_color_field<3.5)
        field = q.z*u_color_scale;
    else
        field = q.w*u_color_scale;

    field += u_color_cycle*t;
    vec3 col = quat_palette(field);
    float glow = 1.0/(1.0+0.15*sqrt(magnitude));

    return vec4(col*glow,1.0);
}
"""


const SRC_RECIPROCAL_FEEDBACK: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 220.0 | @sens 0.01
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_alpha_real = 0.35; // @label Alpha Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_alpha_imag = 0.0; // @label Alpha Imaginary | @min -100.0 | @max 100.0 | @sens 0.01

uniform float u_c_real = 0.0; // @label C Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_imag = 0.0; // @label C Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_motion_x = 0.0; // @label C Motion Real | @min -20.0 | @max 20.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Motion Imaginary | @min -20.0 | @max 20.0 | @sens 0.01

uniform float u_reciprocal_strength = 1.0; // @label Reciprocal Strength | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 10.0 | @sens 0.01
uniform float u_iterations = 12.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_field = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.02,0.01,0.08,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.05,0.30,1.0,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.95,0.05,0.60,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.70,0.03,1.0);

vec2 cmul_recip(vec2 a, vec2 b) {
    return vec2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x);
}

vec2 cdiv_recip(vec2 a, vec2 b) {
    float d = max(dot(b,b),0.000001);
    return vec2(
        (a.x*b.x+a.y*b.y)/d,
        (a.y*b.x-a.x*b.y)/d
    );
}

vec3 palette_recip(float x) {
    x = fract(x);
    if (x < 0.3333) return mix(u_color_1.rgb,u_color_2.rgb,smoothstep(0.0,0.3333,x));
    if (x < 0.6666) return mix(u_color_2.rgb,u_color_3.rgb,smoothstep(0.3333,0.6666,x));
    return mix(u_color_3.rgb,u_color_4.rgb,smoothstep(0.6666,1.0,x));
}

vec3 bipolar_recip(float x) {
    float a = clamp(abs(x)*u_color_scale,0.0,1.0);
    float side = x < 0.0 ? 0.0 : 1.0;
    vec3 neg = mix(u_color_1.rgb,u_color_3.rgb,a);
    vec3 pos = mix(u_color_2.rgb,u_color_4.rgb,a);
    return mix(neg,pos,side);
}

vec4 fx_reciprocal_feedback(vec2 uv) {
    vec2 z = (uv-vec2(0.5))*u_zoom+vec2(u_pan_x,u_pan_y);

    vec2 alpha = vec2(u_alpha_real,u_alpha_imag);

    vec2 c = vec2(
        u_c_real+u_time*u_c_motion_x,
        u_c_imag+u_time*u_c_motion_y
    );

    float iter = 0.0;

    for (int i=0;i<60;i++) {
        if (float(i)>=u_iterations) break;

        vec2 reciprocal = cdiv_recip(alpha,z);
        vec2 next = z+reciprocal*u_reciprocal_strength+c;

        z = mix(z,next,u_feedback);
        iter += 1.0;

        if (dot(z,z)>u_escape*u_escape) break;
    }

    float mag = length(z);
    float phase = atan(z.y,z.x);

    vec3 col;

    if (u_color_field < 0.5) {
        // 0: Iteration structure
        float v = iter/max(u_iterations,1.0);
        col = palette_recip(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 1.5) {
        // 1: Magnitude shells
        float v = log(1.0+mag)*u_color_scale;
        col = palette_recip(v+u_time*u_color_cycle);
    } else if (u_color_field < 2.5) {
        // 2: Phase wheel
        float v = phase/6.2831853+0.5;
        col = palette_recip(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 3.5) {
        // 3: Real bipolar field
        col = bipolar_recip(z.x);
    } else {
        // 4: Imaginary bipolar field
        col = bipolar_recip(z.y);
    }

    float core = exp(-8.0*mag);
    col += core*0.25;

    return vec4(col,1.0);
}
"""

const SRC_COMPLEX_SELF_POWER: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 200.0 | @sens 0.01
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_c_real = 0.0; // @label C Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_imag = 0.0; // @label C Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_motion_x = 0.0; // @label C Motion Real | @min -20.0 | @max 20.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Motion Imaginary | @min -20.0 | @max 20.0 | @sens 0.01

uniform float u_power_strength = 1.0; // @label Self Power Strength | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 13.0 | @sens 0.01
uniform float u_iterations = 12.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_field = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.02,0.01,0.08,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.05,0.30,1.0,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.95,0.05,0.60,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.70,0.03,1.0);

vec2 cmul_self(vec2 a, vec2 b) {
    return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x);
}

vec2 clog_self(vec2 z) {
    float r = max(length(z),0.000001);
    return vec2(log(r),atan(z.y,z.x));
}

vec2 cexp_self(vec2 z) {
    float e = clamp(z.x,-20.0,20.0);
    float q = exp(e);
    return q*vec2(cos(z.y),sin(z.y));
}

vec2 cpow_self(vec2 z) {
    return cexp_self(cmul_self(z,clog_self(z)));
}

vec3 palette_self(float x) {
    x = fract(x);
    if (x < 0.3333) return mix(u_color_1.rgb,u_color_2.rgb,smoothstep(0.0,0.3333,x));
    if (x < 0.6666) return mix(u_color_2.rgb,u_color_3.rgb,smoothstep(0.3333,0.6666,x));
    return mix(u_color_3.rgb,u_color_4.rgb,smoothstep(0.6666,1.0,x));
}

vec3 bipolar_self(float x) {
    float a = clamp(abs(x)*u_color_scale,0.0,1.0);
    float side = x < 0.0 ? 0.0 : 1.0;
    vec3 neg = mix(u_color_1.rgb,u_color_3.rgb,a);
    vec3 pos = mix(u_color_2.rgb,u_color_4.rgb,a);
    return mix(neg,pos,side);
}

vec4 fx_complex_self_power(vec2 uv) {
    vec2 z = (uv-vec2(0.5))*u_zoom+vec2(u_pan_x,u_pan_y);

    vec2 c = vec2(
        u_c_real+u_time*u_c_motion_x,
        u_c_imag+u_time*u_c_motion_y
    );

    float iter = 0.0;

    for (int i=0;i<60;i++) {
        if (float(i)>=u_iterations) break;

        vec2 next = cpow_self(z)*u_power_strength+c;
        z = mix(z,next,u_feedback);
        iter += 1.0;

        if (dot(z,z)>u_escape*u_escape) break;
    }

    float mag = length(z);
    float phase = atan(z.y,z.x);

    vec3 col;

    if (u_color_field < 0.5) {
        // 0: Iteration structure
        float v = iter/max(u_iterations,1.0);
        col = palette_self(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 1.5) {
        // 1: Magnitude shells
        float v = log(1.0+mag)*u_color_scale;
        col = palette_self(v+u_time*u_color_cycle);
    } else if (u_color_field < 2.5) {
        // 2: Phase wheel
        float v = phase/6.2831853+0.5;
        col = palette_self(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 3.5) {
        // 3: Real bipolar field
        col = bipolar_self(z.x);
    } else {
        // 4: Imaginary bipolar field
        col = bipolar_self(z.y);
    }

    float glow = 1.0-exp(-0.035*mag);
    col += glow*0.12;

    return vec4(col,1.0);
}
"""


const SRC_COMPLEX_POWER_LAB: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 200.0 | @sens 0.01
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_x_real = 2.0; // @label X Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_x_imag = 0.0; // @label X Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_x_motion_x = 0.0; // @label X Motion Real | @min -20.0 | @max 20.0 | @sens 0.01
uniform float u_x_motion_y = 0.0; // @label X Motion Imaginary | @min -20.0 | @max 20.0 | @sens 0.01

uniform float u_c_real = 0.43; // @label C Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_imag = 0.0; // @label C Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_motion_x = 0.0; // @label C Motion Real | @min -20.0 | @max 20.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Motion Imaginary | @min -20.0 | @max 20.0 | @sens 0.01

uniform float u_power_strength = 1.0; // @label Power Strength | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 13.0 | @sens 0.01
uniform float u_iterations = 5.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_field = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.03,0.01,0.10,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.10,0.25,0.95,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.95,0.10,0.65,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.75,0.05,1.0);

vec2 cmul_power(vec2 a, vec2 b) {
    return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x);
}

vec2 clog_power(vec2 z) {
    float r = max(length(z), 0.000001);
    return vec2(log(r), atan(z.y,z.x));
}

vec2 cexp_power(vec2 z) {
    float e = clamp(z.x,-20.0,20.0);
    float q = exp(e);
    return q * vec2(cos(z.y),sin(z.y));
}

vec2 cpow_power(vec2 z, vec2 p) {
    vec2 l = clog_power(z);
    return cexp_power(cmul_power(p,l));
}

vec3 palette_power(float x) {
    x = fract(x);
    if (x < 0.3333) return mix(u_color_1.rgb,u_color_2.rgb,smoothstep(0.0,0.3333,x));
    if (x < 0.6666) return mix(u_color_2.rgb,u_color_3.rgb,smoothstep(0.3333,0.6666,x));
    return mix(u_color_3.rgb,u_color_4.rgb,smoothstep(0.6666,1.0,x));
}

vec3 bipolar_power(float x) {
    float a = clamp(abs(x)*u_color_scale,0.0,1.0);
    float side = x < 0.0 ? 0.0 : 1.0;
    vec3 neg = mix(u_color_1.rgb,u_color_3.rgb,a);
    vec3 pos = mix(u_color_2.rgb,u_color_4.rgb,a);
    return mix(neg,pos,side);
}

vec4 fx_complex_power(vec2 uv) {
    vec2 p = (uv-vec2(0.5))*u_zoom + vec2(u_pan_x,u_pan_y);

    vec2 x = vec2(
        u_x_real + u_time*u_x_motion_x,
        u_x_imag + u_time*u_x_motion_y
    );

    vec2 c = vec2(
        u_c_real + u_time*u_c_motion_x,
        u_c_imag + u_time*u_c_motion_y
    );

    vec2 z = p;
    float iter = 0.0;

    for (int i=0;i<60;i++) {
        if (float(i)>=u_iterations) break;

        vec2 next = cpow_power(z,x)*u_power_strength+c;
        z = mix(z,next,u_feedback);
        iter += 1.0;

        if (dot(z,z)>u_escape*u_escape) break;
    }

    float mag = length(z);
    float phase = atan(z.y,z.x);

    vec3 col;

    if (u_color_field < 0.5) {
        // 0: Iteration bands
        float v = iter/max(u_iterations,1.0);
        col = palette_power(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 1.5) {
        // 1: Magnitude shells
        float v = log(1.0+mag)*u_color_scale;
        col = palette_power(v+u_time*u_color_cycle);
    } else if (u_color_field < 2.5) {
        // 2: Phase wheel
        float v = phase/6.2831853+0.5;
        col = palette_power(v*u_color_scale+u_time*u_color_cycle);
    } else if (u_color_field < 3.5) {
        // 3: Real-axis bipolar field
        col = bipolar_power(z.x);
    } else {
        // 4: Imaginary-axis bipolar field
        col = bipolar_power(z.y);
    }

    float glow = 1.0-exp(-0.035*mag);
    col += glow*0.12;

    return vec4(col,1.0);
}
"""



const SRC_COMPLEX_MOBIUS: String= """

uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 200.0 | @sens 0.02
uniform float u_pan_x = 0.0; // @label Pan X | @min -40.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_a_x = 1.0; // @label A Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_a_y = 0.0; // @label A Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_b_x = 0.0; // @label B Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_b_y = 0.0; // @label B Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_x = 0.1; // @label C Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_y = 0.0; // @label C Imaginary | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_d_x = 1.0; // @label D Real | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_d_y = 0.0; // @label D Imaginary | @min -100.0 | @max 100.0 | @sens 0.01

uniform float u_strength = 1.0; // @label Transform Strength | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 13.0 | @sens 0.01
uniform float u_iterations = 8.0; // @label Iterations | @min 1.0 | @max 40.0 | @sens 1.0
uniform float u_escape = 50.0; // @label Escape | @min 2.0 | @max 500.0 | @sens 1.0

uniform float u_color_mode = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0 | @is_style
// @style 0 = Iteration
// @style 1 = Magnitude
// @style 2 = Phase
// @style 3 = Real
// @style 4 = Imaginary

uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 12.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -3.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.01,0.01,0.06,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.05,0.35,1.0,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.95,0.05,0.55,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.75,0.10,1.0);

vec2 cmul_mob(vec2 a,vec2 b) {
    return vec2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x);
}

vec2 cdiv_mob(vec2 a,vec2 b) {
    float d=dot(b,b)+0.000001;
    return vec2(a.x*b.x+a.y*b.y,a.y*b.x-a.x*b.y)/d;
}

vec2 mobius_mob(vec2 z,vec2 a,vec2 b,vec2 c,vec2 d) {
    return cdiv_mob(cmul_mob(a,z)+b,cmul_mob(c,z)+d);
}

vec3 mobius_palette(float x) {
    x=fract(x);
    if(x<0.25) return mix(u_color_1.rgb,u_color_2.rgb,x*4.0);
    if(x<0.50) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.25)*4.0);
    if(x<0.75) return mix(u_color_3.rgb,u_color_4.rgb,(x-0.50)*4.0);
    return mix(u_color_4.rgb,u_color_1.rgb,(x-0.75)*4.0);
}

vec4 fx_complex_mobius(vec2 uv) {
    vec2 z=(uv-vec2(0.5))*2.0/u_zoom+vec2(u_pan_x,u_pan_y);

    vec2 a=vec2(u_a_x,u_a_y);
    vec2 b=vec2(u_b_x,u_b_y);
    vec2 c=vec2(u_c_x,u_c_y);
    vec2 d=vec2(u_d_x,u_d_y);

    float n=0.0;

    for(int i=0;i<40;i++) {
        if(float(i)>=u_iterations) break;

        vec2 next=mobius_mob(z,a,b,c,d);
        z=mix(z,next,u_feedback*u_strength);
        n+=1.0;

        if(length(z)>u_escape) break;
    }

    float field;

    if(u_color_mode<0.5)
        field=n/u_iterations;
    else if(u_color_mode<1.5)
        field=log(1.0+length(z));
    else if(u_color_mode<2.5)
        field=(atan(z.y,z.x)+3.14159265)/6.2831853;
    else if(u_color_mode<3.5)
        field=abs(z.x);
    else
        field=abs(z.y);

    field=field*u_color_scale+u_time*u_color_cycle;

    return vec4(mobius_palette(field),1.0);
}
"""





const SRC_COMPLEX_TANGENT: String ="""
uniform float u_zoom = 1.5; // @label Zoom | @min 0.002 | @max 180.000 | @sens 0.020
uniform float u_pan_x = 0.0; // @label Pan X | @min -040.0 | @max 40.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -40.0 | @max 40.0 | @sens 0.01

uniform float u_c_x = 1.0; // @label C Real | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_c_y = 0.5; // @label C Imaginary | @min -30.0 | @max 30.0 | @sens 0.01
uniform float u_c_motion_x = 0.0; // @label C Motion X | @min -10.0 | @max 10.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Motion Y | @min -10.0 | @max 10.0 | @sens 0.01

uniform float u_tan_strength = 1.0; // @label Tangent Strength | @min 0.05 | @max 40.0 | @sens 0.01
uniform float u_feedback = 1.0; // @label Feedback | @min 0.0 | @max 14.0 | @sens 0.01
uniform float u_iterations = 18.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 20.0; // @label Escape | @min 2.0 | @max 100.0 | @sens 1.0

uniform float u_color_mode = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0 | @is_style
// @style 0 = Iteration
// @style 1 = Magnitude
// @style 2 = Phase
// @style 3 = Real
// @style 4 = Imaginary

uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 8.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -2.0 | @max 2.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.01,0.01,0.06,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.10,0.25,0.95,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.90,0.05,0.55,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.75,0.10,1.0);

vec2 cdiv_tan(vec2 a,vec2 b) {
    float d=dot(b,b)+0.000001;
    return vec2(a.x*b.x+a.y*b.y,a.y*b.x-a.x*b.y)/d;
}

vec2 csin_tan(vec2 z) {
    return vec2(sin(z.x)*cosh(z.y),cos(z.x)*sinh(z.y));
}

vec2 ccos_tan(vec2 z) {
    return vec2(cos(z.x)*cosh(z.y),-sin(z.x)*sinh(z.y));
}

vec2 ctan_tan(vec2 z) {
    return cdiv_tan(csin_tan(z),ccos_tan(z));
}

vec3 tan_palette(float x) {
    x=fract(x);
    if(x<0.25) return mix(u_color_1.rgb,u_color_2.rgb,x*4.0);
    if(x<0.50) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.25)*4.0);
    if(x<0.75) return mix(u_color_3.rgb,u_color_4.rgb,(x-0.50)*4.0);
    return mix(u_color_4.rgb,u_color_1.rgb,(x-0.75)*4.0);
}

vec4 fx_complex_tangent(vec2 uv) {
    vec2 z=(uv-vec2(0.5))*2.0/u_zoom+vec2(u_pan_x,u_pan_y);
    vec2 c=vec2(u_c_x,u_c_y)+vec2(u_c_motion_x,u_c_motion_y)*u_time;

    float n=0.0;

    for(int i=0;i<60;i++) {
        if(float(i)>=u_iterations) break;

        vec2 next=ctan_tan(z)*u_tan_strength+c;
        z=mix(z,next,u_feedback);
        n+=1.0;

        if(length(z)>u_escape) break;
    }

    float field;

    if(u_color_mode<0.5)
        field=n/u_iterations;
    else if(u_color_mode<1.5)
        field=log(1.0+length(z));
    else if(u_color_mode<2.5)
        field=(atan(z.y,z.x)+3.14159265)/6.2831853;
    else if(u_color_mode<3.5)
        field=abs(z.x);
    else
        field=abs(z.y);

    field=field*u_color_scale+u_time*u_color_cycle;

    return vec4(tan_palette(field),1.0);
}
"""



const SRC_COMPLEX_LOG_LAB: String = """
uniform float u_zoom = 1.0; // @label Zoom | @min 0.002 | @max 200.0 | @sens 0.02
uniform float u_pan_x = 0.0; // @label Pan X | @min -300.0 | @max 300.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -300.0 | @max 300.0 | @sens 0.01

uniform float u_c_x = 0.0; // @label C Real | @min -130.0 | @max 130.0 | @sens 0.01
uniform float u_c_y = 0.0; // @label C Imaginary | @min -130.0 | @max 130.0 | @sens 0.01
uniform float u_c_motion_x = 0.0; // @label C Motion X | @min -100.0 | @max 100.0 | @sens 0.01
uniform float u_c_motion_y = 0.0; // @label C Motion Y | @min -100.0 | @max 100.0 | @sens 0.01

uniform float u_log_scale = 1.0; // @label Log Strength | @min 0.001 | @max 13.00 | @sens 0.01
uniform float u_feedback = 2.05; // @label Feedback | @min 0.0 | @max 20.00 | @sens 0.01
uniform float u_iterations = 24.0; // @label Iterations | @min 1.0 | @max 60.0 | @sens 1.0
uniform float u_escape = 20.0; // @label Escape | @min 2.0 | @max 100.0 | @sens 1.0

uniform float u_color_mode = 0.0; // @label Color Field | @min 0.0 | @max 4.0 | @sens 1.0 | @is_style
uniform float u_color_scale = 1.0; // @label Color Scale | @min 0.05 | @max 8.0 | @sens 0.01
uniform float u_color_cycle = 0.0; // @label Color Cycle | @min -2.0 | @max 2.0 | @sens 0.01

uniform vec4 u_color_1 : source_color = vec4(0.02,0.01,0.08,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.05,0.30,0.90,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.90,0.10,0.60,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.80,0.15,1.0);

vec2 clog_lab(vec2 z) {
    float r=max(length(z),0.00001);
    return vec2(log(r),atan(z.y,z.x));
}

vec3 log_palette(float x) {
    x=fract(x);
    if(x<0.25) return mix(u_color_1.rgb,u_color_2.rgb,x*4.0);
    if(x<0.50) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.25)*4.0);
    if(x<0.75) return mix(u_color_3.rgb,u_color_4.rgb,(x-0.50)*4.0);
    return mix(u_color_4.rgb,u_color_1.rgb,(x-0.75)*4.0);
}

vec4 fx_complex_log_lab(vec2 uv) {
    vec2 z=(uv-vec2(0.5))*2.0/u_zoom+vec2(u_pan_x,u_pan_y);

    vec2 c=vec2(u_c_x,u_c_y);
    c+=vec2(u_c_motion_x,u_c_motion_y)*u_time;

    float n=0.0;
    float escaped=0.0;

    for(int i=0;i<80;i++) {
        if(float(i)>=u_iterations) break;

        vec2 l=clog_lab(z);
        vec2 next=l*u_log_scale+c;
        z=mix(z,next,u_feedback);

        n+=1.0;

        if(length(z)>u_escape) {
            escaped=1.0;
            break;
        }
    }

    float field;

    if(u_color_mode<0.5)
        field=n/u_iterations;
    else if(u_color_mode<1.5)
        field=log(1.0+length(z));
    else if(u_color_mode<2.5)
        field=(atan(z.y,z.x)+3.14159265)/6.2831853;
    else if(u_color_mode<3.5)
        field=abs(z.x);
    else
        field=abs(z.y);

    field*=u_color_scale;
    field+=u_time*u_color_cycle;

    vec3 col=log_palette(field);

    if(escaped>0.5)
        col*=0.85;

    return vec4(col,1.0);
}
"""

const SRC_FRACTAL_6D: String="""
uniform float u_render_mode = 0.0; // @label 6D Slice| @min 0.0 | @max 5.0 | @sens 1.0 | @is_style

uniform float u_zoom = 1.000; // @label Zoom | @min 0.002 | @max 80.000 | @sens 0.0200
uniform float u_pan_x = 0.000; // @label Pan X | @min -30.0 | @max 300.000 | @sens 0.0100
uniform float u_pan_y = 0.000; // @label Pan Y | @min -30.0 | @max 300.000 | @sens 0.0100
uniform float u_max_iterations = 64.000; // @label Iterations | @min 18.000 | @max 128.0 | @sens 1.000
uniform float u_escape = 16.000; // @label Escape Radius | @min 1.000 | @max 64.0 | @sens 0.500

// Z = starting value
uniform float u_z_x = 0.000; // @label Z Real | @min -130.000 | @max 130.000 | @sens 0.0100
uniform float u_z_y = 0.000; // @label Z Imaginary | @min -130.000 | @max 130.0 | @sens 0.0100
uniform float u_z_motion_x = 0.000; // @label Z Motion X | @min -11.000 | @max 11.0 | @sens 0.0100
uniform float u_z_motion_y = 0.000; // @label Z Motion Y | @min -11.000 | @max 11.0 | @sens 0.0100

// C = constant
uniform float u_c_x = -0.700; // @label C Real | @min -120.000 | @max 120.000 | @sens 0.0100
uniform float u_c_y = 0.2700; // @label C Imaginary | @min -120.000 | @max 120.000 | @sens 0.0100
uniform float u_c_motion_x = 0.0000; // @label C Motion X | @min -11.000 | @max 11.0 | @sens 0.0100
uniform float u_c_motion_y = 0.0000; // @label C Motion Y | @min -11.000 | @max 11.0 | @sens 0.0100

// X = complex exponent
uniform float u_exp_x = 2.0000; // @label X Real | @min -130.0 | @max 140.000 | @sens 0.0100
uniform float u_exp_y = 0.0000; // @label X Imaginary | @min -130.0 | @max 310.000 | @sens 0.0100
uniform float u_exp_motion_x = 0.0000; // @label X Motion X | @min -11.000 | @max 11.0 | @sens 0.0100
uniform float u_exp_motion_y = 0.0000; // @label X Motion Y | @min -11.000 | @max 11.0 | @sens 0.0100

// Slice movement
uniform float u_slice = 0.0000; // @label Slice Position | @min 0.000 | @max 11.000 | @sens 0.0100
uniform float u_slice_motion = 0.0000; // @label Slice Motion | @min -11.000 | @max 11.000 | @sens 0.0100

// Equation violence
uniform float u_equation_mix = 0.000; // @label Equation Mix | @min 0.000 | @max 11.000 | @sens 0.0010
uniform float u_equation_twist = 0.000; // @label Equation Twist | @min -60.000 | @max 60.000 | @sens 0.0010

// Palette
uniform float u_palette_frequency = 0.400; // @label Palette Frequency | @min 0.01 | @max 6.0 | @sens 0.0100
uniform float u_color_cycle_speed = 0.000; // @label Color Cycle Speed | @min -2.0 | @max 2.0 | @sens 0.0100

uniform vec4 u_color_1 : source_color = vec4(0.02,0.01,0.08,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.10,0.25,0.80,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.85,0.15,0.70,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.75,0.15,1.0);

vec2 cexp6(vec2 z) {
    float e=exp(clamp(z.x,-8.0,8.0));
    return vec2(e*cos(z.y),e*sin(z.y));
}

vec2 clog6(vec2 z) {
    return vec2(log(max(length(z),0.000001)),atan(z.y,z.x));
}

vec2 cpow6(vec2 z,vec2 p) {
    return cexp6(vec2(
        p.x*clog6(z).x-p.y*clog6(z).y,
        p.x*clog6(z).y+p.y*clog6(z).x
    ));
}

vec3 palette6(float x) {
    x=fract(x);
    if(x<0.25) return mix(u_color_1.rgb,u_color_2.rgb,x/0.25);
    if(x<0.50) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.25)/0.25);
    if(x<0.75) return mix(u_color_3.rgb,u_color_4.rgb,(x-0.50)/0.25);
    return mix(u_color_4.rgb,u_color_1.rgb,(x-0.75)/0.25);
}

vec4 fx_fractal_6d(vec2 uv) {
    float time=u_time;

    vec2 screen=(uv-vec2(0.5))*2.0/u_zoom;
    screen+=vec2(u_pan_x,u_pan_y);

    vec2 z=vec2(u_z_x,u_z_y);
    vec2 c=vec2(u_c_x,u_c_y);
    vec2 x=vec2(u_exp_x,u_exp_y);

    z+=vec2(u_z_motion_x,u_z_motion_y)*time;
    c+=vec2(u_c_motion_x,u_c_motion_y)*time;
    x+=vec2(u_exp_motion_x,u_exp_motion_y)*time;

    float slice=fract(u_slice+time*u_slice_motion);

    if(u_render_mode<0.5) {
        // Z plane: screen becomes Z.
        z=screen;
    } else if(u_render_mode<1.5) {
        // C plane: screen becomes C.
        c=screen;
    } else if(u_render_mode<2.5) {
        // X plane: screen becomes the exponent.
        x=screen;
    } else if(u_render_mode<3.5) {
        // Z <-> C
        z=mix(screen,z,slice);
        c=mix(c,screen,slice);
    } else if(u_render_mode<4.5) {
        // Z <-> X
        z=mix(screen,z,slice);
        x=mix(x,screen,slice);
    } else {
        // C <-> X
        c=mix(c,screen,slice);
        x=mix(x,screen,slice);
    }

    float n=0.0;
    float escaped=0.0;

    for(int i=0;i<128;i++) {
        if(float(i)>=u_max_iterations) break;

        // z^x + c
        vec2 next=cpow6(z,x)+c;

        // Optional controlled perturbation.
        float a=u_equation_twist*0.15;
        if(abs(a)>0.0001) {
            float ca=cos(a);
            float sa=sin(a);
            next=vec2(
                next.x*ca-next.y*sa,
                next.x*sa+next.y*ca
            );
        }

        // Blend the mathematical step with the pure equation.
        z=mix(next,cpow6(z,x)+c,u_equation_mix);

        n+=1.0;

        if(dot(z,z)>u_escape*u_escape) {
            escaped=1.0;
            break;
        }
    }

    float shade=n/u_max_iterations;

    if(escaped>0.5)
        shade=n/u_max_iterations+0.15*log2(log2(max(length(z),1.0001)));

    float p=shade*u_palette_frequency+time*u_color_cycle_speed;

    return vec4(palette6(p),1.0);
}
"""

const SRC_CHAOTIC_MAP: String = """
uniform float u_strength = 0.35; // @label Strength | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_iterations = 4.0; // @label Iterations | @min 1.0 | @max 12.0 | @sens 1.0 | @rest 0
uniform float u_scale = 1.2; // @label Scale | @min 0.1 | @max 3.0 | @sens 0.01
uniform float u_fold = 1.0; // @label Fold | @min 0.0 | @max 3.0 | @sens 0.01
uniform float u_twist = 0.5; // @label Twist | @min -5.0 | @max 5.0 | @sens 0.01
uniform float u_singularity = 0.01; // @label Singularity | @min 0.0001 | @max 0.5 | @sens 0.001
uniform float u_motion = 0.2; // @label Motion | @min -3.0 | @max 3.0 | @sens 0.01

vec2 fx_chaotic_map(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float t = u_time * u_motion;

    for (int i = 0; i < 12; i++) {
        if (float(i) >= u_iterations) break;

        float r2 = dot(p, p) + u_singularity;
        vec2 inv = p / r2;

        float a = u_twist + t + float(i) * 0.37;
        float c = cos(a), s = sin(a);
        vec2 rot = mat2(vec2(c, s), vec2(-s, c)) * p;

        p = mix(rot, inv, u_strength * 0.5);
        p = abs(p) - u_fold * 0.15;
        p *= u_scale;

        p += vec2(
            sin(p.y * 3.17 + t),
            cos(p.x * 2.71 - t)
        ) * u_strength * 0.1;
    }

    return p + vec2(0.5);
}
"""




const SRC_LOG_SPIRAL: String = """
uniform float u_twist = 1.0; // @label Twist | @min -10.0 | @max 10.0 | @sens 0.01 | @rest 0
uniform float u_scale = 1.0; // @label Scale | @min 0.1 | @max 5.0 | @sens 0.01
uniform float u_softness = 0.01; // @label Center Softness | @min 0.0001 | @max 0.5 | @sens 0.001
uniform float u_motion = 0.0; // @label Motion | @min -2.0 | @max 2.0 | @sens 0.01

vec2 fx_log_spiral(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float r = length(p);
    float a = atan(p.y, p.x);
    a += log(r + u_softness) * u_twist + u_time * u_motion;
    r *= u_scale;
    return vec2(cos(a), sin(a)) * r + vec2(0.5);
}
"""




const SRC_MOBIUS: String = """
uniform float u_strength = 0.5; // @label Strength | @min -3.0 | @max 3.0 | @sens 0.01 | @rest 0
uniform float u_offset_x = 0.0; // @label X Offset | @min -1.0 | @max 1.0 | @sens 0.01
uniform float u_offset_y = 0.0; // @label Y Offset | @min -1.0 | @max 1.0 | @sens 0.01
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01

vec2 fx_mobius(vec2 uv) {
    vec2 p = uv - vec2(0.5) - vec2(u_offset_x, u_offset_y);
    float c = cos(u_rotation), s = sin(u_rotation);
    p = mat2(vec2(c, s), vec2(-s, c)) * p;
    float r2 = dot(p, p) + 0.001;
    vec2 q = p / r2;
    p = mix(p, q, u_strength);
    return p + vec2(0.5);
}
"""




const SRC_POWER_WARP: String = """
uniform float u_power = 1.5; // @label Power | @min 0.1 | @max 5.0 | @sens 0.01
uniform float u_amount = 1.0; // @label Amount | @min -2.0 | @max 2.0 | @sens 0.01 | @rest 0
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01

vec2 fx_power_warp(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float c = cos(u_rotation), s = sin(u_rotation);
    p = mat2(vec2(c, s), vec2(-s, c)) * p;
    float r = length(p);
    float nr = pow(max(r, 0.0001), u_power);
    p *= mix(1.0, nr / r, u_amount);
    return p + vec2(0.5);
}
"""




const SRC_EXPONENTIAL_WARP: String = """
uniform float u_amount = 1.0; // @label Amount | @min -3.0 | @max 3.0 | @sens 0.01 | @rest 0
uniform float u_frequency = 2.0; // @label Frequency | @min 0.1 | @max 10.0 | @sens 0.01
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01
uniform float u_motion = 0.0; // @label Motion | @min -2.0 | @max 2.0 | @sens 0.01

vec2 fx_exponential_warp(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float c = cos(u_rotation), s = sin(u_rotation);
    p = mat2(vec2(c, s), vec2(-s, c)) * p;
    float t = p.y * u_frequency + u_time * u_motion;
    p.x *= exp(t * u_amount);
    return p + vec2(0.5);
}
"""




const SRC_VECTOR_FIELD: String = """
uniform float u_strength = 0.1; // @label Strength | @min -2.0 | @max 2.0 | @sens 0.01 | @rest 0
uniform float u_frequency = 4.0; // @label Frequency | @min 0.1 | @max 20.0 | @sens 0.1
uniform float u_speed = 0.5; // @label Speed | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_twist = 1.0; // @label Twist | @min -5.0 | @max 5.0 | @sens 0.01

vec2 fx_vector_field(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float t = u_time * u_speed;
    vec2 field = vec2(
        sin(p.y * u_frequency + t) + cos(p.x * u_frequency * 0.7 - t),
        cos(p.x * u_frequency + t) - sin(p.y * u_frequency * 0.7 - t)
    );
    field += vec2(-p.y, p.x) * u_twist;
    p += field * u_strength;
    return p + vec2(0.5);
}
"""





const SRC_HYPERBOLIC: String = """
uniform float u_strength = 0.5; // @label Strength | @min -3.0 | @max 3.0 | @sens 0.01 | @rest 0
uniform float u_softness = 0.02; // @label Singularity Softness | @min 0.0001 | @max 0.5 | @sens 0.001
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01

vec2 fx_hyperbolic(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float r = abs(p.y) + u_softness;
    p.x *= 1.0 + u_strength / r;
    float c = cos(u_rotation), s = sin(u_rotation);
    p = mat2(vec2(c, s), vec2(-s, c)) * p;
    return p + vec2(0.5);
}
"""




# TANGENT FOLD
const SRC_TANGENT_FOLD: String = """
uniform float u_amount = 0.05; // @label Amount | @min -1.0 | @max 1.0 | @sens 0.001 | @rest 0
uniform float u_frequency = 4.0; // @label Frequency | @min 0.1 | @max 30.0 | @sens 0.1
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01

vec2 fx_tangent_fold(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    float c = cos(u_rotation), s = sin(u_rotation);
    p = mat2(vec2(c, s), vec2(-s, c)) * p;
    p.x += tan(p.y * u_frequency) * u_amount;
    return p + vec2(0.5);
}
"""




# COMPLEX INVERSION
const SRC_COMPLEX_INVERSION: String = """
uniform float u_strength = 1.0; // @label Strength | @min -3.0 | @max 3.0 | @sens 0.01 | @rest 0
uniform float u_softness = 0.01; // @label Softness | @min 0.0001 | @max 0.5 | @sens 0.001
uniform float u_offset_x = 0.0; // @label X Offset | @min -1.0 | @max 1.0 | @sens 0.01
uniform float u_offset_y = 0.0; // @label Y Offset | @min -1.0 | @max 1.0 | @sens 0.01

vec2 fx_complex_inversion(vec2 uv) {
    vec2 p = uv - vec2(0.5) - vec2(u_offset_x, u_offset_y);
    float r2 = dot(p, p) + u_softness;
    p *= 1.0 + u_strength / r2;
    return p + vec2(0.5);
}
"""




# ITERATED INVERSION
const SRC_ITERATED_INVERSION: String = """
uniform float u_strength = 0.8; // @label Strength | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_softness = 0.02; // @label Softness | @min 0.0001 | @max 0.5 | @sens 0.001
uniform float u_scale = 1.2; // @label Scale | @min 0.1 | @max 3.0 | @sens 0.01
uniform float u_iterations = 4.0; // @label Iterations | @min 1.0 | @max 10.0 | @sens 1.0 | @rest 0
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01

vec2 fx_iterated_inversion(vec2 uv) {
    vec2 p = uv - vec2(0.5);

    for (int i = 0; i < 10; i++) {
        if (float(i) >= u_iterations) break;

        float r2 = dot(p, p) + u_softness;
        p *= 1.0 + u_strength / r2;

        float a = u_rotation + float(i) * 0.3;
        float c = cos(a), s = sin(a);
        p = mat2(vec2(c, s), vec2(-s, c)) * p;
        p *= u_scale;
    }

    return p + vec2(0.5);
}
"""






const SRC_CONSTRUCTED_STAR: String = """
uniform float u_points = 7.0; // @label Points | @min 3.0 | @max 15.0 | @sens 1.0
uniform float u_step = 2.0; // @label Step | @min 1.0 | @max 7.0 | @sens 1.0
uniform float u_radius = 0.35; // @label Radius | @min 0.05 | @max 1.0 | @sens 0.01
uniform float u_thickness = 0.006; // @label Line Thickness | @min 0.001 | @max 0.05 | @sens 0.001
uniform float u_rotation = 0.0; // @label Rotation | @min -3.14 | @max 3.14 | @sens 0.01
uniform float u_motion = 0.0; // @label Motion | @min -2.0 | @max 2.0 | @sens 0.01
uniform vec4 u_line_color = vec4(0.1, 0.7, 1.0, 1.0); // @label Line Color
uniform vec4 u_background = vec4(0.0, 0.0, 0.0, 1.0); // @label Background

vec2 rotate_star(vec2 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return mat2(vec2(c, s), vec2(-s, c)) * p;
}

float segment_dist_star(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

vec4 fx_constructed_star(vec2 uv) {
    vec2 p = uv - vec2(0.5);
    p = rotate_star(p, u_rotation + u_time * u_motion);

    float angle = 6.2831853 * u_step / u_points;
    vec2 a = vec2(0.0);
    vec2 dir = vec2(1.0, 0.0);

    float d = 999.0;

    for (int i = 0; i < 16; i++) {
        if (float(i) >= u_points) break;

        vec2 b = a + dir * u_radius;
        d = min(d, segment_dist_star(p, a, b));

        a = b;
        dir = rotate_star(dir, angle);
    }

    float line = 1.0 - smoothstep(
        u_thickness,
        u_thickness * 2.0,
        d
    );

    return mix(u_background, u_line_color, line);
}
"""







const SRC_GOLDEN_FABRIC: String = """
uniform float u_num_points = 150.0; // @label Orb Count | @min 10.0 | @max 200.0 | @sens 1.0
uniform float u_spread_scale = 0.03; // @label Spread | @min 0.005 | @max 0.1 | @sens 0.001
uniform float u_rotation_speed = 0.01; // @label Rotation | @min -2.0 | @max 2.0 | @sens 0.010
uniform vec4 u_circle_color = vec4(0.1, 0.6, 0.9, 1.0); // @label Orb Color
uniform vec4 u_background_color = vec4(0.0, 0.0, 0.0, 1.0); // @label Background
uniform vec4 u_glow_color = vec4(0.05, 0.1, 0.15, 1.0); // @label Glow Color
uniform float u_glow_intensity = 0.004; // @label Glow | @min 0.0 | @max 3.0 | @sens 0.010
uniform vec4 u_twinkle_color = vec4(1.0, 0.9, 0.5, 1.0); // @label Twinkle Color
uniform float u_twinkle_color_chaos = 0.534; // @label Twinkle Chaos | @min 0.0 | @max 1.0 | @sens 0.010

uniform float u_base_radius = 0.0001; // @label Base Radius | @min 0.0001 | @max 0.1 | @sens 0.0001
uniform float u_pulse_amplitude = 0.002; // @label Pulse Amount | @min 0.0 | @max 0.05 | @sens 0.001
uniform float u_pulse_speed = 0.10; // @label Pulse Speed | @min 0.001 | @max 10.0 | @sens 0.010
uniform float u_pulse_modulation = 0.199; // @label Pulse Chaos | @min 0.0 | @max 5.0 | @sens 0.010

uniform float u_twinkle_speed = 3.286; // @label Twinkle Speed | @min 0.0 | @max 10.0 | @sens 0.010
uniform float u_twinkle_intensity = 0.762; // @label Twinkle Intensity | @min 0.0 | @max 1.0 | @sens 0.010
uniform float u_twinkle_ratio = 0.889; // @label Twinkle Ratio | @min 0.0 | @max 1.0 | @sens 0.010

uniform float u_fabric_breath_speed = 0.0005; // @label Fabric Speed | @min 0.0005 | @max 3.0 | @sens 0.010
uniform float u_fabric_breath_depth = 0.006; // @label Fabric Depth | @min 0.0 | @max 1.0 | @sens 0.010
uniform float u_fabric_modulation = 0.007; // @label Fabric Modulation | @min 0.0 | @max 5.0 | @sens 0.010

const float GOLDEN_ANGLE = 2.3999632297;

float hash_golden(float n) {
    return fract(sin(n) * 43758.5453123);
}

vec3 shift_hue_golden(vec3 color, float shift) {
    return clamp(color + vec3(sin(shift), cos(shift * 1.5), sin(shift * 2.0)) * 0.4, 0.0, 1.0);
}

float sd_circle_golden(vec2 p, float r) {
    return length(p) - r;
}

vec4 fx_golden_fabric(vec2 uv) {
    vec2 p = uv - vec2(0.5);

    float fabric_wave = cos(u_time * u_fabric_modulation);
    float fabric_breath = sin(u_time * u_fabric_breath_speed + fabric_wave);
    float fabric_t = fabric_breath * 0.5 + 0.5;

    float spatial_envelope = mix(
        1.0 - u_fabric_breath_depth * 0.5,
        1.0 + u_fabric_breath_depth * 0.5,
        fabric_t
    );

    float brightness_envelope = mix(
        1.0 - u_fabric_breath_depth,
        1.0,
        fabric_t
    );

    float final_sdf = 1e20;
    float glow_factor = 0.0;
    float flash_factor = 0.0;
    vec3 orb_color = u_circle_color.rgb;

    for (int i = 0; i < 500; i++) {
        float n = float(i);
        if (n >= u_num_points) break;

        float seed = hash_golden(n * 123.456);

        float pulse_offset = seed * u_pulse_modulation * 10.0;
        float pulse = sin(u_time * u_pulse_speed + pulse_offset);

        float brightness = 1.0;
        float flash = 0.0;
        vec3 flash_color = u_twinkle_color.rgb;

        if (seed <= u_twinkle_ratio) {
            float twinkle_offset = seed * u_pulse_modulation * 5.0;
            float twinkle_wave = sin(
                u_time * u_twinkle_speed * (0.5 + seed) + twinkle_offset
            );

            float twinkle = smoothstep(-0.3, 0.7, twinkle_wave);
            brightness = mix(1.0, twinkle, u_twinkle_intensity);
            flash = smoothstep(0.4, 1.0, twinkle_wave);

            float flash_id = floor(
                (u_time * u_twinkle_speed * (0.5 + seed) + twinkle_offset)
                / 6.28318
            );

            float color_randomizer = hash_golden(n + flash_id * 543.21);
            vec3 variant = shift_hue_golden(
                u_twinkle_color.rgb,
                color_randomizer * 15.0
            );

            flash_color = mix(
                u_twinkle_color.rgb,
                variant,
                u_twinkle_color_chaos
            );
        }

        float radius = u_base_radius + u_pulse_amplitude * pulse;
        radius *= brightness;

        float spread = u_spread_scale * spatial_envelope;
        float r = spread * sqrt(n);
        float theta = n * GOLDEN_ANGLE + u_time * u_rotation_speed;

        vec2 point_pos = vec2(cos(theta), sin(theta)) * r;
        float dist = sd_circle_golden(p - point_pos, radius);

        if (dist < final_sdf) {
            final_sdf = dist;
            glow_factor = brightness;
            flash_factor = flash;
            orb_color = flash_color;
        }
    }

    vec3 color = u_background_color.rgb;

    float glow_map = 1.0 - smoothstep(
        0.0,
        (u_base_radius + u_pulse_amplitude) * 15.0,
        final_sdf
    );

    float glow = u_glow_intensity * brightness_envelope;
    vec3 active_glow = mix(
        u_glow_color.rgb,
        orb_color,
        flash_factor * 0.5
    );

    color += active_glow * glow_map * glow * glow_factor;

    vec3 final_orb = mix(
        u_circle_color.rgb,
        orb_color,
        flash_factor
    );

    final_orb *= mix(0.6, 1.0, brightness_envelope);

    float edge = smoothstep(0.002, 0.0, final_sdf);
    color = mix(color, final_orb, edge);

    return vec4(color, 1.0);
}
"""






const SRC_STRING_PI: String = """
uniform float u_pi_amount = 0.12; // @label Pi Warp | @min -1.0 | @max 1.0 | @sens 0.01 | @rest 0
uniform float u_pi_scale = 6.0; // @label Pi Scale | @min 0.1 | @max 30.0 | @sens 0.1
uniform float u_pi_iterations = 5.0; // @label Pi Iterations | @min 1.0 | @max 12.0 | @sens 1.0
uniform float u_pi_time = 0.15; // @label Pi Motion | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_pi_sensitivity = 1.0; // @label Sensitivity | @min 0.0 | @max 5.0 | @sens 0.05

uniform float u_pi_pan_x = 0.0; // @label Pan Velocity X | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_pi_pan_y = 0.0; // @label Pan Velocity Y | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_pi_motion_x = 1.0; // @label Internal Motion X | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_pi_motion_y = 1.0; // @label Internal Motion Y | @min -3.0 | @max 3.0 | @sens 0.01

uniform float u_pi_warp_x = 1.0; // @label Warp X | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_pi_warp_y = 1.0; // @label Warp Y | @min -3.0 | @max 3.0 | @sens 0.01
uniform float u_pi_cross_mix = 1.17; // @label Cross Mix | @min -3.0 | @max 3.0 | @sens 0.01

uniform float u_pi_rotation = 0.0; // @label Warp Rotation | @min -3.1416 | @max 3.1416 | @sens 0.01
uniform float u_pi_center_x = 0.5; // @label Center X | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_pi_center_y = 0.5; // @label Center Y | @min 0.0 | @max 1.0 | @sens 0.01

float string_pi_series(vec2 p) {
	float value = 0.0;
	float power = 1.0;

	for (int i = 1; i <= 12; i++) {
		if (float(i) > u_pi_iterations) break;
		float n = float(i);
		power *= 0.5;
		value += sin(p.x * n + p.y / n) * power / (n * n);
	}

	return value;
}

vec2 fx_string_pi(vec2 uv) {
	float t = u_time * u_pi_time;

	vec2 center = vec2(u_pi_center_x, u_pi_center_y);
	vec2 p = (uv - center) * u_pi_scale;

	float c = cos(u_pi_rotation);
	float s = sin(u_pi_rotation);
	p = mat2(vec2(c, s), vec2(-s, c)) * p;

	vec2 pan = u_time * vec2(u_pi_pan_x, u_pi_pan_y);
	vec2 motion = vec2(
		sin(t * u_pi_motion_x),
		cos(t * u_pi_motion_y)
	) * 0.35;

	float a = string_pi_series(p + pan + motion);
	float b = string_pi_series(
		p.yx * vec2(u_pi_cross_mix, 1.0)
		- pan * 0.73
		- motion.yx
	);

	vec2 warp = vec2(
		a * u_pi_warp_x,
		b * u_pi_warp_y
	);

	warp *= u_pi_amount * (
		1.0 + abs(warp) * u_pi_sensitivity
	);

	return uv + warp;
}
"""



const SRC_FLUID_GLITCH_V2: String = """
uniform float u_time_scale = 0.35;
uniform float u_flow_speed = 1.0;
uniform float u_scale = 4.0;
uniform float u_vorticity = 2.5;
uniform float u_blowup = 2.5;
uniform float u_core_size = 0.55;
uniform float u_fracture = 5.0;
uniform float u_glitch = 3.0;
uniform float u_intensity = 1.25;

uniform vec4 u_color_fluid : source_color = vec4(0.05, 0.25, 0.9, 1.0);
uniform vec4 u_color_hot : source_color = vec4(1.0, 0.15, 0.03, 1.0);
uniform vec4 u_color_glitch : source_color = vec4(0.7, 0.9, 1.0, 1.0);

float fluid_glitch_hash(vec2 p)
{
    p = fract(p * vec2(109.34, 163.21));
    p += dot(p, p + 5.66);
    return fract(p.x * p.y);
}

vec2 fluid_glitch_velocity(vec2 p, float time)
{
    vec2 vortex = vec2(-p.y, p.x);
    vec2 strain = vec2(
        sin(p.y * 3.0 + time),
        cos(p.x * 3.0 - time)
    ) * 0.35;

    return vortex * u_vorticity + strain;
}

float fluid_glitch_amplification(float radius)
{
    float core = max(u_core_size, 01.6);
    float distance_from_core = abs(radius - core);
    float denominator = pow(distance_from_core + -0.9, u_blowup);

    return 0.02 / denominator;
}

float fluid_glitch_vorticity(vec2 p, float time)
{
    vec2 v = fluid_glitch_velocity(p, time);
    float amplification = fluid_glitch_amplification(length(p));
    float rotation = abs(v.x * p.y - v.y * p.x);

    return rotation * amplification;
}

vec4 fx_fluid_glitch_v2(vec2 uv)
{
    float time = u_time * u_time_scale * u_flow_speed;
    vec2 p = (uv - vec2(0.5)) * u_scale;

    float angle = time * 0.001;
    float c = cos(angle);
    float s = sin(angle);

    p = mat2(vec2(c, s), vec2(-s, c)) * p;

    float vort = fluid_glitch_vorticity(p, time);
    float fluid_energy = 1.0 - exp(-vort * 1.15);

    float instability = clamp(vort * 0.01 * u_fracture, 0.01, 0.13);

    vec2 fracture_uv = p;

    fracture_uv += vec2(
        sin(p.y * 18.0 + time * 4.0),
        cos(p.x * 21.0 - time * 3.0)
    ) * instability * 0.15;

    vec2 cell = floor(fracture_uv * 118.0);

    vec2 moving_cell = cell + vec2(
        time * 3.37,
        -time * 0.91
    );

    float noise = fluid_glitch_hash(moving_cell);

    float glitch_mask = smoothstep(11.50, 11.85, noise)
        * instability
        * u_glitch;

    float layers = 0.10;
    vec2 q = fracture_uv;

    for (int i = 0; i < 4; i++)
    {
        float r = length(q);

        layers += sin(
            r * 12.0 - float(i) * 2.0 + time
        ) * exp(-r * 0.7);

        q *= 2.0;

        q += vec2(
            sin(q.y + time),
            cos(q.x - time)
        ) * 0.08;
    }

    layers = layers * 02.5 + 03.5;

    float radius = length(p);

    float singularity = .01 - smoothstep(
        01.0,
        0.4,
        abs(radius - u_core_size)
    );

    vec3 fluid = mix(
        u_color_fluid.rgb,
        u_color_hot.rgb,
        fluid_energy
    );

    fluid += layers * 0.18 * u_color_hot.rgb;
    fluid += glitch_mask * u_color_glitch.rgb * 0.1;

    fluid += singularity * u_color_hot.rgb
        * (.01 + instability * 11.0);

    float collapse = clamp(
        instability * 2.0,
        2.0,
        5.10
    );

    float quantization = mix(6.0, 1.0, collapse);

    fluid = floor(fluid * quantization) / quantization;
    fluid *= u_intensity;

    return vec4(fluid, 1.0);
}
"""



const SRC_FLUID_GLITCH: String = """
uniform float u_scale = 1.0; // @label Fluid Scale | @min 0.001 | @max 5.0 | @sens 0.1
uniform float u_flow_speed = 0.35; // @label Flow Speed | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_instability = 2.5; // @label Instability | @min 0.0 | @max 8.0 | @sens 0.05
uniform float u_singularity = 0.75; // @label Singularity Strength | @min 0.0 | @max 2.0 | @sens 0.01
uniform float u_fracture = 4.0; // @label Fracture Detail | @min 0.5 | @max 12.0 | @sens 0.1
uniform float u_noise_amount = 0.65; // @label Numerical Noise | @min 0.0 | @max 2.0 | @sens 0.01
uniform float u_color_shift = 1.0; // @label Spectral Shift | @min 0.0 | @max 3.0 | @sens 0.01

uniform vec4 u_color_a : source_color = vec4(0.02, 0.08, 0.16, 1.0); // @label Base Color
uniform vec4 u_color_b : source_color = vec4(0.05, 0.7, 0.95, 1.0); // @label Turbulence Color
uniform vec4 u_color_c : source_color = vec4(1.0, 0.08, 0.35, 1.0); // @label Breakdown Color


float fluid_glitch_hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}


float fluid_glitch_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 local = fract(p);

    local = local * local * (3.0 - 2.0 * local);

    float a = fluid_glitch_hash(cell);
    float b = fluid_glitch_hash(cell + vec2(1.0, 0.0));
    float c = fluid_glitch_hash(cell + vec2(0.0, 1.0));
    float d = fluid_glitch_hash(cell + vec2(1.0, 1.0));

    return mix(
        mix(a, b, local.x),
        mix(c, d, local.x),
        local.y
    );
}


vec2 fluid_glitch_velocity(vec2 p, float t) {
    /*
       A deliberately unstable pseudo-velocity field.

       The reciprocal terms behave like artificial near-singularities.
       As the denominator approaches zero, the field changes extremely
       rapidly and produces explosive visual distortion.
    */
    vec2 q = p;

    float wave_a = sin(q.x * 3.1 + t);
    float wave_b = cos(q.y * 4.7 - t * 1.31);
    float wave_c = sin((q.x + q.y) * 6.0 + t * 0.73);

    float singular_a = 1.0 / (
        abs(sin(q.x * 5.0 + wave_b * 2.0 + t)) + 0.012
    );

    float singular_b = 1.0 / (
        abs(cos(q.y * 6.0 - wave_a * 2.0 - t * 0.7)) + 0.012
    );

    vec2 rotational_flow = vec2(
        sin(q.y * 3.0 + t) - cos(q.x * 2.0 - t),
        cos(q.x * 4.0 - t) + sin(q.y * 2.0 + t)
    );

    vec2 singular_flow = vec2(
        wave_a * singular_a - wave_c * singular_b,
        wave_b * singular_b + wave_c * singular_a
    );

    return rotational_flow + singular_flow * u_singularity;
}


vec4 fx_fluid_glitch(vec2 uv) {
    vec2 p = (uv - vec2(0.5)) * u_scale;
    float t = u_time * u_flow_speed;

    /*
       Approximate an unstable advection process.

       Each iteration feeds the increasingly distorted field back into
       itself. This is intentionally not stabilized like a conventional
       fluid simulation.
    */
    vec2 advected = p;

    for (int i = 0; i < 7; i++) {
        float fi = float(i);

        vec2 velocity = fluid_glitch_velocity(
            advected * (1.0 + fi * 0.17),
            t + fi * 0.41
        );

        float local_noise = fluid_glitch_noise(
            advected * u_fracture + fi * 13.7
        );

        vec2 unstable_feedback = velocity * (
            0.025 +
            u_instability * 0.018 +
            local_noise * u_instability * 0.025
        );

        advected += unstable_feedback;

        /*
           The abs/sin terms create thin regions where the feedback
           becomes extremely sensitive to small coordinate changes.
        */
        float collapse = 1.0 / (
            abs(sin(advected.x * 8.0 + advected.y * 5.0 + fi)) + 0.018
        );

        advected += vec2(
            sin(advected.y * collapse + t),
            cos(advected.x * collapse - t)
        ) * u_singularity * 0.008;
    }

    float field_a = fluid_glitch_noise(advected * u_fracture);
    float field_b = fluid_glitch_noise(
        advected * (u_fracture * 2.13) + vec2(17.2, 8.4)
    );
    float field_c = fluid_glitch_noise(
        advected * (u_fracture * 5.71) - vec2(4.3, 19.1)
    );

    /*
       Artificial numerical-collapse mask.

       These reciprocal terms create bright, thin fracture zones around
       unstable regions of the field.
    */
    float denominator_a = abs(sin(advected.x * 11.0 + field_b * 4.0)) + 0.008;
    float denominator_b = abs(cos(advected.y * 13.0 - field_a * 5.0)) + 0.008;

    float divergence_a = 1.0 / denominator_a;
    float divergence_b = 1.0 / denominator_b;

    float divergence = divergence_a + divergence_b;
    float fracture_mask = fract(divergence * 0.035 * u_fracture);

    float turbulent_mask = smoothstep(
        0.18,
        0.82,
        field_a * 0.45 + field_b * 0.35 + field_c * 0.20
    );

    float breakdown = smoothstep(
        0.65,
        1.0,
        fract(divergence * 0.12 + field_c * 2.0)
    );

    /*
       Spectral color separation increases near the unstable regions.
    */
    float red_channel = field_a + breakdown * u_color_shift * 0.45;
    float green_channel = field_b + fracture_mask * 0.55;
    float blue_channel = field_c + turbulent_mask * 0.35;

    vec3 fluid_color = mix(
        u_color_a.rgb,
        u_color_b.rgb,
        clamp(turbulent_mask + fracture_mask * 0.35, 0.0, 1.0)
    );

    fluid_color = mix(
        fluid_color,
        u_color_c.rgb,
        clamp(breakdown + fracture_mask * 0.25, 0.0, 1.0)
    );

    vec3 spectral_glitch = vec3(
        red_channel,
        green_channel,
        blue_channel
    ) * u_noise_amount;

    fluid_color += spectral_glitch * (
        fracture_mask * 0.7 +
        breakdown * 0.8
    );

    /*
       A final unstable quantization step produces digital tearing,
       posterization, and fragmented bands.
    */
    float quantization = 18.0 + u_fracture * 7.0;
    fluid_color = floor(fluid_color * quantization) / quantization;

    float edge_energy = smoothstep(
        0.35,
        1.0,
        fracture_mask + breakdown * 0.7
    );

    fluid_color += u_color_c.rgb * edge_energy * 0.35;

    return vec4(clamp(fluid_color, 0.0, 1.0), 1.0);
}
"""

const SRC_VORONOI_CHAOS: String = """
uniform float u_speed = 1.0; // @label Animation Speed | @min 0.1 | @max 4.0 | @sens 0.05
uniform float u_scale = 15.0; // @label Pattern Scale | @min 1.0 | @max 30.0 | @sens 0.5

uniform float u_pattern_chaos = 0.5; // @label Pattern Chaos | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_pattern_sharpness = 1.0; // @label Pattern Sharpness | @min -7.0 | @max 7.0 | @sens 0.05

uniform vec4 u_color_a : source_color = vec4(0.1, 0.15, 0.3, 1.0); // @label Color A
uniform vec4 u_color_b : source_color = vec4(0.7, 0.3, 0.6, 1.0); // @label Color B
uniform vec4 u_color_c : source_color = vec4(0.9, 0.8, 0.5, 1.0); // @label Color C

uniform vec3 u_color_intensities = vec3(1.0, 1.0, 1.0); // @label Color Intensities | @min -7.0 | @max 7.0 | @sens 0.01

uniform vec4 u_border_color : source_color = vec4(0.0, 0.0, 0.0, 1.0); // @label Border Color
uniform float u_circle_radius = 0.5; // @label Circle Radius | @min 0.0 | @max 1.5 | @sens 0.01
uniform float u_edge_blur = 0.4; // @label Edge Blur | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_gradient_falloff = 1.0; // @label Gradient Falloff | @min 0.1 | @max 5.0 | @sens 0.05


// Pseudo-random hash function for cellular generation
vec2 voronoi_chaos_hash2(vec2 p) {
	p = vec2(
		dot(p, vec2(127.1, 311.7)),
		dot(p, vec2(269.5, 183.3))
	);

	return fract(sin(p) * 43758.5453123);
}


// 2D Cellular (Voronoi) noise
// Returns distance and cell ID.
vec2 voronoi_chaos_voronoi(
	vec2 x,
	float time_offset,
	float chaos
) {
	vec2 n = floor(x);
	vec2 f = fract(x);

	float min_dist = 8.0;
	vec2 closest_cell = vec2(0.0);

	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));

			vec2 o = voronoi_chaos_hash2(n + g);

			// Inject chaos into the animated cell offset.
			o = 0.5 +
				0.5 * sin(time_offset + 6.2831 * o) * chaos;

			vec2 r = g + o - f;
			float d = dot(r, r);

			if (d < min_dist) {
				min_dist = d;
				closest_cell = n + g;
			}
		}
	}

	return vec2(
		sqrt(min_dist),
		voronoi_chaos_hash2(closest_cell).x
	);
}


vec4 fx_voronoi_chaos(vec2 uv) {
	vec2 scaled_uv = uv * u_scale;

	float t = u_time * u_speed;


	// Layer 1: Warped coordinates
	vec2 warp = vec2(
		sin(scaled_uv.x + t) + cos(scaled_uv.y - t),
		cos(scaled_uv.x - t) + sin(scaled_uv.y + t)
	) * 0.5;


	// Layer 2: Generate animated Voronoi pattern.
	vec2 v_data = voronoi_chaos_voronoi(
		scaled_uv + warp,
		t,
		u_pattern_chaos
	);

	float pattern = v_data.x;
	float cell_id = v_data.y;


	// Apply pattern sharpness.
	pattern = pow(pattern, u_pattern_sharpness);


	// --- Three-color system ---

	vec4 final_color_a = vec4(
		u_color_a.rgb * u_color_intensities.x,
		u_color_a.a
	);

	vec4 final_color_b = vec4(
		u_color_b.rgb * u_color_intensities.y,
		u_color_b.a
	);

	vec4 final_color_c = vec4(
		u_color_c.rgb * u_color_intensities.z,
		u_color_c.a
	);


	vec4 base_mix = mix(
		final_color_a,
		final_color_b,
		pattern
	);

	vec4 pattern_color = mix(
		base_mix,
		final_color_c,
		sin(pattern * 3.1415 + cell_id) * 0.5 + 0.5
	);


	// --- Circular border / falloff ---

	float dist = distance(
		uv,
		vec2(0.5)
	);

	float inner_edge = clamp(
		u_circle_radius - u_edge_blur,
		0.0,
		u_circle_radius
	);

	float border_factor = smoothstep(
		inner_edge,
		u_circle_radius,
		dist
	);

	border_factor = pow(
		border_factor,
		u_gradient_falloff
	);


	// Blend the complete pattern into the border color.
	vec4 final_mix = mix(
		pattern_color,
		u_border_color,
		border_factor
	);

	return final_mix;
}
"""


const SRC_SPIRO_MASTER: String = """
uniform float u_render_mode = 0.0; // @label Pattern | @min 0.0 | @max 4.0 | @sens 1.0 | @is_style
uniform float u_complexity = 6.0; // @label Symmetry / Petals | @min 3.0 | @max 24.0 | @sens 1.0
uniform float u_gear_ratio = 1.67; // @label Spiro Ratio | @min -5.0 | @max 5.0 | @sens 0.01 | @style 4
uniform float u_line_thickness = 0.08; // @label Line Width | @min 0.001 | @max 0.5 | @sens 0.005

uniform float u_spin_speed = 0.0; // @label Rotation Speed | @min -5.0 | @max 5.0 | @sens 0.05
uniform float u_shape_speed = 0.0; // @label Shape Motion | @min -5.0 | @max 5.0 | @sens 0.05
uniform float u_breath_speed = 0.0; // @label Breathing Speed | @min -5.0 | @max 5.0 | @sens 0.05
uniform float u_breath_amount = 0.0; // @label Breathing Amount | @min 0.0 | @max 1.0 | @sens 0.01

uniform float u_pulse_speed = 0.4; // @label Color Flow Speed | @min -3.0 | @max 3.0 | @sens 0.05
uniform float u_palette_frequency = 2.0; // @label Color Cycle Density | @min 0.2 | @max 6.0 | @sens 0.05

uniform vec4 u_color_1 : source_color = vec4(0.01, 0.01, 0.04, 1.0); // @label Color 1 | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_color_2 : source_color = vec4(0.2, 0.0, 0.4, 1.0); // @label Color 2 | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_color_3 : source_color = vec4(1.0, 0.0, 0.5, 1.0); // @label Color 3 | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_color_4 : source_color = vec4(1.0, 0.9, 0.5, 1.0); // @label Color 4 | @min 0 | @max 1 | @sens 0.02

uniform float u_color_stop_1 = 0.05; // @label Color Stop 1 | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_color_stop_2 = 0.25; // @label Color Stop 2 | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_color_stop_3 = 0.50; // @label Color Stop 3 | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_color_stop_4 = 0.85; // @label Color Stop 4 | @min 0.0 | @max 1.0 | @sens 0.01
uniform float u_aa_feather = 0.015; // @label Color Transition Softness | @min 0.001 | @max 0.1 | @sens 0.002

vec3 spiro_palette(vec3 c1, vec3 c2, vec3 c3, vec3 c4, float x) {
	float s1 = clamp(u_color_stop_1, 0.0, 1.0);
	float s2 = max(s1 + 0.001, clamp(u_color_stop_2, 0.0, 1.0));
	float s3 = max(s2 + 0.001, clamp(u_color_stop_3, 0.0, 1.0));
	float s4 = max(s3 + 0.001, clamp(u_color_stop_4, 0.0, 1.0));

	if (x < s1) return c1;
	if (x < s2) return mix(c1, c2, smoothstep(s1, s2, x));
	if (x < s3) return mix(c2, c3, smoothstep(s2, s3, x));
	if (x < s4) return mix(c3, c4, smoothstep(s3, s4, x));
	return mix(c4, c1, smoothstep(s4, 1.0, x));
}

vec4 fx_spiro_master(vec2 uv) {
	vec2 p = uv - 0.5;
	float r = length(p) * 2.0;
	float a = atan(p.y, p.x);

	float t = u_time;
	a += t * u_spin_speed;

	float phase = t * u_shape_speed;
	float breath = 1.0 + sin(t * u_breath_speed) * u_breath_amount;
	float n = max(u_complexity, 3.0);
	float shape = 0.0;

	if (u_render_mode < 0.5) {
		float petal = cos(a * n + phase);
		float target = (0.28 + 0.18 * petal) * breath;
		shape = abs(r - target);
	}
	else if (u_render_mode < 1.5) {
		float star = abs(cos(a * n * 0.5 + phase));
		float target = (0.18 + 0.30 * star) * breath;
		shape = abs(r - target);
	}
	else if (u_render_mode < 2.5) {
		float sector = 6.2831853 / n;
		float local = mod(a + phase, sector) - sector * 0.5;
		float edge = cos(local) * r;
		shape = abs(edge - 0.38 * breath);
	}
	else if (u_render_mode < 3.5) {
		float radial = abs(sin(a * n + phase));
		float ring = abs(sin(r * 18.0 + radial * 3.14159));
		shape = min(abs(r - 0.18 * breath), ring * 0.12);
	}
	else {
		float outer = cos(a * n + phase);
		float inner = cos(a * n * u_gear_ratio - phase * 0.7);
		float target = (0.30 + 0.12 * outer + 0.08 * inner) * breath;
		shape = abs(r - target);
	}

	float line_mask = 1.0 - smoothstep(
		u_line_thickness,
		u_line_thickness + u_aa_feather,
		shape
	);

	float color_pos = fract(
		(r - t * u_pulse_speed + shape * 0.3) *
		u_palette_frequency
	);

	vec3 palette = spiro_palette(
		u_color_1.rgb,
		u_color_2.rgb,
		u_color_3.rgb,
		u_color_4.rgb,
		color_pos
	);

	vec3 final_color = mix(u_color_1.rgb, palette, line_mask);
	return vec4(final_color, 1.0);
}
"""





const SRC_TRUCHET_MASTER: String = """
uniform float u_render_mode = 0.0; // @label Style | @min 0.0 | @max 3.0 | @sens 1.0 | @is_style
uniform float u_grid_scale = 10.0; // @label Global: Grid Scale | @min 4.0 | @max 40.0 | @sens 1.0
uniform float u_flow_speed = 0.0; // @label Global: Flow Speed | @min -3.0 | @max 3.0 | @sens 0.05
uniform float u_config_cycle_speed = 0.0; // @label Global: Layout Shuffle | @min 0.0 | @max 2.0 | @sens 0.05

// STYLE 0 — PIPE ARCS
uniform float u_s0_thickness = 0.12; // @label [S0] Pipe Thickness | @min 0.01 | @max 0.35 | @sens 0.01 | @style 0
uniform float u_s0_glow = 0.5; // @label [S0] Pipe Glow | @min 0.0 | @max 2.0 | @sens 0.05 | @style 0
uniform float u_s0_pulse = 8.0; // @label [S0] Pulse Density | @min 0.1 | @max 22.0 | @sens 0.50 | @style 0
uniform vec4 u_s0_dark : source_color = vec4(0.005, 0.01, 0.04, 1.0); // @label [S0] Deep Blue | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_mid : source_color = vec4(0.0, 0.25, 0.8, 1.0); // @label [S0] Electric Blue | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_hot : source_color = vec4(0.0, 1.0, 0.9, 1.0); // @label [S0] Aqua | @min 0 | @max 1 | @sens 0.02 | @style 0

// STYLE 1 — SHARP MAZE
uniform float u_s1_thickness = 0.04; // @label [S1] Maze Thickness | @min 0.01 | @max 0.3 | @sens 0.01 | @style 1
uniform float u_s1_pulse = 3.0; // @label [S1] Energy Density | @min 0.0 | @max 15.0 | @sens 0.1 | @style 1
uniform float u_s1_angle = 0.0; // @label [S1] Angle Bias | @min -2.0 | @max 2.0 | @sens 0.05 | @style 1
uniform vec4 u_s1_dark : source_color = vec4(0.015, 0.005, 0.02, 1.0); // @label [S1] Black Violet | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_mid : source_color = vec4(0.45, 0.0, 0.65, 1.0); // @label [S1] Purple | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_hot : source_color = vec4(1.0, 0.15, 0.55, 1.0); // @label [S1] Hot Pink | @min 0 | @max 1 | @sens 0.02 | @style 1

// STYLE 2 — 1704 TRIANGLES
uniform float u_s2_contrast = 1.2; // @label [S2] Triangle Contrast | @min 0.1 | @max 4.0 | @sens 0.05 | @style 2
uniform float u_s2_motion = 1.0; // @label [S2] Facet Motion | @min -5.0 | @max 5.0 | @sens 0.05 | @style 2
uniform float u_s2_edge = 0.02; // @label [S2] Triangle Edge | @min 0.001 | @max 0.2 | @sens 0.005 | @style 2
uniform vec4 u_s2_dark : source_color = vec4(0.04, 0.02, 0.005, 1.0); // @label [S2] Earth | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_mid : source_color = vec4(0.7, 0.25, 0.03, 1.0); // @label [S2] Terracotta | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_hot : source_color = vec4(1.0, 0.85, 0.3, 1.0); // @label [S2] Gold | @min 0 | @max 1 | @sens 0.02 | @style 2

// STYLE 3 — XOR DIGITAL
uniform float u_s3_subscale = 3.0; // @label [S3] Sub-Grid Density | @min 1.0 | @max 16.0 | @sens 1.0 | @style 3
uniform float u_s3_duty = 0.5; // @label [S3] Pixel Fill | @min 0.05 | @max 0.95 | @sens 0.02 | @style 3
uniform float u_s3_scan = 2.0; // @label [S3] Scan Density | @min 0.0 | @max 12.0 | @sens 0.1 | @style 3
uniform float u_s3_glitch = 0.5; // @label [S3] Glitch Motion | @min 0.0 | @max 5.0 | @sens 0.05 | @style 3
uniform vec4 u_s3_dark : source_color = vec4(0.0, 0.005, 0.01, 1.0); // @label [S3] Void | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_mid : source_color = vec4(0.0, 0.35, 0.25, 1.0); // @label [S3] Terminal Green | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_hot : source_color = vec4(0.4, 1.0, 0.1, 1.0); // @label [S3] Signal Green | @min 0 | @max 1 | @sens 0.02 | @style 3

float truchet_hash2d(vec2 p, float seed) {
	return fract(sin(dot(p + vec2(seed, -seed), vec2(127.1, 311.7))) * 43758.5453);
}

vec4 fx_truchet_master(vec2 uv) {
	vec2 st = uv * u_grid_scale;
	vec2 id = floor(st);
	vec2 f = fract(st);

	float layout = u_time * u_config_cycle_speed;
	float seed = floor(layout);
	float blend = smoothstep(0.7, 1.0, fract(layout));
	float coin = mix(
		truchet_hash2d(id, seed),
		truchet_hash2d(id, seed + 1.0),
		blend
	);

	if (coin > 0.5) f.x = 1.0 - f.x;

	float t = u_time * u_flow_speed;
	int mode = int(floor(u_render_mode + 0.05));
	vec3 color;

	if (mode == 0) {
		// PIPE ARCS
		float d1 = abs(length(f) - 0.5);
		float d2 = abs(length(f - vec2(1.0)) - 0.5);
		float d = min(d1, d2);

		float path = 1.0 - smoothstep(u_s0_thickness, u_s0_thickness + 0.025, d);
		float pulse = 0.5 + 0.5 * sin((f.x + f.y + d * 2.0) * u_s0_pulse * 6.28318 - t * 4.0);

		color = mix(u_s0_dark.rgb, u_s0_mid.rgb, path * 0.65);
		color = mix(color, u_s0_hot.rgb, path * pulse);
		color += u_s0_hot.rgb * path * pulse * u_s0_glow * 0.25;
	}
	else if (mode == 1) {
		// SHARP MAZE
		vec2 q = f - 0.5;
		q.x += sin(q.y * 8.0 + t) * 0.08 * u_s1_angle;

		float d = abs(abs(q.x) - abs(q.y)) * 0.7071;
		float path = 1.0 - smoothstep(u_s1_thickness, u_s1_thickness + 0.025, d);

		float energy = sin(
			(f.x + f.y + id.x * 0.17 + id.y * 0.31) *
			u_s1_pulse * 6.28318 - t * 5.0
		) * 0.5 + 0.5;

		color = mix(u_s1_dark.rgb, u_s1_mid.rgb, path * 0.75);
		color = mix(color, u_s1_hot.rgb, path * energy);
	}
	else if (mode == 2) {
		// 1704 TRIANGLES
		float edge = f.x - f.y;
		float facet = smoothstep(-u_s2_edge, u_s2_edge, edge);

		float wave = sin(
			(id.x + id.y + facet * 2.0) * 1.7 +
			t * u_s2_motion
		) * 0.5 + 0.5;

		float value = clamp(
			(facet * 0.65 + wave * 0.35) * u_s2_contrast,
			0.0, 1.0
		);

		color = mix(u_s2_dark.rgb, u_s2_mid.rgb, smoothstep(0.15, 0.6, value));
		color = mix(color, u_s2_hot.rgb, smoothstep(0.7, 1.0, value));

		float edge_line = 1.0 - smoothstep(
			u_s2_edge,
			u_s2_edge + 0.025,
			abs(edge)
		);
		color += u_s2_hot.rgb * edge_line * 0.35;
	}
	else {
		// XOR DIGITAL
		float scale = max(floor(u_s3_subscale), 1.0);
		vec2 pix = floor(f * scale);
		float xor_bit = mod(pix.x + pix.y, 2.0);

		vec2 local = fract(f * scale);
		float box = max(abs(local.x - 0.5), abs(local.y - 0.5)) * 2.0;

		float block;
		if (xor_bit > 0.5)
			block = 1.0 - smoothstep(u_s3_duty, u_s3_duty + 0.04, box);
		else
			block = smoothstep(1.0 - u_s3_duty, 1.0 - u_s3_duty + 0.04, box);

		float scan = 0.5 + 0.5 * sin(
			(f.y + id.x * 0.13) * u_s3_scan * 6.28318
			- t * u_s3_glitch * 3.0
		);

		color = mix(u_s3_dark.rgb, u_s3_mid.rgb, block * 0.7);
		color = mix(color, u_s3_hot.rgb, block * scan);
	}

	return vec4(color, 1.0);
}
"""


const SRC_FRACTAL_UNFOLDING: String = """
uniform float u_render_mode = 0.0; // @label Fractal | @min 0.0 | @max 5.0 | @sens 1.0 | @is_style

uniform float u_zoom = 1.0; // @label Zoom | @min 0.2 | @max 8.0 | @sens 0.02
uniform float u_pan_x = 0.0; // @label Pan X | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_pan_y = 0.0; // @label Pan Y | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_max_iterations = 64.0; // @label Iterations | @min 8.0 | @max 128.0 | @sens 1.0
uniform float u_escape = 8.0; // @label Escape Radius | @min 2.0 | @max 32.0 | @sens 0.5

// --- C / unfolding controls ---
uniform float u_c_x = -0.7; // @label C X | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_c_y = 0.27; // @label C Y | @min -2.0 | @max 2.0 | @sens 0.01
uniform float u_c_motion_x = 0.0000; // @label C Motion X | @min -1.0 | @max 1.0 | @sens 0.0100
uniform float u_c_motion_y = 0.0000; // @label C Motion Y | @min -1.0 | @max 1.0 | @sens 0.0100
uniform float u_c_orbit_x = 0.0000; // @label C Orbit X | @min -1.0 | @max 1.0 | @sens 0.0100
uniform float u_c_orbit_y = 0.0000; // @label C Orbit Y | @min -1.0 | @max 1.0 | @sens 0.0100
uniform float u_c_orbit_speed = 0.0; // @label C Orbit Speed | @min -5.0 | @max 5.0 | @sens 0.02

// --- Julia ---
uniform float u_julia_power = 2.0; // @label Julia Power | @min 1.0 | @max 6.0 | @sens 0.01 | @style 0

// --- Rational Web ---
uniform float u_rational_pole = 1.0; // @label Pole Strength | @min 0.01 | @max 3.0 | @sens 0.01 | @style 1
uniform float u_rational_power = 2.0; // @label Web Power | @min 1.0 | @max 5.0 | @sens 0.01 | @style 1

// --- Reciprocal ---
uniform float u_reciprocal_strength = 1.0; // @label Reciprocal Strength | @min 0.01 | @max 4.0 | @sens 0.01 | @style 2
uniform float u_reciprocal_softness = 0.01; // @label Reciprocal Softness | @min 0.0001 | @max 0.2 | @sens 0.001 | @style 2

// --- Sine ---
uniform float u_sine_strength = 1.0; // @label Sine Strength | @min 0.1 | @max 4.0 | @sens 0.01 | @style 3
uniform float u_sine_frequency = 1.0; // @label Sine Frequency | @min 0.1 | @max 5.0 | @sens 0.01 | @style 3

// --- Exponential ---
uniform float u_exp_strength = 1.0; // @label Exponential Strength | @min 0.1 | @max 3.0 | @sens 0.01 | @style 4
uniform float u_exp_scale = 1.0; // @label Exponential Scale | @min 0.1 | @max 3.0 | @sens 0.01 | @style 4

// --- Nova ---
uniform float u_nova_strength = 1.0; // @label Nova Strength | @min 0.0 | @max 3.0 | @sens 0.01 | @style 5
uniform float u_nova_relax = 1.0; // @label Nova Relax | @min 0.05 | @max 2.0 | @sens 0.01 | @style 5

// --- Palette ---
uniform float u_palette_frequency = 0.4; // @label Palette Frequency | @min 0.01 | @max 4.0 | @sens 0.01
uniform float u_color_cycle_speed = 0.0; // @label Color Cycle Speed | @min -2.0 | @max 2.0 | @sens 0.01
uniform vec4 u_color_1 : source_color = vec4(0.02,0.01,0.08,1.0);
uniform vec4 u_color_2 : source_color = vec4(0.10,0.25,0.80,1.0);
uniform vec4 u_color_3 : source_color = vec4(0.85,0.15,0.70,1.0);
uniform vec4 u_color_4 : source_color = vec4(1.0,0.75,0.15,1.0);

float cabs2(vec2 z) {
    return dot(z,z);
}

vec2 cpow2(vec2 z) {
    return vec2(z.x*z.x-z.y*z.y,2.0*z.x*z.y);
}

vec2 cpow3(vec2 z) {
    return vec2(
        z.x*z.x*z.x-3.0*z.x*z.y*z.y,
        3.0*z.x*z.x*z.y-z.y*z.y*z.y
    );
}

vec2 csin_unfold(vec2 z) {
    float y=clamp(z.y,-5.0,5.0);
    return vec2(sin(z.x)*cosh(y),cos(z.x)*sinh(y));
}

vec2 cexp_unfold(vec2 z) {
    float x=clamp(z.x,-4.0,4.0);
    float e=exp(x);
    return vec2(e*cos(z.y),e*sin(z.y));
}

vec3 unfold_palette(float x) {
    x=fract(x);
    if(x<0.25) return mix(u_color_1.rgb,u_color_2.rgb,x/0.25);
    if(x<0.50) return mix(u_color_2.rgb,u_color_3.rgb,(x-0.25)/0.25);
    if(x<0.75) return mix(u_color_3.rgb,u_color_4.rgb,(x-0.50)/0.25);
    return mix(u_color_4.rgb,u_color_1.rgb,(x-0.75)/0.25);
}

vec4 fx_fractal_unfolding(vec2 uv) {
    vec2 z=(uv-vec2(0.5))*2.0/u_zoom+vec2(u_pan_x,u_pan_y);

    float time=u_time;
    vec2 c=vec2(u_c_x,u_c_y);
    c+=vec2(u_c_motion_x,u_c_motion_y)*time;
    c+=vec2(
        cos(time*u_c_orbit_speed)*u_c_orbit_x,
        sin(time*u_c_orbit_speed)*u_c_orbit_y
    );

    float escaped=0.0;
    float n=0.0;

    for(int i=0;i<128;i++) {
        if(float(i)>=u_max_iterations) break;

        if(u_render_mode<0.5) {
            // Julia
            float r=max(length(z),0.0001);
            float a=atan(z.y,z.x);
            float p=u_julia_power;
            z=pow(r,p)*vec2(cos(a*p),sin(a*p))+c;

        } else if(u_render_mode<1.5) {
            // Rational Julia: (z^2+c)/(z^2-c)
            vec2 zz=cpow2(z);
            vec2 num=zz+c;
            vec2 den=zz-c;
            float d=max(cabs2(den),0.00001);
            z=vec2(
                (num.x*den.x+num.y*den.y)/d,
                (num.y*den.x-num.x*den.y)/d
            )*u_rational_pole;

        } else if(u_render_mode<2.5) {
            // Reciprocal Julia: z^2 + c/z
            vec2 zz=cpow2(z);
            float d=max(cabs2(z),u_reciprocal_softness);
            vec2 inv=vec2(z.x,-z.y)/d;
            z=zz+c*inv*u_reciprocal_strength;

        } else if(u_render_mode<3.5) {
            // Sine Julia: c * sin(z)
            z=csin_unfold(z*u_sine_frequency)*c*u_sine_strength;

        } else if(u_render_mode<4.5) {
            // Exponential Julia: c * exp(z)
            z=cexp_unfold(z*u_exp_scale)*c*u_exp_strength;

        } else {
            // Nova: relaxed Newton iteration for z^3-1
            vec2 z2=cpow2(z);
            vec2 z3=cpow3(z);
            float d=max(cabs2(z2),0.00001);
            vec2 ratio=vec2(
                (z3.x*z2.x+z3.y*z2.y)/d,
                (z3.y*z2.x-z3.x*z2.y)/d
            )/3.0;
            z=z-(ratio*u_nova_relax)+c*u_nova_strength;
        }

        float r2=cabs2(z);
        n+=1.0;

        if(r2>u_escape*u_escape) {
            escaped=1.0;
            break;
        }
    }

    float shade=n/u_max_iterations;

    if(escaped>0.5) {
        float smooth_n=n-log2(log2(max(length(z),1.0001)));
        shade=smooth_n/u_max_iterations;
    }

    float palette=shade*u_palette_frequency+time*u_color_cycle_speed;
    vec3 col=unfold_palette(palette);

    return vec4(col,1.0);
}
"""




const SRC_CYBER_VEINS: String = """
uniform float u_rotation = 0.0; // @label Base Angle | @min -180 | @max 180 | @sens 0.5
uniform vec2 u_maze_scale = vec2(36.0, 36.0); // @label Stretching | @min 1.0 | @max 100.0 | @sens 0.5
uniform float u_rotation_speed = 0.0; // @label Rotation Speed | @min -4.0 | @max 4.0 | @sens 0.05
uniform float u_complexity = 0.25; // @label Scale | @min 0.0 | @max 5.0 | @sens 0.05
uniform float u_morph_speed = 0.3; // @label Global: Morph Speed | @min -6.0 | @max 6.0 | @sens 0.1
uniform float u_vein_density = 15.0; // @label Corridor Density | @min 1.0 | @max 60.0 | @sens 0.5
uniform float u_glow_sharpness = 0.82; // @label Glow Sharpness | @min 0.00 | @max 1.0 | @sens 0.01
uniform float u_pulse_speed = 1.5; // @label Pulse Speed | @min -15.0 | @max 15.0 | @sens 0.50
uniform float u_laser_overdrive = 1.0; // @label Overdrive | @min 0.0 | @max 2.0 | @sens 0.05
uniform float u_chromatic_split = 0.75; // @label RGB Color Split | @min -5.0 | @max 5.00 | @sens 0.01
uniform vec4 u_color_base : source_color = vec4(0.01, 0.01, 0.03, 1.0); // @label Color: Floor | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_color_glow : source_color = vec4(0.1, 0.0, 0.25, 1.0); // @label Color: Walls | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_pattern_color : source_color = vec4(1.0, 1.0, 1.0, 1.0); // @label Color: Grid | @min 0 | @max 1 | @sens 0.02

float cyber_veins_evaluate(vec2 coords) {
	// Track 1: Moving plane for morphing geometry
	float z_time = u_time * u_morph_speed;
	vec3 coord_moving = vec3(coords.x, coords.y, z_time);

	float gyroid_moving =
		(sin(coord_moving.x * u_complexity) * cos(coord_moving.y * u_complexity)) +
		(sin(coord_moving.y * u_complexity) * cos(coord_moving.z)) +
		(sin(coord_moving.z) * cos(coord_moving.x * u_complexity));

	float field_abs = abs(gyroid_moving);

	// Track 2: Static snapshot for the decoupled circuit speed clock
	vec3 coord_static = vec3(coords.x, coords.y, 0.0);

	float gyroid_static =
		(sin(coord_static.x * u_complexity) * cos(coord_static.y * u_complexity)) +
		(sin(coord_static.y * u_complexity) * cos(coord_static.z)) +
		(sin(coord_static.z) * cos(coord_static.x * u_complexity));

	float field_static_abs = abs(gyroid_static);

	float laser_pulse =
		sin(field_static_abs * u_vein_density - u_time * u_pulse_speed) * 0.5 + 0.5;

	float circuits =
		smoothstep(u_glow_sharpness, u_glow_sharpness + 0.06, laser_pulse);

	float laser_mask =
		circuits * smoothstep(2.0, 0.2, field_abs);

	return clamp(laser_mask * u_laser_overdrive, 0.0, 2.0);
}

vec4 fx_cyber_veins(vec2 uv) {
	vec2 uv_centered = uv - 0.5;

	float animated_angle =
		u_rotation + (u_time * u_rotation_speed * 15.0);

	float radians_angle =
		animated_angle * 0.01745329251;

	float cos_a = cos(radians_angle);
	float sin_a = sin(radians_angle);

	vec2 p = vec2(
		uv_centered.x * cos_a - uv_centered.y * sin_a,
		uv_centered.x * sin_a + uv_centered.y * cos_a
	);

	p *= u_maze_scale;

	// --- CHROMATIC ABERRATION CHROMINANCE SYSTEM ---
	// Sample three independent spatial locations along the horizontal plane.
	float mask_red =
		cyber_veins_evaluate(p - vec2(u_chromatic_split, 0.0));

	float mask_green =
		cyber_veins_evaluate(p);

	float mask_blue =
		cyber_veins_evaluate(p + vec2(u_chromatic_split, 0.0));

	// Reconstruct the individual R, G, B mask vectors.
	vec3 spectral_veins =
		vec3(mask_red, mask_green, mask_blue) * u_pattern_color.rgb;

	// Compute the shared ambient lighting background.
	float z_time = u_time * u_morph_speed;

	vec3 coord_bg =
		vec3(p.x, p.y, z_time);

	float gyroid_bg =
		(sin(coord_bg.x * u_complexity) * cos(coord_bg.y * u_complexity)) +
		(sin(coord_bg.y * u_complexity) * cos(coord_bg.z)) +
		(sin(coord_bg.z) * cos(coord_bg.x * u_complexity));

	vec4 dynamic_bg =
		mix(
			u_color_base,
			u_color_glow,
			smoothstep(1.5, 0.0, abs(gyroid_bg))
		);

	// Add the separated chromatic laser filaments.
	vec4 final_color =
		vec4(dynamic_bg.rgb + spectral_veins, 1.0);

	return final_color;
}
"""



const SRC_PLASMA_MASTER: String = """
uniform int u_render_mode = 0; // @label Style Select | @min 0 | @max 3 | @sens 1 | @is_style
uniform vec2 u_plasma_scale = vec2(25.0, 25.0); // @label Global: Wave Scale | @min 1.0 | @max 50.0 | @sens 1.0
uniform float u_plasma_speed = 1.0; // @label Global: Wave Speed | @min 0.0 | @max 8.0 | @sens 0.5
uniform float u_turbulence = 1.0; // @label Global: Wave Complexity | @min 0.05 | @max 8.0 | @sens 0.5

// --- STYLE 0 : LIQUID PLASMA ---
uniform float u_plasma_contrast = 1.2; // @label [S0] Contrast | @min 0.1 | @max 4.0 | @sens 0.05 | @style 0
uniform float u_plasma_warp = 1.0; // @label [S0] Flow Distortion | @min 0.0 | @max 4.0 | @sens 0.05 | @style 0
uniform vec4 u_s0_dark : source_color = vec4(0.01, 0.0, 0.08, 1.0); // @label [S0] Deep Violet | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_mid : source_color = vec4(0.1, 0.2, 0.8, 1.0); // @label [S0] Electric Blue | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_hot : source_color = vec4(0.0, 1.0, 0.85, 1.0); // @label [S0] Liquid Cyan | @min 0 | @max 1 | @sens 0.02 | @style 0

// --- STYLE 1 : COSINE SPECTRUM ---
uniform float u_s1_frequency = 2.0; // @label [S1] Spectrum Density | @min 0.1 | @max 12.0 | @sens 0.1 | @style 1
uniform float u_s1_phase = 0.0; // @label [S1] Spectrum Phase | @min -6.28 | @max 6.28 | @sens 0.05 | @style 1
uniform float u_s1_spread = 1.0; // @label [S1] Color Spread | @min 0.1 | @max 3.0 | @sens 0.05 | @style 1
uniform float u_s1_cycle = 0.5; // @label [S1] Spectrum Motion | @min -5.0 | @max 5.0 | @sens 0.05 | @style 1
uniform vec4 u_s1_a : source_color = vec4(0.05, 0.0, 0.35, 1.0); // @label [S1] Indigo | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_b : source_color = vec4(0.0, 0.7, 1.0, 1.0); // @label [S1] Azure | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_c : source_color = vec4(0.8, 0.1, 1.0, 1.0); // @label [S1] Magenta | @min 0 | @max 1 | @sens 0.02 | @style 1

// --- STYLE 2 : CHRONO ---
uniform float u_s2_warp = 1.5; // @label [S2] Time Distortion | @min 0.0 | @max 6.0 | @sens 0.05 | @style 2
uniform float u_s2_pulse = 2.0; // @label [S2] Pulse Density | @min 0.1 | @max 12.0 | @sens 0.1 | @style 2
uniform float u_s2_morph = 0.7; // @label [S2] Color Morph Speed | @min -5.0 | @max 5.0 | @sens 0.05 | @style 2
uniform float u_s2_glow = 1.0; // @label [S2] Glow | @min 0.0 | @max 3.0 | @sens 0.05 | @style 2
uniform vec4 u_s2_deep : source_color = vec4(0.12, 0.0, 0.03, 1.0); // @label [S2] Crimson Deep | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_mid : source_color = vec4(0.9, 0.15, 0.02, 1.0); // @label [S2] Solar Orange | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_hot : source_color = vec4(1.0, 0.8, 0.08, 1.0); // @label [S2] Chrono Gold | @min 0 | @max 1 | @sens 0.02 | @style 2

// --- STYLE 3 : CYBER VEINS ---
uniform float u_s3_density = 14.0; // @label [S3] Vein Density | @min 1.0 | @max 60.0 | @sens 1.0 | @style 3
uniform float u_s3_sharpness = 0.84; // @label [S3] Vein Sharpness | @min 0.05 | @max 0.995 | @sens 0.01 | @style 3
uniform float u_s3_secondary = 3.0; // @label [S3] Secondary Veins | @min 0.0 | @max 15.0 | @sens 0.1 | @style 3
uniform float u_s3_drift = 1.0; // @label [S3] Vein Drift | @min -5.0 | @max 5.0 | @sens 0.05 | @style 3
uniform vec4 u_s3_base : source_color = vec4(0.005, 0.01, 0.02, 1.0); // @label [S3] Void | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_glow : source_color = vec4(0.0, 0.15, 0.2, 1.0); // @label [S3] Circuit Glow | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_hot : source_color = vec4(0.0, 1.0, 0.65, 1.0); // @label [S3] Neon Veins | @min 0 | @max 1 | @sens 0.02 | @style 3

vec4 fx_plasma_master(vec2 uv) {
	vec2 p = (uv - 0.5) * u_plasma_scale;
	float t = u_time * u_plasma_speed;

	float v1 = sin(p.x * u_turbulence + t);
	float v2 = sin(u_turbulence * (p.y * cos(t * 0.33) + p.x * sin(t * 0.21)) + t);
	vec2 cp = p + vec2(sin(t * 0.4), cos(t * 0.35)) * 2.0;
	float v3 = sin(sqrt(dot(cp, cp)) * u_turbulence - t);

	float field = (v1 + v2 + v3) / 3.0;
	field = field * 0.5 + 0.5;

	vec3 color = vec3(0.0);

	if (u_render_mode == 0) {
		// LIQUID PLASMA
		float warp = sin(p.x * 0.7 + t) * sin(p.y * 0.6 - t * 0.7) * u_plasma_warp;
		float f = clamp((field + warp * 0.08 - 0.5) * u_plasma_contrast + 0.5, 0.0, 1.0);

		color = mix(u_s0_dark.rgb, u_s0_mid.rgb, smoothstep(0.15, 0.55, f));
		color = mix(color, u_s0_hot.rgb, smoothstep(0.5, 0.9, f));
	}
	else if (u_render_mode == 1) {
		// COSINE SPECTRUM
		float x = field * u_s1_frequency + t * u_s1_cycle + u_s1_phase;
		vec3 wave = 0.5 + 0.5 * cos(6.2831853 * (x + vec3(0.0, 0.33, 0.67)) * u_s1_spread);

		color = mix(u_s1_a.rgb, u_s1_b.rgb, wave.b);
		color = mix(color, u_s1_c.rgb, wave.r);
	}
	else if (u_render_mode == 2) {
		// CHRONO
		float warped = field
			+ sin(field * u_s2_pulse * 6.2831853 - t * u_s2_warp) * 0.12;

		float pulse = sin(warped * u_s2_pulse * 6.2831853 - t * u_s2_warp);
		float glow = smoothstep(0.0, 1.0, pulse * 0.5 + 0.5) * u_s2_glow;

		float morph = sin(t * u_s2_morph) * 0.5 + 0.5;
		vec3 deep = mix(u_s2_deep.rgb, u_s2_mid.rgb, morph);
		vec3 hot = mix(u_s2_mid.rgb, u_s2_hot.rgb, morph);

		color = mix(deep, hot, smoothstep(0.25, 0.75, warped));
		color += u_s2_hot.rgb * glow * 0.18;
	}
	else {
		// CYBER VEINS
		float pulse = sin(
			field * u_s3_density * 6.2831853
			+ sin(field * u_s3_secondary * 6.2831853)
			- t * u_s3_drift
		) * 0.5 + 0.5;

		float veins = 1.0 - smoothstep(
			u_s3_sharpness,
			u_s3_sharpness + 0.08,
			pulse
		);

		float secondary = sin(
			field * u_s3_secondary * 18.0
			+ t * u_s3_drift * 0.7
		) * 0.5 + 0.5;

		veins *= 0.7 + secondary * 0.3;

		color = mix(u_s3_base.rgb, u_s3_glow.rgb, field * 0.5);
		color = mix(color, u_s3_hot.rgb, veins);
	}

	return vec4(color, 1.0);
}
"""




const SRC_FOLDING_KALEIDOSCOPE: String = """
uniform int u_fold_iterations = 4; // @label Fold Iterations | @min 1 | @max 8 | @sens 1
uniform float u_fold_angle = 1.047; // @label Mirror Angle (Radians) | @min 0.0 | @max 3.1416 | @sens 0.02
uniform float u_fold_scale = 1.2; // @label Fold Spatial Scaling | @min 0.5 | @max 2.5 | @sens 0.05
uniform vec2 u_fold_shift = vec2(0.3, 0.3); // @label Fold Translation | @min -1.0 | @max 1.0 | @sens 0.01

vec2 fx_folding_kaleidoscope(vec2 uv) {
	// Center coordinates around (0.0, 0.0)
	vec2 p = uv - 0.5;
	
	// Create a mathematical fold mirror vector line based on the user's angle
	vec2 mirror_normal = vec2(cos(u_fold_angle), sin(u_fold_angle));
	
	// RECURSIVE SPACE-FOLDING MATRIX LOOP
	for (int i = 0; i < u_fold_iterations; i++) {
		// 1. Plane Fold: Enforce absolute symmetry on the axes
		p = abs(p);
		
		// 2. Vector Fold: If space crosses the angled mirror plane, reflect it backward
		float distance_to_plane = dot(p, mirror_normal);
		if (distance_to_plane > 0.0) {
			p -= 2.0 * distance_to_plane * mirror_normal;
		}
		
		// 3. Scale and Translate: Stretch and offset space before the next fold layer hits
		p *= u_fold_scale;
		p -= u_fold_shift;
	}
	
	// Realign back to clean texture coordinate tracking boundaries (0.0 to 1.0)
	return fract(p + 0.5);
}
"""


const SRC_MIRROR_TILE: String = """
uniform vec2 u_tile_frequency = vec2(3.0, 3.0); // @label Tile Density | @min 1.0 | @max 12.0 | @sens 0.1
uniform vec2 u_tile_scroll = vec2(0.0, 0.0); // @label Tile Scroll Offset | @min -1.0 | @max 1.0 | @sens 0.01
uniform float u_mirror_angle = 0.0; // @label Tile Grid Tilt | @min -3.1416 | @max 3.1416 | @sens 0.05
uniform float u_pan_x = 0.00; // @label Pan X | @min -2.0 | @max 2.0 | @sens 0.010 
uniform float u_pan_y = 0.00; // @label Pan Y | @min -2.0 | @max 2.0 | @sens 0.010

// Helper: 2D Grid Rotation Matrix
vec2 tile_rot2(vec2 p, float angle) {
	float s = sin(angle); float c = cos(angle);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

vec2 fx_mirror_tile(vec2 uv) {
	vec2 p = tile_rot2(uv - 0.5, u_mirror_angle);
	vec2 static_offset = u_tile_scroll;
	vec2 velocity = vec2(u_pan_x, u_pan_y);

	vec2 scaled_p = (p + 0.5) * u_tile_frequency
		+ static_offset
		+ u_time * velocity;

	vec2 tile_index = floor(scaled_p);
	vec2 local_uv = fract(scaled_p);

	if (mod(tile_index.x, 2.0) == 1.0) local_uv.x = 1.0 - local_uv.x;
	if (mod(tile_index.y, 2.0) == 1.0) local_uv.y = 1.0 - local_uv.y;

	return local_uv;
}
"""




const SRC_FXAA_FILTER: String = """
uniform float u_fxaa_span_max = 8.0; // @label Blur Maximum Span | @min 2.0 | @max 16.0 | @sens 1.0
uniform float u_fxaa_reducer = 128.0; // @label Edge Sharpness Cutoff | @min 32.0 | @max 256.0 | @sens 4.0

vec4 fx_fxaa_filter(vec2 uv) {
	// Query screen pixel step sizes
	vec2 r_size = vec2(textureSize(u_warped_texture, 0));
	vec2 texel_step = 1.0 / r_size;
	
	// Sample the core pixel and its 4 immediate cross neighbors
	vec3 rgbNW = texture(u_warped_texture, uv + vec2(-1.0, -1.0) * texel_step).rgb;
	vec3 rgbNE = texture(u_warped_texture, uv + vec2(1.0, -1.0) * texel_step).rgb;
	vec3 rgbSW = texture(u_warped_texture, uv + vec2(-1.0, 1.0) * texel_step).rgb;
	vec3 rgbSE = texture(u_warped_texture, uv + vec2(1.0, 1.0) * texel_step).rgb;
	vec3 rgbM  = texture(u_warped_texture, uv).rgb;
	
	// Convert channels to luminance weights to evaluate edge contrast gradients
	vec3 luma = vec3(0.299, 0.587, 0.114);
	float lumaNW = dot(rgbNW, luma);
	float lumaNE = dot(rgbNE, luma);
	float lumaSW = dot(rgbSW, luma);
	float lumaSE = dot(rgbSE, luma);
	float lumaM  = dot(rgbM,  luma);
	
	// Detect contrast bounds
	float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
	float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
	
	// Calculate edge direction vector forces
	vec2 dir;
	dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
	dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));
	
	float dirReduce = max((lumaNW + lumaSW + lumaNE + lumaSE) * (0.25 * 0.03125), 1.0 / u_fxaa_reducer);
	float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
	
	dir = min(vec2(u_fxaa_span_max), max(vec2(-u_fxaa_span_max), dir * rcpDirMin)) * texel_step;
	
	// Gather directional anti-aliasing pixel weights blends
	vec3 rgbA = 0.5 * (
		texture(u_warped_texture, uv + dir * (1.0 / 3.0 - 0.5)).rgb +
		texture(u_warped_texture, uv + dir * (2.0 / 3.0 - 0.5)).rgb);
		
	vec3 rgbB = rgbA * 0.5 + 0.25 * (
		texture(u_warped_texture, uv + dir * -0.5).rgb +
		texture(u_warped_texture, uv + dir * 0.5).rgb);
		
	float lumaB = dot(rgbB, luma);
	
	// If the sub-pixel directional blur goes out of our luminance contrast window, fallback to tighter blend
	if ((lumaB < lumaMin) || (lumaB > lumaMax)) {
		return vec4(rgbA, 1.0);
	}
	
	return vec4(rgbB, 1.0);
}
"""


const SRC_FISHEYE: String = """
uniform float u_bulge = 0.300; // @label Bulge Strength | @min -06.000 | @max 6.000 | @sens 0.010 | @rest 0
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01

vec2 fx_FISHEYE(vec2 uv) {
	vec2 p = uv - u_center;
	float r2 = dot(p, p);
	return u_center + p * (1.0 + u_bulge * r2 * 4.0);
}
"""


const SRC_NEON_BLUR: String = """
uniform float u_glow_radius = 0.015; // @label Glow Spread | @min 0.0 | @max 0.05 | @sens 0.001
uniform float u_glow_intensity = 2.0; // @label Neon Intensity | @min 0.0 | @max 5.0 | @sens 0.05
uniform float u_glow_threshold = 0.3; // @label Highlight Cutoff | @min 0.0 | @max 1.0 | @sens 0.02
uniform vec4 u_neon_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0); // @label Neon Color Tint | @min 0 | @max 1 | @sens 0.02

vec4 fx_neon_blur(vec2 uv) {
	// 1. Sample the crisp original base image
	vec4 base_color = texture(u_warped_texture, uv);
	
	// 2. Multi-tap box blur sampling matrix to extract and spread local light
	vec4 glow_acc = vec4(0.0);
	float total_weight = 0.0;
	
	// Directional sampling offsets for a smooth 2D blur spread
	vec2 offsets[8] = vec2[](
		vec2(-1.0, -1.0), vec2(0.0, -1.0), vec2(1.0, -1.0),
		vec2(-1.0,  0.0),                  vec2(1.0,  0.0),
		vec2(-1.0,  1.0), vec2(0.0,  1.0), vec2(1.0,  1.0)
	);
	
	for (int i = 0; i < 8; i++) {
		vec2 sample_uv = uv + offsets[i] * u_glow_radius;
		vec4 tex_sample = texture(u_warped_texture, clamp(sample_uv, 0.0, 1.0));
		
		// Measure luminance to see if the pixel passes our highlight threshold cutoff
		float luma = dot(tex_sample.rgb, vec3(0.299, 0.587, 0.114));
		
		// If it's bright enough, isolate it and add it to our glow accumulator
		float highlight_mask = smoothstep(u_glow_threshold, u_glow_threshold + 0.1, luma);
		glow_acc += tex_sample * highlight_mask;
		total_weight += 1.0;
	}
	
	// Calculate final averaged glow layer and apply user intensity and color tinting overrides
	vec3 final_glow = (glow_acc.rgb / max(total_weight, 1.0)) * u_glow_intensity * u_neon_tint.rgb;
	
	// 3. Layer the soft blurred neon light directly over the original crisp lines
	return vec4(base_color.rgb + final_glow, base_color.a);
}
"""




const SRC_OIL_PAINTING: String = """
uniform float u_brush_radius = 4.0; // @label Brush Stroke Size | @min 1.0 | @max 8.0 | @sens 0.5
uniform float u_paint_coarseness = 3.0; // @label Color Clustering | @min 1.0 | @max 10.0 | @sens 0.5
uniform float u_canvas_texture = 0.08; // @label Canvas Paper Grain | @min 0.0 | @max 0.3 | @sens 0.01

// Simple generator to layer on canvas fabric weave grain lines
float paint_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 fx_oil_painting(vec2 uv) {
	// Query the layout dimensions of the texture from previous passes
	vec2 tex_size = vec2(textureSize(u_warped_texture, 0));
	vec2 src_step = 1.0 / tex_size;
	
	// Create accumulation buffers for painterly color averages
	vec3 color_sum = vec3(0.0);
	float weight_sum = 0.0;
	
	int radius = int(floor(u_brush_radius));
	
	// Scan adjacent pixel clusters within our artistic brush boundary box
	for (int j = -radius; j <= radius; j++) {
		for (int i = -radius; i <= radius; i++) {
			vec2 offset = vec2(float(i), float(j)) * src_step;
			vec3 tex_sample = texture(u_warped_texture, clamp(uv + offset, 0.0, 1.0)).rgb;
			
			// Cluster colors into coarse brackets to group strokes together
			vec3 clustered = floor(tex_sample * u_paint_coarseness) / u_paint_coarseness;
			
			color_sum += tex_sample;
			weight_sum += 1.0;
		}
	}
	
	// Calculate the flattened canvas pigment core color
	vec3 paint_pigment = color_sum / max(weight_sum, 1.0);
	
	// Layer an organic interlaced canvas thread texture over the paint layers
	float fabric_weave = paint_hash(floor(uv * tex_size)) * u_canvas_texture;
	paint_pigment += vec3(fabric_weave - (u_canvas_texture * 0.5));
	
	return vec4(paint_pigment, 1.0);
}
"""


const SRC_ASCII_ART: String = """
uniform float u_terminal_columns = 80.0; // @label Text Columns | @min 20 | @max 180 | @sens 2
uniform float u_font_stretch = 1.5; // @label Character Height Ratio | @min 0.5 | @max 3.0 | @sens 0.05
uniform vec4 u_text_color : source_color = vec4(0.0, 1.0, 0.3, 1.0); // @label Font Color | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_terminal_bg : source_color = vec4(0.01, 0.02, 0.01, 1.0); // @label Terminal Background | @min 0 | @max 1 | @sens 0.02

// A procedural layout that mocks character glyph shapes based on cell coordinates
float ascii_character_glyph(int character_id, vec2 cell_uv) {
	vec2 p = abs(cell_uv - 0.5);
	
	if (character_id == 4) { // Dense character block '#'
		return step(0.1, max(p.x, p.y)) * step(max(p.x, p.y), 0.45);
	}
	if (character_id == 3) { // Bold character 'X'
		return step(abs(p.x - p.y), 0.08) * step(max(p.x, p.y), 0.4);
	}
	if (character_id == 2) { // Cross character '+'
		return (step(p.x, 0.06) * step(p.y, 0.35)) + (step(p.y, 0.06) * step(p.x, 0.35));
	}
	if (character_id == 1) { // Center dash character '-'
		return step(abs(cell_uv.y - 0.5), 0.05) * step(p.x, 0.3);
	}
	// Tiny dot character '.'
	return step(length(cell_uv - 0.5), 0.08);
}

vec4 fx_ascii_art(vec2 uv) {
	// 1. Establish character terminal row grid scaling configurations
	vec2 text_scale = vec2(u_terminal_columns, u_terminal_columns * u_font_stretch);
	
	// Segment the coordinate layout down into individual grid cells
	vec2 blocky_uv = floor(uv * text_scale) / text_scale;
	vec2 local_cell_uv = fract(uv * text_scale);
	
	// 2. Measure local luminance inside the character block coordinate boundaries
	vec4 source_sample = texture(u_warped_texture, blocky_uv);
	float brightness = dot(source_sample.rgb, vec3(0.299, 0.587, 0.114));
	
	// Convert brightness score thresholds into a discrete character selector ID
	int character_selector = int(floor(brightness * 5.0));
	character_selector = clamp(character_selector, 0, 4);
	
	// 3. Render the shape of the chosen character glyph inside the local cell block
	float glyph_mask = ascii_character_glyph(character_selector, local_cell_uv);
	
	// If the background cell brightness is completely dark, suppress drawing the glyph text
	if (brightness < 0.05) { glyph_mask = 0.0; }
	
	// Mix character matrix inks over the command line terminal base screen backdrop
	vec3 output_color = mix(u_terminal_bg.rgb, u_text_color.rgb, glyph_mask);
	
	return vec4(output_color, 1.0);
}
"""


const SRC_HALFTONE_DOTS: String = """
uniform float u_dot_frequency = 45.0; // @label Dot Frequency Grid | @min 10.0 | @max 150.0 | @sens 1.0
uniform float u_halftone_sharpness = 0.08; // @label Dot Crispness | @min 0.01 | @max 0.4 | @sens 0.005
uniform vec4 u_ink_color : source_color = vec4(0.0, 0.0, 0.0, 1.0); // @label Screenprint Ink | @min 0 | @max 1 | @sens 0.02
uniform vec4 u_paper_color : source_color = vec4(0.95, 0.95, 0.9, 1.0); // @label Newsprint Paper | @min 0 | @max 1 | @sens 0.02

vec4 fx_halftone_dots(vec2 uv) {
	// Sample the compiled background canvas texture from previous passes
	vec4 pixel_color = texture(u_warped_texture, uv);
	
	// Convert the RGB pixel stream into a clean scalar luminance (brightness) score
	float luminance = dot(pixel_color.rgb, vec3(0.299, 0.587, 0.114));
	
	// Slice coordinate space up into a repeating dot matrix grid cell network
	vec2 grid = fract(uv * u_dot_frequency) - 0.5;
	float dot_radius = length(grid);
	
	// The dot size scales proportionally based on local luminance intensity
	float target_size = luminance * 0.707; // 0.707 prevents dots from totally disappearing
	
	// Evaluate the edge mask boundaries of each print ink circle cell
	float print_mask = smoothstep(target_size, target_size - u_halftone_sharpness, dot_radius);
	
	// Blend between your vintage textured paper stock color and your dark printing press ink
	return mix(u_paper_color, u_ink_color, print_mask);
}
"""


const SRC_GOD_RAYS: String = """
uniform float u_ray_density = 0.95; // @label Ray Length | @min 0.5 | @max 0.99 | @sens 0.01
uniform float u_ray_weight = 0.5; // @label Beam Exposure | @min 0.0 | @max 1.5 | @sens 0.05
uniform float u_ray_decay = 0.98; // @label Falloff Decay | @min 0.9 | @max 1.0 | @sens 0.005
uniform vec2 u_ray_source = vec2(0.5, 0.5); // @label Light Origin | @min 0.0 | @max 1.0 | @sens 0.01

vec4 fx_god_rays(vec2 uv) {
	// Calculate a directional vector pointing from the pixel back to the light center source
	vec2 delta_uv = (uv - u_ray_source);
	
	// Scale the step division vector based on density parameters
	delta_uv *= 1.0 / 8.0 * u_ray_density; // 8-tap approximation loop
	
	// Capture the baseline core image pixel color
	vec4 base_color = texture(u_warped_texture, uv);
	
	// Create accumulation buffers for the projected light streaks
	vec3 light_stream = base_color.rgb;
	float current_illumination = 1.0;
	
	vec2 trace_uv = uv;
	
	// Step along the directional vector, sampling texture brightness layers
	for (int i = 0; i < 8; i++) {
		trace_uv -= delta_uv;
		vec3 sample_layer = texture(u_warped_texture, clamp(trace_uv, 0.0, 1.0)).rgb;
		
		// Apply exponential decay attenuation curves
		sample_layer *= current_illumination * u_ray_weight;
		light_stream += sample_layer;
		current_illumination *= u_ray_decay;
	}
	
	// Blend the accumulated light beams back over the top of the crisp baseline color
	return vec4(base_color.rgb + light_stream * 0.15, 1.0);
}
"""


const SRC_VIGNETTE_BLUR: String = """
uniform float u_vignette_extent = 0.5; // @label Vignette Radius | @min 0.1 | @max 1.5 | @sens 0.02
uniform float u_vignette_softness = 0.45; // @label Vignette Softness | @min 0.05 | @max 1.0 | @sens 0.02
uniform float u_blur_radius = 0.015; // @label Edge Blur Strength | @min 0.0 | @max 0.05 | @sens 0.001

vec4 fx_vignette_blur(vec2 uv) {
	// Center space to calculate radial distance for the lens edge
	vec2 center_dist = uv - 0.5;
	float d = length(center_dist);
	
	// 1. Calculate the vignette falloff mask using smoothstep
	float vignette = smoothstep(u_vignette_extent, u_vignette_extent - u_vignette_softness, d);
	
	// 2. RADIAL BLUR PASS: The further from the center, the more samples we gather
	float current_blur = smoothstep(u_vignette_extent * 0.5, u_vignette_extent, d) * u_blur_radius;
	
	vec4 color_accumulation = vec4(0.0);
	float total_weight = 0.0;
	
	// 4-tap box blur array offsets for smooth edge sampling
	vec2 blur_offsets[4] = vec2[](
		vec2(-1.0, -1.0), vec2(1.0, -1.0),
		vec2(-1.0, 1.0), vec2(1.0, 1.0)
	);
	
	// Gather adjacent pixel weights based on radial blur gradient
	for (int i = 0; i < 4; i++) {
		vec2 sample_uv = uv + blur_offsets[i] * current_blur;
		color_accumulation += texture(u_warped_texture, clamp(sample_uv, 0.0, 1.0));
		total_weight += 1.0;
	}
	
	vec4 final_sample = color_accumulation / total_weight;
	
	// Apply the dark vignette frame overlay onto the blurred pixel stream
	final_sample.rgb *= vignette;
	
	return vec4(final_sample.rgb, 1.0);
}
"""


const SRC_PIXEL_CRUSHER: String = """
uniform float u_pixel_grid_size = 128.0; // @label Pixel Grid Blocks | @min 16 | @max 512 | @sens 4
uniform float u_color_depth_steps = 8.0; // @label Color Palette Bits | @min 2 | @max 32 | @sens 1
uniform float u_dither_strength = 0.15; // @label Retro Dither Noise | @min 0.0 | @max 0.5 | @sens 0.01

// Simple grid noise generator to create dithered checkerboard pixels
float pixel_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec4 fx_pixel_crusher(vec2 uv) {
	// 1. RESOLUTION CRUSH: Snap the smooth UV space to a low-res pixel grid blocks count
	vec2 blocky_uv = floor(uv * u_pixel_grid_size) / u_pixel_grid_size;
	
	// Sample the scene texture at our blocky coordinate steps
	vec4 pixel_color = texture(u_warped_texture, blocky_uv);
	
	// 2. RETRO DITHER: Calculate an old-school 50% checkerboard dither pattern to fake smooth shading
	float dither = pixel_hash(floor(uv * u_pixel_grid_size)) * u_dither_strength;
	pixel_color.rgb += vec3(dither - (u_dither_strength * 0.5));
	
	// 3. COLOR PALETTE CRUSH: Force the smooth color floats into blocky bit-depth chunks
	pixel_color.r = floor(pixel_color.r * u_color_depth_steps) / u_color_depth_steps;
	pixel_color.g = floor(pixel_color.g * u_color_depth_steps) / u_color_depth_steps;
	pixel_color.b = floor(pixel_color.b * u_color_depth_steps) / u_color_depth_steps;
	
	return vec4(pixel_color.rgb, 1.0);
}
"""

const SRC_VHS_GLITCH: String = """
uniform float u_vhs_noise_mix = 0.15; // @label Tape Static Noise | @min 0.0 | @max 0.5 | @sens 0.01
uniform float u_shake_frequency = 4.0; // @label Tracking Jitter | @min 0.0 | @max 15.0 | @sens 0.5
uniform float u_chromatic_split = 0.008; // @label Color Bleeding | @min 0.0 | @max 0.04 | @sens 0.001
uniform float u_glitch_frequency = 1.5; // @label Signal Tearing | @min 0.0 | @max 5.0 | @sens 0.1

// Simple hash to generate pseudo-random values for tracking noise lines
float vhs_hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

vec4 fx_vhs_glitch(vec2 uv) {
	float t = u_time;
	vec2 warped_uv = uv;
	
	// 1. Calculate horizontal pixel tearing strips using sine wave steps and noise
	float tear_wave = sin(uv.y * 10.0 + t * u_shake_frequency) * cos(uv.y * 25.0 - t);
	float tear_trigger = step(0.92, vhs_hash(vec2(floor(uv.y * 15.0), floor(t * 8.0))));
	warped_uv.x += tear_wave * u_glitch_frequency * 0.02 * tear_trigger;
	
	// 2. Vertical tracking jitter (shakes the frame rapidly up and down based on a timer)
	float vertical_shake = vhs_hash(vec2(floor(t * u_shake_frequency), 1.0)) * 0.004;
	warped_uv.y += vertical_shake * step(0.85, vhs_hash(vec2(t, 0.0)));
	
	// 3. Chromatic Channel Bleeding (Simulates analog color misalignments)
	// We separate the Red and Blue channels into separate lookup coordinates
	float r_channel = texture(u_warped_texture, warped_uv + vec2(u_chromatic_split, 0.0)).r;
	float g_channel = texture(u_warped_texture, warped_uv).g;
	float b_channel = texture(u_warped_texture, warped_uv - vec2(u_chromatic_split, 0.0)).b;
	vec3 analog_color = vec3(r_channel, g_channel, b_channel);
	
	// 4. Inject magnetic tape grain and snow static lines
	float static_grain = vhs_hash(uv + vec2(t * 0.1));
	float line_noise = step(0.98, vhs_hash(vec2(0.0, uv.y + t * 5.0))) * 0.3;
	
	// Blend the noise elements into the final canvas
	vec3 final_color = mix(analog_color, vec3(static_grain), u_vhs_noise_mix);
	final_color += vec3(line_noise) * u_vhs_noise_mix * 2.0;
	
	return vec4(final_color, 1.0);
}
"""


const SRC_CRT_SCREEN: String = """
uniform float u_scanline_density = 400.0; // @label Scanline Density | @min 50 | @max 1000 | @sens 10
uniform float u_scanline_opacity = 0.25; // @label Scanline Opacity | @min 0.0 | @max 1.0 | @sens 0.02
uniform float u_pixel_grille = 0.2; // @label RGB Mask Strength | @min 0.0 | @max 1.0 | @sens 0.02
uniform float u_barrel_distortion = 0.08; // @label Screen Curvature | @min 0.0 | @max 0.4 | @sens 0.01
uniform float u_vignette_hold = 0.6; // @label Screen Border Shadow | @min 0.1 | @max 1.0 | @sens 0.02

// Helper function to simulate a curved CRT tube surface
vec2 crt_curved_uv(vec2 uv) {
	vec2 p = uv - 0.5;
	float d = dot(p, p);
	// Deform coordinates outward proportional to their squared distance from the center
	p *= 1.0 + d * u_barrel_distortion;
	return p + 0.5;
}

vec4 fx_crt_screen(vec2 uv) {
	// 1. Apply Screen Curvature Distortion
	vec2 warped_uv = crt_curved_uv(uv);
	
	// If the curved coordinates stretch past the physical screen bezel, clip to black
	if (warped_uv.x < 0.0 || warped_uv.x > 1.0 || warped_uv.y < 0.0 || warped_uv.y > 1.0) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	
	// Sample the compiled scene texture from the previous passes
	vec4 base_color = texture(u_warped_texture, warped_uv);
	
	// 2. Inject Horizontal Scanlines
	float scanline = sin(warped_uv.y * u_scanline_density * 6.28318) * 0.5 + 0.5;
	// Lerp based on user opacity preference
	base_color.rgb = mix(base_color.rgb, base_color.rgb * scanline, u_scanline_opacity);
	
	// 3. Inject Vertical RGB Shadow Mask / Aperture Grille
	float grille = sin(warped_uv.x * u_scanline_density * 1.5 * 6.28318) * 0.5 + 0.5;
	base_color.rgb = mix(base_color.rgb, base_color.rgb * grille, u_pixel_grille);
	
	// 4. Subtle Screen Border Vignette Falloff
	vec2 vig_uv = warped_uv * (1.0 - warped_uv.yx);
	float vig = vig_uv.x * vig_uv.y * 15.0;
	base_color.rgb *= pow(vig, u_vignette_hold);
	
	return base_color;
}
"""


const SRC_FIELD_SHIFT: String = """
uniform vec2 u_field_frequency = vec2(4.0, 4.0); // @label Wave Density | @min 0.5 | @max 16.0 | @sens 0.1
uniform float u_field_strength = 0.05; // @label Glass Thickness | @min 0.0 | @max 0.25 | @sens 0.005
uniform float u_shift_speed = 0.8; // @label Melt Speed | @min 0.0 | @max 3.0 | @sens 0.05
uniform float u_wave_interlace = 2.0; // @label Wave Cross-Folding | @min 0.5 | @max 5.0 | @sens 0.05

vec2 fx_field_shift(vec2 uv) {
	float t = u_time * u_shift_speed;
	
	// Create cross-folding trigonometric vector forces
	float force_x = sin(uv.x * u_field_frequency.x + t) * cos(uv.y * u_field_frequency.y * u_wave_interlace - t);
	float force_y = cos(uv.y * u_field_frequency.y + t) * sin(uv.x * u_field_frequency.x * u_wave_interlace + t);
	
	// Recombine forces into a smooth displacement vector map
	vec2 displacement = vec2(force_x, force_y) * u_field_strength;
	
	// Displace the lookup UV space smoothly
	return uv + displacement;
}
"""


const SRC_POLAR_KALEIDOSCOPE: String = """
uniform float u_sectors = 8.0; // @label Radial Slices | @min 2.0 | @max 32.0 | @sens 1.0
uniform float u_rings = 3.0; // @label Concentric Rings | @min 1.0 | @max 12.0 | @sens 1.0
uniform float u_ring_zoom = 1.5; // @label Ring Scaling | @min 0.5 | @max 5.0 | @sens 0.05
uniform float u_rotation_speed = 0.0; // @label Slice Spin Speed | @min -2.0 | @max 2.0 | @sens 0.05
uniform float u_pulse_speed = 0.1; // @label Ring Pulse Speed | @min -1.0 | @max 1.0 | @sens 0.02

vec2 fx_polar_kaleidoscope(vec2 uv) {
	// Center the coordinates around (0.0, 0.0)
	vec2 p = uv - 0.5;
	
	// Convert space into raw polar coordinates
	float r = length(p);
	float a = atan(p.y, p.x);
	
	// 1. REFLECTION PASS A: Mirror the Angular Space (Slices)
	float angle_step = 6.2831853 / max(u_sectors, 1.0);
	a += u_time * u_rotation_speed;
	// Modulo space partitioning
	float sector_id = floor(a / angle_step);
	a = mod(a, angle_step);
	// Abs creates the mirrored reflection fold down the center of each slice
	a = abs(a - angle_step * 0.5);
	
	// 2. REFLECTION PASS B: Mirror the Radial Space (Rings)
	float radius_step = 0.5 / max(u_rings, 1.0);
	float shifting_r = r * u_ring_zoom + sin(u_time * u_pulse_speed) * 0.05;
	// Divide radius into tile grids, mirroring back and forth across cell boundaries
	float ring_id = floor(shifting_r / radius_step);
	float local_r = mod(shifting_r, radius_step);
	if (mod(ring_id, 2.0) == 1.0) {
		local_r = radius_step - local_r;
	}
	
	// Convert our twice-mirrored polar grid coordinates back to Cartesian UV space
	vec2 warped_uv = vec2(cos(a), sin(a)) * local_r + 0.5;
	
	return warped_uv;
}
"""


const SRC_DROSTE_SPIRAL: String = """
uniform float u_branches = 1.0; // @label Spiral Branches | @min 1.0 | @max 5.0 | @sens 1.0
uniform float u_twist_factor = 1.0; // @label Twist Tightness | @min -4.0 | @max 4.0 | @sens 0.05
uniform float u_spiral_zoom = 0.8; // @label Vortex Zoom | @min 0.2 | @max 3.0 | @sens 0.05
uniform float u_implode_speed = 0.2; // @label Inward Collapse Speed | @min -2.0 | @max 2.0 | @sens 0.05

vec2 fx_droste_spiral(vec2 uv) {
	// Center the coordinates around the vortex center
	vec2 p = uv - 0.5;
	
	// Avoid mathematical undefined errors at the absolute center node
	float r = max(length(p), 0.0001);
	float a = atan(p.y, p.x);
	
	// Conformal Logarithmic Mapping Engine
	// Taking the log of the radius stretches space into a linear timeline grid
	float log_r = log(r);
	
	// Apply structural twists by combining our stretched logarithmic scale and radial angle
	float spiral_x = (log_r * u_spiral_zoom) + (a * u_twist_factor * 0.1591549) - (u_time * u_implode_speed);
	float spiral_y = (a * u_branches * 0.1591549) + (log_r * u_twist_factor * 0.1591549);
	
	// Map the coordinates back into standard texture repeating tile bounds
	vec2 warped_uv = vec2(spiral_x, spiral_y);
	
	// Centering offset realignment mapping for subsequent pattern filters
	return fract(warped_uv + 0.5);
}
"""


const SRC_CHROMATIC_RIPPLE: String = """
uniform float u_ripple_frequency = 8.0; // @label Wave Frequency | @min 1.0 | @max 30.0 | @sens 0.5
uniform float u_ripple_strength = 0.03; // @label Distortion Power | @min 0.0 | @max 0.2 | @sens 0.002
uniform float u_ripple_speed = 2.0; // @label Wave Velocity | @min 0.0 | @max 5.0 | @sens 0.05
uniform vec2 u_ripple_axis = vec2(1.0, 0.0); // @label Wave Direction Vector | @min -1 | @max 1 | @sens 0.1

vec2 fx_chromatic_ripple(vec2 uv) {
	// Calculate a moving wave phase based on coordinate positioning and time
	float alignment = dot(uv, normalize(u_ripple_axis));
	float wave = sin(alignment * u_ripple_frequency - u_time * u_ripple_speed);
	
	// Create an organic warping displacement offset vector
	vec2 offset = vec2(wave) * u_ripple_strength;
	
	// Shift coordinate lookups dynamically to create shimmering liquid glass ripples
	return uv + offset;
}
"""


const SRC_POLAR_MAP: String = """
uniform float u_zoom = 1.0; // @label Tunnel Zoom | @min 0.2 | @max 5.0 | @sens 0.05
uniform float u_repeats_radial = 2.0; // @label Ring Repeats | @min 0.5 | @max 8.0 | @sens 0.5
uniform float u_spin_speed = 0.0; // @label Spin Speed | @min -2.0 | @max 2.0 | @sens 0.05
uniform float u_tunnel_speed = 0.3; // @label Tunnel Fly Speed | @min -3.0 | @max 3.0 | @sens 0.05

vec2 fx_polar_map(vec2 uv) {
	// Center coordinates around (0.0, 0.0)
	vec2 p = uv - 0.5;
	
	// Calculate the polar metrics: r (radius/distance) and a (angle/rotation)
	float r = length(p);
	float a = atan(p.y, p.x);
	
	// 1. Transform Radius into a continuous tunnel depth layout
	// Inverting r makes the center fly forward or backward over time
	float tunnel_depth = (1.0 / max(r, 0.001)) * u_zoom;
	float radial_uv = tunnel_depth + (u_time * u_tunnel_speed);
	
	// 2. Transform Angle into a clean, normalized looping wrap (0.0 to 1.0)
	// Adding time spins the polar coordinate mapping wheel smoothly
	float angular_uv = (a + 3.14159265) / 6.2831853;
	angular_uv = angular_uv * u_repeats_radial + (u_time * u_spin_speed);
	
	// Reassemble back into standard coordinate space for the next pass/texture read
	return vec2(angular_uv, radial_uv);
}
"""


const SRC_FBM_MASTER: String = """
uniform int u_render_mode = 0; // @label Style Select | @min 0 | @max 4 | @sens 1 | @is_style
uniform vec2 u_warp_frequency = vec2(5.0, 5.0); // @label Global: Warp Frequency | @min 0.0 | @max 24.0 | @sens 0.5
uniform float u_warp_strength = 12.0; // @label Global: Warp Strength | @min -10.0 | @max 15.0 | @sens 0.5
uniform float u_noise_detail = 4.0; // @label Global: Noise Detail | @min 1.0 | @max 8.0 | @sens 1.0
uniform float u_flow_speed = 0.4; // @label Global: Fluid Flow Speed | @min -10.0 | @max 10.0 | @sens 0.05

// --- STYLE 0 : ORGANIC RAMP ---
uniform float u_s0_frequency = 0.5; // @label [S0] Color Density | @min 0.0 | @max 4.0 | @sens 0.02 | @style 0
uniform float u_s0_contrast = 1.5; // @label [S0] Contrast | @min 0.1 | @max 4.0 | @sens 0.05 | @style 0
uniform vec4 u_s0_1 : source_color = vec4(0.015, 0.005, 0.05, 1.0); // @label [S0] Deep Violet | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_2 : source_color = vec4(0.18, 0.0, 0.35, 1.0); // @label [S0] Violet | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_3 : source_color = vec4(0.0, 0.45, 0.5, 1.0); // @label [S0] Teal | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform vec4 u_s0_4 : source_color = vec4(0.1, 0.9, 1.0, 1.0); // @label [S0] Cyan | @min 0 | @max 1 | @sens 0.02 | @style 0
uniform float u_s0_split_1 = 0.30; // @label [S0] Color Stop 1 | @min 0.05 | @max 0.6 | @sens 0.01 | @style 0
uniform float u_s0_split_2 = 0.55; // @label [S0] Color Stop 2 | @min 0.2 | @max 0.8 | @sens 0.01 | @style 0
uniform float u_s0_split_3 = 0.80; // @label [S0] Color Stop 3 | @min 0.4 | @max 0.98 | @sens 0.01 | @style 0

// --- STYLE 1 : SPECTRUM ---
uniform float u_s1_frequency = 2.0; // @label [S1] Spectrum Density | @min 0.1 | @max 12.0 | @sens 0.1 | @style 1
uniform float u_s1_cycle = 0.175; // @label [S1] Spectrum Motion | @min -5.0 | @max 5.0 | @sens 0.025 | @style 1
uniform float u_s1_spread = 1.0; // @label [S1] Color Spread | @min 0.1 | @max 4.0 | @sens 0.05 | @style 1
uniform float u_s1_contrast = 1.2; // @label [S1] Spectrum Contrast | @min 0.1 | @max 3.0 | @sens 0.05 | @style 1
uniform float u_s1_phase = 0.0; // @label [S1] Spectrum Phase | @min -6.28 | @max 6.28 | @sens 0.05 | @style 1
uniform vec4 u_s1_a : source_color = vec4(0.02, 0.0, 0.35, 1.0); // @label [S1] Indigo | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_b : source_color = vec4(0.0, 0.65, 1.0, 1.0); // @label [S1] Azure | @min 0 | @max 1 | @sens 0.02 | @style 1
uniform vec4 u_s1_c : source_color = vec4(1.0, 0.05, 0.45, 1.0); // @label [S1] Magenta | @min 0 | @max 1 | @sens 0.02 | @style 1

// --- STYLE 2 : NEBULA ---
uniform float u_s2_morph_speed = 0.5; // @label [S2] Nebula Evolve | @min -10.0 | @max 10.0 | @sens 0.05 | @style 2
uniform float u_s2_contrast = 1.2; // @label [S2] Nebula Contrast | @min 0.1 | @max 4.0 | @sens 0.05 | @style 2
uniform float u_s2_color_shift = 1.0; // @label [S2] Color Shift | @min 0.0 | @max 3.0 | @sens 0.05 | @style 2
uniform vec4 u_s2_dark : source_color = vec4(0.005, 0.0, 0.02, 1.0); // @label [S2] Deep Space | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_mid : source_color = vec4(0.18, 0.01, 0.35, 1.0); // @label [S2] Nebula Purple | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_warm : source_color = vec4(0.9, 0.18, 0.03, 1.0); // @label [S2] Stellar Orange | @min 0 | @max 1 | @sens 0.02 | @style 2
uniform vec4 u_s2_hot : source_color = vec4(1.0, 0.75, 0.25, 1.0); // @label [S2] Star Gold | @min 0 | @max 1 | @sens 0.02 | @style 2

// --- STYLE 3 : CYBER VEINS ---
uniform float u_s3_density = 9.0; // @label [S3] Vein Density | @min 1.0 | @max 30.0 | @sens 0.5 | @style 3
uniform float u_s3_sharpness = 0.72; // @label [S3] Vein Sharpness | @min 0.1 | @max 0.98 | @sens 0.01 | @style 3
uniform float u_s3_contrast = 1.5; // @label [S3] Vein Contrast | @min 0.1 | @max 4.0 | @sens 0.05 | @style 3
uniform float u_s3_glow = 1.0; // @label [S3] Glow | @min 0.0 | @max 4.0 | @sens 0.05 | @style 3
uniform float u_s3_motion = 0.5; // @label [S3] Vein Motion | @min -5.0 | @max 5.0 | @sens 0.05 | @style 3
uniform vec4 u_s3_dark : source_color = vec4(0.0, 0.003, 0.01, 1.0); // @label [S3] Void | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_glow_color : source_color = vec4(0.0, 0.15, 0.7, 1.0); // @label [S3] Electric Blue | @min 0 | @max 1 | @sens 0.02 | @style 3
uniform vec4 u_s3_hot : source_color = vec4(0.4, 1.0, 0.1, 1.0); // @label [S3] Acid Green | @min 0 | @max 1 | @sens 0.02 | @style 3

// --- STYLE 4 : ADVANCED ---
uniform float u_a_q_motion_x = 0.20; // @label [ADV] Q Motion X | @min -5.0 | @max 5.0 | @sens 0.01 | @style 4
uniform float u_a_q_motion_y = 0.20; // @label [ADV] Q Motion Y | @min -5.0 | @max 5.0 | @sens 0.01 | @style 4
uniform float u_a_r_motion_x = 0.30; // @label [ADV] R Motion X | @min -5.0 | @max 5.0 | @sens 0.01 | @style 4
uniform float u_a_r_motion_y = 0.05; // @label [ADV] R Motion Y | @min -5.0 | @max 5.0 | @sens 0.01 | @style 4
uniform float u_a_q_offset_x = 5.2; // @label [ADV] Q Offset X | @min -20.0 | @max 20.0 | @sens 0.05 | @style 4
uniform float u_a_q_offset_y = 1.3; // @label [ADV] Q Offset Y | @min -20.0 | @max 20.0 | @sens 0.05 | @style 4
uniform float u_a_r_offset_x = 1.7; // @label [ADV] R Offset X | @min -20.0 | @max 20.0 | @sens 0.05 | @style 4
uniform float u_a_r_offset_y = 9.2; // @label [ADV] R Offset Y | @min -20.0 | @max 20.0 | @sens 0.05 | @style 4
uniform float u_a_q_influence = 12.0; // @label [ADV] Q -> R Influence | @min -20.0 | @max 20.0 | @sens 0.1 | @style 4
uniform float u_a_final_influence = 12.0; // @label [ADV] Final Warp Influence | @min -20.0 | @max 20.0 | @sens 0.1 | @style 4
uniform float u_a_q_frequency = 1.0; // @label [ADV] Q Frequency | @min 0.1 | @max 6.0 | @sens 0.05 | @style 4
uniform float u_a_r_frequency = 1.0; // @label [ADV] R Frequency | @min 0.1 | @max 6.0 | @sens 0.05 | @style 4
uniform float u_a_contrast = 1.5; // @label [ADV] Field Contrast | @min 0.1 | @max 5.0 | @sens 0.05 | @style 4
uniform vec4 u_a_dark : source_color = vec4(0.005, 0.0, 0.015, 1.0); // @label [ADV] Void | @min 0 | @max 1 | @sens 0.02 | @style 4
uniform vec4 u_a_mid : source_color = vec4(0.15, 0.02, 0.45, 1.0); // @label [ADV] Deep Purple | @min 0 | @max 1 | @sens 0.02 | @style 4
uniform vec4 u_a_hot : source_color = vec4(1.0, 0.12, 0.35, 1.0); // @label [ADV] Hot Pink | @min 0 | @max 1 | @sens 0.02 | @style 4

float fbm_hash2d(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float fbm_value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(fbm_hash2d(i), fbm_hash2d(i + vec2(1.0, 0.0)), u.x),
        mix(fbm_hash2d(i + vec2(0.0, 1.0)), fbm_hash2d(i + vec2(1.0)), u.x),
        u.y
    );
}

float fbm_octaves(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 8; i++) {
        if (float(i) >= u_noise_detail) break;
        value += amplitude * fbm_value_noise(p * frequency);
        frequency *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

vec4 fx_fbm_master(vec2 uv) {
    vec2 st = uv * u_warp_frequency;
    float time = u_time * u_flow_speed;
    vec2 q;
    vec2 r;

    if (u_render_mode == 4) {
        q = vec2(
            fbm_octaves(st * u_a_q_frequency + vec2(time * u_a_q_motion_x)),
            fbm_octaves(st * u_a_q_frequency + vec2(u_a_q_offset_x, u_a_q_offset_y) + time * u_a_q_motion_y)
        );
        r = vec2(
            fbm_octaves(st * u_a_r_frequency + u_a_q_influence * q + vec2(u_a_r_offset_x, u_a_r_offset_y) + time * u_a_r_motion_x),
            fbm_octaves(st * u_a_r_frequency + u_a_q_influence * q + vec2(8.3, 2.8) + time * u_a_r_motion_y)
        );
    } else {
        q = vec2(
            fbm_octaves(st + vec2(time * 0.2)),
            fbm_octaves(st + vec2(5.2, 1.3) + time * 0.15)
        );
        r = vec2(
            fbm_octaves(st + u_warp_strength * q + vec2(1.7, 9.2) + time * 0.3),
            fbm_octaves(st + u_warp_strength * q + vec2(8.3, 2.8) + time * 0.05)
        );
    }

    float field = u_render_mode == 4
        ? fbm_octaves(st + u_a_final_influence * r)
        : fbm_octaves(st + u_warp_strength * r);

    float mode_field = clamp(field * 1.5 + 0.3, 0.0, 1.0);
    int mode = u_render_mode;
    vec3 color = vec3(0.0);

    if (mode == 0) {
        float t = fract((field + length(q) * 0.3) * u_s0_frequency);
        t = clamp((t - 0.5) * u_s0_contrast + 0.5, 0.0, 1.0);
        float w1 = smoothstep(0.0, u_s0_split_1, t);
        float w2 = smoothstep(u_s0_split_1, u_s0_split_2, t);
        float w3 = smoothstep(u_s0_split_2, u_s0_split_3, t);
        color = mix(u_s0_1.rgb, u_s0_2.rgb, w1);
        color = mix(color, u_s0_3.rgb, w2);
        color = mix(color, u_s0_4.rgb, w3);
        color *= mode_field;
    }
    else if (mode == 1) {
        float x = field * u_s1_frequency + time * u_s1_cycle + u_s1_phase;
        vec3 wave = 0.5 + 0.5 * cos(
            6.28318 * (x + vec3(0.0, 0.33, 0.67)) * u_s1_spread
        );
        wave = clamp((wave - 0.5) * u_s1_contrast + 0.5, 0.0, 1.0);
        color = mix(u_s1_a.rgb, u_s1_b.rgb, wave.b);
        color = mix(color, u_s1_c.rgb, wave.r);
        color *= mode_field;
    }
    else if (mode == 2) {
        float morph = sin(u_time * u_s2_morph_speed) * 0.5 + 0.5;
        float shift = sin(length(q) * 5.0 + u_time * u_s2_color_shift) * 0.5 + 0.5;
        float n = clamp((field - 0.5) * u_s2_contrast + 0.5, 0.0, 1.0);
        vec3 mid = mix(u_s2_mid.rgb, u_s2_warm.rgb, morph);
        color = mix(u_s2_dark.rgb, mid, smoothstep(0.15, 0.6, n));
        color = mix(color, u_s2_hot.rgb, smoothstep(0.65, 0.95, n) * shift);
    }
    else if (mode == 3) {
        float pulse = sin(field * u_s3_density * 6.28318 + time * u_s3_motion * 2.0) * 0.5 + 0.5;
        float veins = smoothstep(u_s3_sharpness, u_s3_sharpness + 0.06, pulse);
        veins = clamp((veins - 0.5) * u_s3_contrast + 0.5, 0.0, 1.0);
        color = mix(u_s3_dark.rgb, u_s3_glow_color.rgb, field * 0.45);
        color = mix(color, u_s3_hot.rgb, veins);
        color += u_s3_hot.rgb * veins * u_s3_glow * 0.25;
    }
    else {
        float n = clamp((field - 0.5) * u_a_contrast + 0.5, 0.0, 1.0);
        float q_energy = clamp(length(q) * 0.7, 0.0, 1.0);
        float r_energy = clamp(length(r) * 0.7, 0.0, 1.0);
        float structure = clamp(n * 0.65 + q_energy * 0.2 + r_energy * 0.3, 0.0, 1.0);
        color = mix(u_a_dark.rgb, u_a_mid.rgb, smoothstep(0.05, 0.65, structure));
        color = mix(color, u_a_hot.rgb, smoothstep(0.55, 0.95, structure));
    }

    return vec4(color, 1.0);
}
"""




const SRC_KALEIDOSCOPE: String = """
uniform float u_segments = 6.0; // @label Slides | @min 1 | @max 32 | @sens 1
uniform float u_rotation_speed = 0.0; // @label Rotation Speed | @min -2 | @max 2 | @sens 0.05

vec2 fx_kaleidoscope(vec2 uv_in) {
	vec2 uv = uv_in - 0.5;
	float r = length(uv);
	float a = atan(uv.y, uv.x) + (u_time * u_rotation_speed);
	float angle_step = 2.0 * 3.14159265 / max(u_segments, 1.0);
	a = mod(a, angle_step);
	a = abs(a - angle_step * 0.5);
	return vec2(cos(a), sin(a)) * r + 0.5;
}
"""

const SRC_SWIRL: String = """
uniform vec2 u_center = vec2(0.5, 0.5); // @label Center | @min 0 | @max 1 | @sens 0.01
uniform float u_radius = 0.5; // @label Radius | @min 0.05 | @max 1.5 | @sens 0.02
uniform float u_strength = 3.0; // @label Twist Strength | @min -12 | @max 12 | @sens 0.25
uniform float u_rotation_speed = 0.0; // @label Rotation Speed | @min -2 | @max 2 | @sens 0.05

vec2 fx_swirl(vec2 uv) {
	vec2 p = uv - u_center;
	float falloff = 1.0 - smoothstep(0.0, u_radius, length(p));
	float ang = u_strength * falloff + u_time * u_rotation_speed;
	float s = sin(ang);
	float c = cos(ang);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y) + u_center;
}
"""

const SRC_EDGE_GLOW: String = """
uniform float u_edge_threshold = 0.15; // @label Edge Threshold | @min 0 | @max 1 | @sens 0.01
uniform float u_glow_intensity = 2.5; // @label Glow Intensity | @min 0 | @max 8 | @sens 0.1
uniform vec2 u_step_offset = vec2(0.003, 0.003); // @label Step Offset | @min 0.0005 | @max 0.02 | @sens 0.0005
uniform float u_cel_bands = 5.0; // @label Cel Shade Bands | @min 2.0 | @max 12.0 | @sens 1.0

vec3 quantize_cel(vec3 color, float bands) {
	return floor(color * bands) / bands;
}

vec4 fx_edge_glow(vec2 uv) {
	vec4 center_color = texture(u_warped_texture, uv);
	float c = (center_color.r + center_color.g + center_color.b) / 3.0;
	
	float left = texture(u_warped_texture, uv - vec2(u_step_offset.x, 0.0)).g;
	float right = texture(u_warped_texture, uv + vec2(u_step_offset.x, 0.0)).g;
	float up = texture(u_warped_texture, uv - vec2(0.0, u_step_offset.y)).g;
	float down = texture(u_warped_texture, uv + vec2(0.0, u_step_offset.y)).g;
	
	float edge_delta = abs(c - left) + abs(c - right) + abs(c - up) + abs(c - down);
	float edge_mask = smoothstep(u_edge_threshold, u_edge_threshold + 0.1, edge_delta);
	vec3 glowing_borders = center_color.rgb * edge_mask * u_glow_intensity;
	
	vec3 raw_composite = center_color.rgb + glowing_borders;
	vec3 cel_shaded = quantize_cel(raw_composite, u_cel_bands);
	
	return vec4(cel_shaded, center_color.a);
}
"""
