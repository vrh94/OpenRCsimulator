// CLOUD-1 (2026-11-22): one cumulus cloud you can fly around and through. The mesh is a unit box scaled (never
// rotated) to the cloud's bounds; its back faces are drawn so the cloud still shows from inside. The fragment marches
// the view ray through the box up to the scene depth (terrain, scenery and aircraft in front hide the cloud; the
// pilot inside it sees white-out) and accumulates a cauliflower density: a flat-based dome eroded by tiling 3D
// noise. Presentation only: nothing here reaches the flight.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, depth_test_disabled, fog_disabled, blend_mix, shadows_disabled;
#include "res://render/world/engine_srgb.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler3D noise_texture : filter_linear, repeat_enable;
uniform vec3 cloud_lin = vec3(0.95);       // the sky's lit cloud colour (scene-linear)
uniform vec3 shade_lin = vec3(0.40, 0.45, 0.54); // the shaded underside: the sky's zenith and haze light
uniform vec3 haze_lin = vec3(0.58, 0.77, 0.85);
uniform float haze_density = 0.00005;      // per metre, as the storm bank
uniform vec3 sun_dir = vec3(0.0, 0.707, 0.707); // toward the sun
uniform float extinction = 0.035;          // per metre at full density (≈ 30 m visibility deep inside)
uniform float detail_scale_m = 170.0;      // metres per noise tile (cauliflower)
uniform float near_step_m = 14.0;          // march step near the camera
uniform float far_step_m = 45.0;           // and at far_steps_distance_m
uniform int max_steps = 40;                // a long path through a big cloud takes longer steps
uniform float far_steps_distance_m = 6000.0;
uniform float fine_detail_distance_m = 1500.0;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float view_depth_at(vec2 screen_uv, mat4 inverse_projection) {
	float raw_depth = textureLod(depth_texture, screen_uv, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth * 2.0 - 1.0);
#else
	vec3 ndc = vec3(screen_uv * 2.0 - 1.0, raw_depth);
#endif
	vec4 view = inverse_projection * vec4(ndc, 1.0);
	return -view.z / view.w;
}

// Density in [0, 1] at world point p of the cloud whose box has centre c and size s. A flat base, a wide body and a
// dome, bulged per cloud by large lobes (noise in the box's own coordinates) and carved into cauliflower by world-
// scale detail. Everything stays inside 0.9 of the box, so a box face never cuts a cloud.
float cloud_density(vec3 p, vec3 c, vec3 s, vec3 seed_shift, bool fine) {
	vec3 q = (p - c) / s;                 // [-0.5, 0.5]
	float y = q.y + 0.5;                  // 0 at the base, 1 at the top
	float r = length(q.xz) * 2.0;         // 0 at the axis, 1 at the box's side
	// Lobes vary faster with height than across, so towers grow stacked turrets instead of straight sides.
	float lobes = texture(noise_texture, vec3(q.x * 0.85, q.y * 1.7, q.z * 0.85) + seed_shift * 0.00031).r;
	float body = mix(0.5, 0.6, smoothstep(0.0, 0.25, y));
	float dome = (y - 0.25) / 0.6;
	float cap = 1.0 - dome * dome;
	float envelope = y < 0.25 ? body : 0.6 * (cap > 0.0 ? sqrt(cap) : -sqrt(-cap));
	envelope += (lobes - 0.5) * 0.5;
	float d = (envelope - r) * 3.0;
	d += (texture(noise_texture, (p + seed_shift) / detail_scale_m).r - 0.5) * 0.55;
	if (fine) {
		d += (texture(noise_texture, (p + seed_shift * 1.3) / (detail_scale_m * 0.32)).r - 0.5) * 0.22;
	}
	return clamp(d * 1.8, 0.0, 1.0) * smoothstep(0.0, 0.035, y);
}

// Interleaved gradient noise: a smooth per-pixel start offset that hides step banding with little grain.
float hash12(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 rd = normalize(world_position - ro);
	vec3 c = MODEL_MATRIX[3].xyz;
	vec3 s = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec3 half_size = s * 0.5;
	vec3 inv = 1.0 / rd;
	vec3 t0 = (c - half_size - ro) * inv;
	vec3 t1 = (c + half_size - ro) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	float t_near = max(max(max(tmin.x, tmin.y), tmin.z), 0.0);
	float t_far = min(min(tmax.x, tmax.y), tmax.z);
	// Stop at whatever is drawn in front (terrain, trees, the airplane). Depth is along the view axis.
	vec3 forward = -normalize(INV_VIEW_MATRIX[2].xyz);
	float scene_t = view_depth_at(SCREEN_UV, INV_PROJECTION_MATRIX) / max(dot(rd, forward), 1.0e-4);
	t_far = min(t_far, scene_t);
	if (t_far <= t_near) {
		discard;
	}
	// Steps of a fixed length near the camera, longer far away; empty space is crossed in double steps.
	float step_m = mix(near_step_m, far_step_m, clamp(t_near / far_steps_distance_m, 0.0, 1.0));
	float dt = max(step_m, (t_far - t_near) / float(max_steps));
	float t = t_near + dt * hash12(FRAGCOORD.xy);
	bool fine = t_near < fine_detail_distance_m;
	vec3 seed_shift = vec3(fract(c.x * 0.0137) * 3000.0, 0.0, fract(c.z * 0.0191) * 3000.0);
	vec3 light_step = normalize(sun_dir) * min(min(s.x, s.y) * 0.16, 140.0);
	float transmittance = 1.0;
	vec3 radiance = vec3(0.0);
	float weighted_t = 0.0;
	bool coarse = true;
	bool refined = false;
	for (int i = 0; i < 72; i++) {
		if (t >= t_far || transmittance < 0.03) {
			break;
		}
		vec3 p = ro + rd * t;
		float d = cloud_density(p, c, s, seed_shift, fine);
		if (d > 0.001) {
			if (coarse && !refined) {
				// Entered the cloud in a double step: go back one step, once, so the edge is sampled finely.
				coarse = false;
				refined = true;
				t = max(t - dt, t_near);
				continue;
			}
			refined = false;
			float y = clamp((p.y - (c.y - half_size.y)) / s.y, 0.0, 1.0);
			// One sample toward the sun shades the far side and the inside; the flat base is the darkest part, lit only
			// by the sky and the ground below.
			float toward_sun = cloud_density(p + light_step, c, s, seed_shift, false);
			float sunlit = exp(-toward_sun * 2.6) * mix(0.35, 1.0, smoothstep(0.0, 0.45, y));
			vec3 color = mix(shade_lin, cloud_lin, clamp(0.18 + 0.82 * sunlit, 0.0, 1.0));
			float alpha = 1.0 - exp(-d * extinction * dt);
			radiance += transmittance * alpha * color;
			weighted_t += transmittance * alpha * t;
			transmittance *= 1.0 - alpha;
			t += dt;
		} else {
			t += coarse ? dt * 2.0 : dt;
			coarse = !refined;
			refined = false;
		}
	}
	float opacity = 1.0 - transmittance;
	if (opacity < 0.004) {
		discard;
	}
	vec3 color = radiance / opacity;
	float distance_m = weighted_t / opacity;
	color = mix(haze_lin, color, exp(-distance_m * haze_density));
	ALBEDO = encode_for_engine(color);
	ALPHA = opacity;
}
