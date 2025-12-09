shader_type canvas_item;

// Hex tile hover shader - radiant white glow for hovered hexagons
// Applied to Polygon2D glow overlays

uniform float intensity : hint_range(0.0, 2.0) = 1.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 2.5;
uniform float edge_glow : hint_range(0.0, 1.0) = 0.6;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 0.4);
uniform bool enabled = true;

void fragment() {
	// Pulsing effect
	float pulse = 0.6 + 0.4 * sin(TIME * pulse_speed);

	// Radial gradient from center
	vec2 center = vec2(0.5, 0.5);
	float dist_from_center = length(UV - center) * 2.0;

	// Edge enhancement
	float edge_factor = smoothstep(0.3, 1.0, dist_from_center);
	float glow = mix(0.3, edge_glow, edge_factor);

	// Shimmer wave effect
	float wave = sin(TIME * pulse_speed * 1.5 + UV.x * 8.0 - UV.y * 8.0) * 0.15 + 0.85;

	// Combine effects
	float final_alpha = base_color.a * intensity * pulse * glow * wave;

	// Apply enabled flag
	if (!enabled) {
		final_alpha = 0.0;
	}

	COLOR = vec4(base_color.rgb, final_alpha);
}

