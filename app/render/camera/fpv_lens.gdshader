// CAM-12 / FPV-3/4: the onboard camera's lens and video. Remaps a supersampled rectilinear render (fpv_lens.gd) to a
// radially symmetric lens projection. Output point p (half-height units, y up), r = |p|:
//   model 0 "barrel"      (stereographic): r = 2 f tan(θ/2)  →  θ = 2 atan(r / 2f)
//   model 1 "fisheye"     (equidistant):   r = f θ           →  θ = r / f
//   model 2 "rectilinear" (pinhole):       r = f tan θ       →  the source point is p / f (no warp; video effects only)
// The ray at θ lands in the rectilinear source at tan(θ) · p / r; the source spans ±tan_extent. Rays beyond the
// source or beyond 89° fall off into the lens's dark rim. The geometry is mirrored by fpv_lens.gd source_point().
// FPV-4: optional rotational motion blur (taps along the source points the same ray had over the shutter, from the
// camera-space rotation blur_rotation) and video noise (per-pixel grain, deterministic in noise_time).
shader_type canvas_item;

uniform sampler2D source : filter_linear, repeat_disable;
uniform float aspect = 1.7777778;
uniform float focal = 1.0;
uniform int model = 0;
uniform vec2 tan_extent = vec2(1.6, 0.9);
uniform float vignette = 0.25;
uniform float theta_corner = 1.0;
uniform bool blur_on = false;
uniform mat3 blur_rotation = mat3(1.0);
uniform float noise_amount = 0.0;
uniform float noise_time = 0.0;
uniform vec2 picture_size = vec2(1920.0, 1080.0);

const float THETA_LIMIT = 1.5533430; // 89°
const float RIM = 0.03; // share of the source edge over which the picture fades into the rim
const int BLUR_TAPS = 6;

vec2 source_uv(vec2 s) {
	vec2 q = s / tan_extent;
	return vec2(0.5 + 0.5 * q.x, 0.5 - 0.5 * q.y);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 p = vec2((UV.x * 2.0 - 1.0) * aspect, 1.0 - UV.y * 2.0);
	float r = length(p);
	float theta = model == 0 ? 2.0 * atan(r / (2.0 * focal)) : (model == 1 ? r / focal : atan(r / focal));
	if (theta >= THETA_LIMIT) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec2 s = model == 2 ? p / focal : (r > 1e-6 ? tan(theta) * p / r : p / focal);
		vec2 q = s / tan_extent;
		float edge = max(abs(q.x), abs(q.y));
		vec3 c;
		if (blur_on) {
			// Camera space: x right, y up, the view along −z. The same ray over the shutter, from now back in time.
			vec3 d = vec3(s, -1.0);
			vec3 d_then = blur_rotation * d;
			vec2 s_then = d_then.z < -1e-3 ? d_then.xy / -d_then.z : s;
			c = vec3(0.0);
			for (int i = 0; i < BLUR_TAPS; i++) {
				float k = float(i) / float(BLUR_TAPS - 1);
				c += texture(source, source_uv(mix(s, s_then, k))).rgb;
			}
			c /= float(BLUR_TAPS);
		} else {
			c = texture(source, source_uv(s)).rgb;
		}
		float rim = 1.0 - smoothstep(1.0 - RIM, 1.0, edge);
		float t = theta / max(theta_corner, 1e-3);
		float shade = 1.0 - vignette * t * t;
		c *= rim * shade;
		if (noise_amount > 0.0) {
			// Analog-style grain: luminance noise with a little chroma, new every video frame.
			vec2 cell = floor(UV * picture_size);
			float frame = floor(noise_time * 60.0);
			float n = hash12(cell + frame * 17.0) - 0.5;
			vec3 chroma = vec3(hash12(cell + frame * 29.0 + 3.1), hash12(cell + frame * 31.0 + 7.7), hash12(cell + frame * 37.0 + 1.3)) - 0.5;
			c = max(c + noise_amount * (n + 0.3 * chroma) * (0.35 + c), vec3(0.0));
		}
		COLOR = vec4(c, 1.0);
	}
}
