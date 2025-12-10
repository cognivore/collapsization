## Lightweight debug overlay that can be attached to any CanvasLayer/Control.
extends Control
class_name DebugHUD

var _labels: Dictionary = {}

static func create(title: String, metrics: Array[String]) -> Control:
	var script: GDScript = load("res://scripts/debug/debug_hud.gd")
	var hud: Control = script.new()
	hud.name = title
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.anchors_preset = Control.PRESET_TOP_RIGHT
	hud.anchor_left = 1.0
	hud.anchor_right = 1.0
	hud.offset_left = -320
	hud.offset_top = 12
	hud.offset_right = -12
	hud.offset_bottom = 300
	hud._build_panel(title, metrics)
	return hud


func _build_panel(title: String, metrics: Array[String]) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.75)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vbox)

	var header := Label.new()
	header.text = title
	header.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
	header.add_theme_font_size_override("font_size", 14)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(header)

	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(sep)

	for metric in metrics:
		var lbl := Label.new()
		lbl.name = metric
		lbl.text = "%s: --" % metric
		lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 0.8))
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(lbl)
		_labels[metric] = lbl


func update_metrics(values: Dictionary) -> void:
	for key in values.keys():
		if key in _labels:
			_labels[key].text = "%s: %s" % [key, values[key]]
