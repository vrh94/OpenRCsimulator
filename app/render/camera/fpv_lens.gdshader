// CAM-12 / FPV-3/4: the onboard camera's lens and video. Remaps a supersampled rectilinear render (fpv_lens.gd) to a
// radially symmetric lens projection. Output point p (half-height units, y up), r = |p|:
//   model 0 "barrel"      (stereographic): r = 2 f tan(θ/2)  →  θ = 2 atan(r / 2f)
//   model 1 "fisheye"     (equidistant):   r = f θ           →  θ = r / f
//   model 2 "rectilinear" (pinhole):       r = f tan θ       →  the source point is p / f (no warp; video effects only)
// The ray at θ lands in the rectilinear source at tan(θ) · p / r; the source spans ±tan_extent. Rays beyond the
// source or beyond 89° fall off into the lens's dark rim. The geometry is mirrored by fpv_lens.gd source_point().
// FPV-4: optional rotational motion blur (taps along the source points the same ray had over the shutter, from the
// camera-space rotation blur_rotation) and video noise (per-pixel grain, deterministic in noise_time).
// FPV-7: analog link breakup (0 clean … 1 lost, video_link.gd): torn and jittering lines, colour loss, snow and
// dropout streaks that grow as the link fades, full static when it is lost. Deterministic in noise_time.
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
uniform float breakup = 0.0;

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
	float frame = floor(noise_time * 60.0);
	float line = floor(UV.y * picture_size.y / 3.0); // bands of three lines, like an analog sync error
	if (breakup > 0.0) {
		// Torn lines: some bands slip sideways; the whole picture jitters vertically as sync is lost.
		float tear = hash12(vec2(line, frame * 3.0 + 11.0));
		if (tear < breakup * breakup * breakup * 0.5) {
			p.x += (hash12(vec2(line * 1.7, frame + 5.0)) - 0.5) * 0.3 * breakup;
		}
		p.y += (hash12(vec2(frame, 19.0)) - 0.5) * 0.06 * breakup * breakup;
	}
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
			float n = hash12(cell + frame * 17.0) - 0.5;
			vec3 chroma = vec3(hash12(cell + frame * 29.0 + 3.1), hash12(cell + frame * 31.0 + 7.7), hash12(cell + frame * 37.0 + 1.3)) - 0.5;
			c = max(c + noise_amount * (n + 0.3 * chroma) * (0.35 + c), vec3(0.0));
		}
		if (breakup > 0.0) {
			vec2 cell = floor(UV * picture_size * 0.5); // analog snow is coarser than the display pixels
			float snow = hash12(cell + frame * 43.0);
			float luma = dot(c, vec3(0.299, 0.587, 0.114));
			c = mix(c, vec3(luma), smoothstep(0.3, 0.85, breakup)); // colour drops out as the signal weakens
			c = mix(c, vec3(snow), clamp(pow(breakup, 2.5), 0.0, 1.0));
			if (hash12(vec2(line * 0.37, frame * 7.0 + 2.0)) < breakup * breakup * 0.06) {
				c = vec3(0.6 + 0.4 * snow); // a white dropout streak
			}
		}
		COLOR = vec4(c, 1.0);
	}
}
