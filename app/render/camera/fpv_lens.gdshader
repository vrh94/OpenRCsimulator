// CAM-12 / FPV-3: the onboard camera's wide-angle lens. Remaps a supersampled rectilinear render (fpv_lens.gd) to a
// radially symmetric lens projection. Output point p (half-height units, y up), r = |p|:
//   model 0 "barrel"  (stereographic): r = 2 f tan(θ/2)  →  θ = 2 atan(r / 2f)
//   model 1 "fisheye" (equidistant):   r = f θ           →  θ = r / f
// The ray at θ lands in the rectilinear source at tan(θ) · p / r; the source spans ±tan_extent. Rays beyond the
// source or beyond 89° fall off into the lens's dark rim. The math is mirrored by fpv_lens.gd source_point().
shader_type canvas_item;

uniform sampler2D source : filter_linear, repeat_disable;
uniform float aspect = 1.7777778;
uniform float focal = 1.0;
uniform int model = 0;
uniform vec2 tan_extent = vec2(1.6, 0.9);
uniform float vignette = 0.25;
uniform float theta_corner = 1.0;

const float THETA_LIMIT = 1.5533430; // 89°
const float RIM = 0.03; // share of the source edge over which the picture fades into the rim

void fragment() {
	vec2 p = vec2((UV.x * 2.0 - 1.0) * aspect, 1.0 - UV.y * 2.0);
	float r = length(p);
	float theta = model == 0 ? 2.0 * atan(r / (2.0 * focal)) : r / focal;
	if (theta >= THETA_LIMIT) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 s = r > 1e-6 ? tan(theta) * p / r : p / focal;
		vec2 q = s / tan_extent;
		float edge = max(abs(q.x), abs(q.y));
		vec3 c = texture(source, vec2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y)).rgb;
		float rim = 1.0 - smoothstep(1.0 - RIM, 1.0, edge);
		float t = theta / max(theta_corner, 1e-3);
		float shade = 1.0 - vignette * t * t;
		COLOR = vec4(c * rim * shade, 1.0);
	}
}
