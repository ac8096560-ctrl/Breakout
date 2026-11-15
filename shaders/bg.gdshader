shader_type canvas_item;

// Atmospheric background: vertical gradient + soft center glow + vignette.

uniform vec4 top : source_color = vec4(0.055, 0.10, 0.19, 1.0);
uniform vec4 bottom : source_color = vec4(0.012, 0.028, 0.07, 1.0);
uniform vec4 center_glow : source_color = vec4(0.10, 0.22, 0.30, 1.0);
uniform float glow_amount = 0.35;
uniform float vignette = 0.15;

void fragment() {
	vec3 col = mix(top.rgb, bottom.rgb, UV.y);
	vec2 c = UV - vec2(0.5, 0.45);
	float d = length(c * vec2(1.25, 1.0));
	col += center_glow.rgb * (1.0 - smoothstep(0.0, 0.75, d)) * glow_amount;
	col *= 1.0 - vignette * smoothstep(0.5, 1.05, d);
	COLOR = vec4(col, 1.0);
}
