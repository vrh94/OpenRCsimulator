// Triglav buildings (buildings.gd): roofs take the orthophoto's colour at their position, walls are plaster; the
// haze matches the terrain (terrain.gdshader).
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D photo : source_color, filter_linear_mipmap, repeat_disable;
uniform bool photo_enabled = true;
uniform float photo_size_m = 8000.0;
uniform vec2 pilot_core;
uniform vec3 roof_colour : source_color = vec3(0.35, 0.22, 0.18);
uniform vec3 wall_colour : source_color = vec3(0.78, 0.75, 0.69);

uniform vec3 haze_lin = vec3(0.584, 0.768, 0.846);
uniform vec3 sun_dir = vec3(0.0, 0.707, 0.707);
uniform vec3 sun_lin = vec3(3.14159);
uniform float sun_scatter = 0.0;
uniform float beta = 0.00017;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 col = wall_colour;
	if (world_normal.y > 0.3) {
		col = roof_colour;
		if (photo_enabled) {
			vec2 core_xy = vec2(pilot_core.x + world_pos.x, pilot_core.y - world_pos.z);
			col = texture(photo, vec2(core_xy.x / photo_size_m, 1.0 - core_xy.y / photo_size_m)).rgb;
		}
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	float dist = length(VERTEX);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	vec3 haze = haze_lin + sun_lin * pow(max(dot(v, sun_dir), 0.0), 8.0) * sun_scatter;
	FOG = vec4(haze, 1.0 - exp(-beta * dist));
}
