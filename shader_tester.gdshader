shader_type canvas_item;

uniform float split_y : hint_range(0.0, 0.5) = 0.25; 
uniform float line_thickness : hint_range(0.000, 0.150) = 0.001;
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

uniform float wave_amplitude : hint_range(0.0, 0.2) = 0.05;
uniform float wave_frequency : hint_range(0.0, 20.0) = 6.28;
uniform float wave_speed : hint_range(0.0, 5.0) = 2.0;

// -- CENTRAL ZONE (FBM Warping the Truchet Grid) --
uniform float truchet_scale_center = 15.0;
uniform float truchet_warp_strength : hint_range(0.0, 1.0) = 0.25;
uniform vec4 truchet_color_a : source_color = vec4(0.1, 0.4, 0.8, 1.0); 
uniform vec4 truchet_color_b : source_color = vec4(0.05, 0.15, 0.4, 1.0); 

// -- OUTER ZONES (Truchet Grid Warping the FBM Fluid) --
uniform float truchet_scale_outer = 20.0;
uniform float fbm_warp_strength : hint_range(0.0, 2.0) = 0.8; // How hard the triangles break the fluid

uniform float fbm_scale = 4.0;
uniform float fbm_speed = 0.3;
uniform float fbm_swirl_intensity : hint_range(0.0, 10.0) = 3.0;
uniform int fbm_octaves : hint_range(2, 8) = 6;

uniform vec4 fbm_bg_color : source_color = vec4(0.02, 0.02, 0.08, 1.0);
uniform vec4 fbm_mid_color : source_color = vec4(0.8, 0.2, 0.5, 1.0);
uniform vec4 fbm_high_color : source_color = vec4(1.0, 0.7, 0.3, 1.0);

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	
	return mix(mix(dot(hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0)), 
				   dot(hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
			   mix(dot(hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)), 
				   dot(hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x), u.y) + 0.5;
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	float frequency = 1.0;
	for (int i = 0; i < 8; i++) {
		if (i >= fbm_octaves) break;
		value += amplitude * noise(p * frequency);
		frequency *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

// Helper to quickly calculate a sharp triangle layout value (-1.0 to 1.0 range)
vec2 get_truchet_vector(vec2 incoming_uv, float scale) {
	vec2 scaled = incoming_uv * scale;
	vec2 index = floor(scaled);
	vec2 local = fract(scaled);
	float checker = mod(index.x + index.y, 2.0);
	
	float mask = (checker < 1.0) ? step(local.x, local.y) : step(local.x, 1.0 - local.y);
	// Convert 0.0 / 1.0 mask into directional offset values
	return vec2(mask * 2.0 - 1.0, (1.0 - mask) * 2.0 - 1.0);
}

// Reusable calculation block for the primary FBM fluid stream
float get_fluid_intensity(vec2 sample_uv, float time) {
	vec2 base = sample_uv * fbm_scale;
	vec2 q = vec2(
		fbm(base + vec2(0.0, 0.0) + vec2(time, time * 0.5)),
		fbm(base + vec2(5.2, 1.3) + vec2(-time * 0.2, time))
	);
	vec2 r = vec2(
		fbm(base + 4.0 * q + vec2(1.7, 9.2) + vec2(time * 0.4, -time * 0.1)),
		fbm(base + 4.0 * q + vec2(8.3, 2.8) + vec2(-time * 0.3, time * 0.5))
	);
	return fbm(base + fbm_swirl_intensity * r);
}

void fragment() {
	vec2 uv = UV;
	float mirrored_y = abs(uv.y - 0.5); 
	vec4 final_color = vec4(0.0);
	
	float wave = sin(uv.x * wave_frequency + TIME * wave_speed) * wave_amplitude;
	float current_split = (0.5 - split_y) + wave;
	float half_line = line_thickness * 0.5;
	
	float is_line = step(current_split - half_line, mirrored_y) * (1.0 - step(current_split + half_line, mirrored_y));
	float t = TIME * fbm_speed;

	// --- Outer Edge Zones (Truchet Grid distorting the FBM Fluid) ---
	if (mirrored_y > current_split + half_line) {
		// 1. Calculate triangle coordinates first
		vec2 truchet_displace = get_truchet_vector(uv, truchet_scale_outer);
		
		// 2. Inject the blocky triangle directions straight into the fluid's UV coordinates
		vec2 shattered_uv = uv + truchet_displace * fbm_warp_strength * 0.05;
		
		// 3. Render the FBM fluid using the shattered coordinates
		float outer_fluid = get_fluid_intensity(shattered_uv, t);
		
		vec4 color_blend = mix(fbm_bg_color, fbm_mid_color, smoothstep(0.1, 0.5, outer_fluid));
		final_color = mix(color_blend, fbm_high_color, smoothstep(0.45, 0.8, outer_fluid));
	} 
	// --- Inner Center Zone (FBM Fluid distorting the Truchet Grid) ---
	else if (mirrored_y < current_split - half_line) {
		// 1. Sample natural fluid noise first
		float center_fluid = get_fluid_intensity(uv, t);
		
		// 2. Wrap the coordinates organically using the noise intensity
		vec2 warped_uv = uv + vec2(center_fluid, fbm(uv * fbm_scale + t)) * truchet_warp_strength;
		
		// 3. Render standard triangle patterns over the curved coordinates
		vec2 truchet_uv = warped_uv * truchet_scale_center;
		vec2 grid_index = floor(truchet_uv);
		vec2 local_uv = fract(truchet_uv);
		
		float checker = mod(grid_index.x + grid_index.y, 2.0);
		float triangle_mask = (checker < 1.0) ? step(local_uv.x, local_uv.y) : step(local_uv.x, 1.0 - local_uv.y);
		
		final_color = mix(truchet_color_a, truchet_color_b, triangle_mask);
	}
	
	final_color = mix(final_color, line_color, is_line);
	COLOR = final_color;
}
