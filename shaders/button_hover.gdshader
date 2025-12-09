shader_type canvas_item;

// Button hover glow shader - white radiant pulse effect
// Applied to ColorRect overlay on buttons

uniform float intensity : hint_range(0.0, 2.0) = 1.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 4.0;
uniform vec4 glow_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool enabled = false;

void fragment() {
	// Pulsing effect
	float pulse = 0.6 + 0.4 * sin(TIME * pulse_speed);

	// Edge distance for glow (normalized 0-1 from edge)
	float edge_dist = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float edge_factor = smoothstep(0.0, 0.15, edge_dist);
	float edge_glow = (1.0 - edge_factor) * pulse;

	// Inner shimmer
	float shimmer = 0.85 + 0.15 * sin(TIME * pulse_speed * 2.0 + UV.x * 15.0 + UV.y * 15.0);

	// Combine effects
	float alpha = edge_glow * intensity * shimmer;

	// Apply enabled state
	if (!enabled) {
		alpha = 0.0;
	}

	COLOR = vec4(glow_color.rgb, alpha * 0.5);
}

