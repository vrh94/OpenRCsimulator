// Option 7b: Ljubljana's far skyline (city.gd). Each instance is one 12.5 m block of the GURS CLSS 2023-25 roofs;
// its instance colour is the roof's sRGB colour, the walls are plaster shaded by it. The haze matches the terrain
// (landscapes/triglav_tamar/terrain.gdshader) so the city fades into the distance like the ground under it.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

uniform vec3 wall_colour : source_color = vec3(0.74, 0.72, 0.68);

uniform vec3 haze_lin = vec3(0.584, 0.768, 0.846);
uniform vec3 sun_dir = vec3(0.0, 0.707, 0.707);
uniform vec3 sun_lin = vec3(3.14159);
uniform float sun_scatter = 0.0;
uniform float beta = 0.00017;

varying vec3 roof_lin;
varying float roof_face;

vec3 srgb_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void vertex() {
	roof_lin = srgb_to_linear(COLOR.rgb);
	roof_face = step(0.5, NORMAL.y);
}

void fragment() {
	// Walls: plaster, a little of the roof's tint so concrete blocks and red-roofed houses differ at a distance.
	vec3 wall = mix(wall_colour, roof_lin, 0.35);
	ALBEDO = mix(wall, roof_lin, roof_face);
	ROUGHNESS = 1.0;
	float dist = length(VERTEX);
	vec3 v = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	vec3 haze = haze_lin + sun_lin * pow(max(dot(v, sun_dir), 0.0), 8.0) * sun_scatter;
	FOG = vec4(haze, 1.0 - exp(-beta * dist));
}
