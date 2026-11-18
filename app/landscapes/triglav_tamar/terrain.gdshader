// Triglav (Planica/Tamar) terrain: one shared 64 x 64 grid tile, scaled and placed per quadtree node by its
// transform (terrain_view.gd). Heights come from the baked grids (heightfield.gd) as RG8 textures (red the low byte,
// green the high byte of the uint16 value), read with texelFetch and interpolated here. Tiles finer than
// `core_max_spacing_m` read the 2 m core inside the core; coarser tiles and everything outside read the 16 m ring.
// Skirts (VERTEX.y = 1 on the mesh) hang below the tile edges and hide cracks between levels.
// Colour: the 2023-25 orthophoto inside the core, alpine shading from slope and height elsewhere; the haze is the
// ground shader's custom FOG (render/ground.gdshader) without its flat-ground rim fade.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D core_h : filter_nearest, repeat_disable;
uniform vec2 core_origin;          // core frame metres of node (0, 0)
uniform float core_spacing = 2.0;
uniform ivec2 core_size = ivec2(4000, 4000);
uniform float core_base = 600.0;
uniform float core_step = 0.03125;
uniform sampler2D ring_h : filter_nearest, repeat_disable;
uniform vec2 ring_origin;
uniform float ring_spacing = 16.0;
uniform ivec2 ring_size = ivec2(1500, 1500);
uniform float ring_base = 600.0;
uniform float ring_step = 0.03125;
uniform float core_max_spacing_m = 6.0;
uniform float core_blend_m = 96.0;   // core to ring blend band inside the core edge

uniform vec2 pilot_core;             // the render origin in the core frame
uniform float ground_ref_m;          // the terrain height at the render origin (render y = 0)
uniform float skirt_m = 24.0;

uniform sampler2D photo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D photo_coverage : filter_linear, repeat_disable;
uniform float photo_size_m = 8000.0;
uniform bool photo_enabled = true;
// Near the camera the 1 m photo is soft: a CC0 aerial grass-and-rock texture modulates its brightness at two scales.
uniform sampler2D near_detail : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool near_detail_enabled = false;
uniform float near_detail_tile_m = 6.0;
uniform float near_detail_end_m = 320.0;
uniform float near_detail_strength = 0.85;

uniform vec3 haze_lin = vec3(0.584, 0.768, 0.846);
uniform vec3 sun_dir = vec3(0.0, 0.707, 0.707);
uniform vec3 sun_lin = vec3(3.14159);
uniform float sun_scatter = 0.0;
uniform vec3 lobe_lin = vec3(0.0);
uniform vec3 lobe_dir = vec3(1.0, 0.0, 0.0);
uniform float lobe_k = 8.0;
uniform float lobe_height = 1.5708;
uniform float beta = 0.00017;

varying vec2 core_xy;    // east, north in the core frame
varying float tile_spacing;

float decode(vec4 texel, float base, float stp) {
	return base + (round(texel.r * 255.0) + round(texel.g * 255.0) * 256.0) * stp;
}

float grid_height(sampler2D tex, vec2 origin, float spacing, ivec2 size, float base, float stp, vec2 p) {
	vec2 t = (p - origin) / spacing;
	vec2 cell = floor(t);
	vec2 f = clamp(t - cell, 0.0, 1.0);
	ivec2 i0 = clamp(ivec2(cell), ivec2(0), size - 1);
	ivec2 i1 = clamp(ivec2(cell) + 1, ivec2(0), size - 1);
	// Image rows run south to north and the texture's first row is row 0, so t.y indexes rows directly.
	float h00 = decode(texelFetch(tex, ivec2(i0.x, i0.y), 0), base, stp);
	float h10 = decode(texelFetch(tex, ivec2(i1.x, i0.y), 0), base, stp);
	float h01 = decode(texelFetch(tex, ivec2(i0.x, i1.y), 0), base, stp);
	float h11 = decode(texelFetch(tex, ivec2(i1.x, i1.y), 0), base, stp);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float ring_height(vec2 p) {
	return grid_height(ring_h, ring_origin, ring_spacing, ring_size, ring_base, ring_step, p);
}

// How far inside the core a point is (metres; negative outside).
float core_inset(vec2 p) {
	vec2 lo = core_origin;
	vec2 hi = core_origin + vec2(core_size - 1) * core_spacing;
	return min(min(p.x - lo.x, hi.x - p.x), min(p.y - lo.y, hi.y - p.y));
}

float terrain_height(vec2 p, bool fine) {
	float ring = ring_height(p);
	if (!fine) return ring;
	float w = smoothstep(0.0, core_blend_m, core_inset(p));
	if (w <= 0.0) return ring;
	float core = grid_height(core_h, core_origin, core_spacing, core_size, core_base, core_step, p);
	return mix(ring, core, w);
}

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX.x, 0.0, VERTEX.z, 1.0)).xyz;
	tile_spacing = length(MODEL_MATRIX[0].xyz) / 64.0;
	core_xy = vec2(pilot_core.x + world.x, pilot_core.y - world.z);
	float h = terrain_height(core_xy, tile_spacing <= core_max_spacing_m);
	float skirt = VERTEX.y * max(skirt_m, tile_spacing * 3.0);
	VERTEX.y = h - ground_ref_m - skirt;
	// Vertex normal from the tile's own spacing; the fragment refines it near the camera.
	float d = max(tile_spacing, 2.0);
	bool fine = tile_spacing <= core_max_spacing_m;
	float he = terrain_height(core_xy + vec2(d, 0.0), fine);
	float hw = terrain_height(core_xy - vec2(d, 0.0), fine);
	float hn = terrain_height(core_xy + vec2(0.0, d), fine);
	float hs = terrain_height(core_xy - vec2(0.0, d), fine);
	vec3 n = normalize(vec3(-(he - hw) / (2.0 * d), 1.0, (hn - hs) / (2.0 * d)));
	// The tile is scaled (S, 1, S); Godot maps NORMAL by the inverse transpose, so pre-multiply by the scale.
	float s = tile_spacing * 64.0;
	NORMAL = normalize(vec3(n.x * s, n.y, n.z * s));
}

vec3 lobe_term(vec3 dir) {
	if (all(equal(lobe_lin, vec3(0.0)))) return vec3(0.0);
	float h = max(length(dir.xz), 1e-4);
	float az = max(dot(dir.xz / h, normalize(lobe_dir.xz + vec2(1e-6, 0.0))), 0.0);
	return lobe_lin * pow(az, lobe_k) * exp(-max(asin(clamp(dir.y, -1.0, 1.0)), 0.0) / lobe_height);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0)), f.x), f.y);
}

// Summer Julian Alps without a photo: spruce and beech forest below the tree line, alpine grass above it, grey
// limestone on steep ground and high up.
vec3 alpine_colour(vec2 p, float h, float slope) {
	float n = value_noise(p / 90.0) * 0.6 + value_noise(p / 23.0) * 0.4;
	vec3 forest = mix(vec3(0.045, 0.075, 0.035), vec3(0.075, 0.10, 0.045), n);
	vec3 grass = mix(vec3(0.17, 0.20, 0.09), vec3(0.24, 0.25, 0.13), n);
	vec3 rock = mix(vec3(0.34, 0.33, 0.30), vec3(0.46, 0.45, 0.42), n);
	float tree_line = 1650.0 + 120.0 * (n - 0.5);
	vec3 col = mix(forest, grass, smoothstep(tree_line - 60.0, tree_line + 60.0, h));
	float rocky = max(smoothstep(0.42, 0.62, slope), smoothstep(2050.0, 2250.0, h + 150.0 * n));
	return mix(col, rock, rocky);
}

void fragment() {
	vec3 world_n;
	float dist = length(VERTEX);
	bool fine = dist < 2500.0 && core_inset(core_xy) > 0.0;
	if (fine) {
		float d = core_spacing;
		float he = terrain_height(core_xy + vec2(d, 0.0), true);
		float hw = terrain_height(core_xy - vec2(d, 0.0), true);
		float hn = terrain_height(core_xy + vec2(0.0, d), true);
		float hs = terrain_height(core_xy - vec2(0.0, d), true);
		world_n = normalize(vec3(-(he - hw) / (2.0 * d), 1.0, (hn - hs) / (2.0 * d)));
	} else {
		world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	}
	float h = ground_ref_m + (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	vec3 col = alpine_colour(core_xy, h, 1.0 - world_n.y);
	vec2 uv = vec2(core_xy.x / photo_size_m, 1.0 - core_xy.y / photo_size_m);
	if (photo_enabled && all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		float real = texture(photo_coverage, uv).r;
		col = mix(col, texture(photo, uv).rgb, real);
	}
	if (near_detail_enabled && dist < near_detail_end_m) {
		float mean = dot(textureLod(near_detail, vec2(0.5), 12.0).rgb, vec3(1.0 / 3.0));
		float a = dot(texture(near_detail, core_xy / near_detail_tile_m).rgb, vec3(1.0 / 3.0));
		float b = dot(texture(near_detail, core_xy / (near_detail_tile_m * 3.7) + 0.31).rgb, vec3(1.0 / 3.0));
		float factor = clamp((a * 0.6 + b * 0.4) / max(mean, 1e-3), 0.4, 1.8);
		float w = near_detail_strength * (1.0 - smoothstep(near_detail_end_m * 0.3, near_detail_end_m, dist));
		col *= mix(1.0, factor, w);
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	vec3 haze = haze_lin + sun_lin * pow(max(dot(v, sun_dir), 0.0), 8.0) * sun_scatter + lobe_term(v);
	FOG = vec4(haze, 1.0 - exp(-beta * dist));
}
