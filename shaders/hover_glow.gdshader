shader_type canvas_item;

// Radiant white glow shader for hover highlighting
// Creates a pulsing, shimmering effect around the element

uniform float intensity : hint_range(0.0, 2.0) = 1.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 3.0;
uniform float glow_size : hint_range(0.0, 20.0) = 4.0;
uniform vec4 glow_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);
uniform bool enabled = true;

void fragment() {
	vec4 tex_color = texture(TEXTURE, UV);

	if (!enabled) {
		COLOR = tex_color;
		return;
	}

	// Pulsing intensity
	float pulse = 0.7 + 0.3 * sin(TIME * pulse_speed);

	// Sample nearby pixels for glow effect
	vec2 pixel_size = TEXTURE_PIXEL_SIZE;
	float glow = 0.0;

	// Sample in a circle around the pixel
	for (float angle = 0.0; angle < 6.28; angle += 0.785) { // 8 samples
		for (float dist = 1.0; dist <= glow_size; dist += 1.0) {
			vec2 offset = vec2(cos(angle), sin(angle)) * dist * pixel_size;
			float sample_alpha = texture(TEXTURE, UV + offset).a;
			glow += sample_alpha * (1.0 - dist / glow_size);
		}
	}
	glow /= 8.0 * glow_size;

	// Apply shimmer effect
	float shimmer = 0.5 + 0.5 * sin(TIME * pulse_speed * 2.0 + UV.x * 10.0 + UV.y * 10.0);

	// Combine glow with original
	vec4 glow_contribution = glow_color * glow * intensity * pulse * shimmer;

	// Add glow around edges
	if (tex_color.a > 0.01) {
		COLOR = tex_color + glow_contribution * 0.5;
		COLOR.rgb = mix(tex_color.rgb, glow_color.rgb, intensity * pulse * 0.3);
	} else {
		COLOR = glow_contribution;
	}

	COLOR.a = max(tex_color.a, glow * intensity * 0.5);
}

