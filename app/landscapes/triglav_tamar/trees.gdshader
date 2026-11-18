// Triglav trees (trees.gd): low-poly spruce and broadleaf meshes instanced per 250 m chunk. COLOR.r = 1 marks
// trunk vertices. Crowns take their tint from the orthophoto at the tree, so larch, beech and spruce keep their
// real summer colours; the haze matches the terrain (terrain.gdshader).
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D photo : source_color, filter_linear_mipmap, repeat_disable;
uniform bool photo_enabled = true;
uniform float photo_size_m = 8000.0;
uniform vec2 pilot_core;
uniform vec3 conifer_colour : source_color = vec3(0.10, 0.16, 0.09);
uniform vec3 broadleaf_colour : source_color = vec3(0.17, 0.26, 0.10);
uniform vec3 trunk_colour : source_color = vec3(0.20, 0.14, 0.09);
uniform float photo_tint = 0.65;
uniform bool broadleaf = false;

uniform vec3 haze_lin = vec3(0.584, 0.768, 0.846);
uniform vec3 sun_dir = vec3(0.0, 0.707, 0.707);
uniform vec3 sun_lin = vec3(3.14159);
uniform float sun_scatter = 0.0;
uniform float beta = 0.00017;

varying vec3 crown;

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 base = broadleaf ? broadleaf_colour : conifer_colour;
	crown = base;
	if (photo_enabled) {
		vec2 core_xy = vec2(pilot_core.x + origin.x, pilot_core.y - origin.z);
		vec2 uv = vec2(core_xy.x / photo_size_m, 1.0 - core_xy.y / photo_size_m);
		vec3 tint = textureLod(photo, uv, 3.0).rgb;
		crown = mix(base, tint, photo_tint);
	}
	// A little variation between neighbours.
	float h = fract(sin(dot(origin.xz, vec2(12.9898, 78.233))) * 43758.5453);
	crown *= 0.85 + 0.3 * h;
}

void fragment() {
	ALBEDO = COLOR.r > 0.5 ? trunk_colour : crown;
	ROUGHNESS = 1.0;
	float dist = length(VERTEX);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	vec3 haze = haze_lin + sun_lin * pow(max(dot(v, sun_dir), 0.0), 8.0) * sun_scatter;
	FOG = vec4(haze, 1.0 - exp(-beta * dist));
}
