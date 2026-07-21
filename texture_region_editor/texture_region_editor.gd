extends AcceptDialog

## Because Godot doesn't let you instantiate the built-in TextureRegionEditor from a plugin.
## If they make a PR to let you do that, this whole script is unnecessary.
## At least it'll make it easy to add new functionality if I decide to do that...
class_name TextureRegionEditor

var plugin:EditorPlugin

# UI Components
var slice_mode_button:OptionButton
var zoom_in:Button
var zoom_out:Button
var zoom_reset:Button
var hb_grid:HBoxContainer
var smart_style_button:OptionButton
var smart_style_color_button:ColorPickerButton
var cb_pixel_snap:CheckButton
var sb_step_x:SpinBox
var sb_step_y:SpinBox
var sb_off_x:SpinBox
var sb_off_y:SpinBox
var sb_sep_x:SpinBox
var sb_sep_y:SpinBox

var texture_preview:PanelContainer
var texture_overlay:TextureRegionEditorOverlay

var vscroll:VScrollBar
var hscroll:HScrollBar

# State
var draw_ofs:Vector2
var draw_zoom:float = 1.0
var min_draw_zoom:float = 1.0
var max_draw_zoom:float = 1.0
var updating_scroll:bool = false

var slice_mode:SliceMode = SliceMode.SLICE_FREE
var smart_slice_style:SmartSliceStyle = SmartSliceStyle.FIND_SHAPES

## The alpha threshold at which a pixel is considered transparent.
var find_shapes_threshold:float = 0.1
## Lower epsilon means more points in the polygons for the detected shapes.
var find_shapes_epsilon:float = 2.0
## The color which is should be used for checking shapes.
var chroma_key_color:Color = Color.RED

var grid_slice_offset:Vector2
var grid_slice_step:Vector2
var grid_slice_separation:Vector2

var node_sprite_2d:Sprite2D
var node_sprite_3d:Sprite3D
var node_ninepatch:NinePatchRect
var res_stylebox:StyleBoxTexture
var res_atlas_texture:AtlasTexture

var rect:Rect2
var rect_prev:Rect2
var prev_margin:float = 0.0
var edited_margin:int  = -1
var smartslice_cache:Array[Rect2]
var smartslice_is_dirty = true

var drag:bool = false
var creating:bool = false
var moving:bool = false
var drag_from:Vector2
var drag_index:int = -1
var request_center:bool = false

var panner:ViewPanner

static var pan_pos_cache:Dictionary[RID, Vector2] = {}
static var pan_zoom_cache:Dictionary[RID, float] = {}

enum SliceMode {
	SLICE_FREE = 0,
	SLICE_GRID = 1,
	SLICE_SMART = 2
}

enum SmartSliceStyle
{
	## An algorithm which looks for polygons in the image and draws bounds around them.
	FIND_SHAPES = 0,
	## An algorithm that masks for a specific color, and keys based on that.
	CHROMA_KEY = 1
}

func _init() -> void:
	self.title = "Region Editor"
	self.set_flag(FLAG_MAXIMIZE_DISABLED, false)
	self.set_process_shortcut_input(true)
	self.ok_button_text = "Add Frame"
	self.dialog_close_on_escape = false
	
	panner = ViewPanner.new()
	panner.set_callbacks(_pan_callback, _zoom_callback)

	_build_interface()

## https://github.com/godotengine/godot/blob/c12e51972a41665743be79c7d3e3fd5c871d97f3/editor/scene/texture/texture_region_editor_plugin.cpp#L1209
func _build_interface() -> void:
	var editor_settings = EditorInterface.get_editor_settings()
	
	var vb = VBoxContainer.new()
	add_child(vb)
	
	var hb_tools = HBoxContainer.new()
	vb.add_child(hb_tools)
	
	var last_slice_mode = editor_settings.get_project_metadata("spriteframe_buddy_region_editor", "slice_mode", SliceMode.SLICE_FREE)
	slice_mode_button = OptionButton.new()
	hb_tools.add_child(slice_mode_button)
	slice_mode_button.accessibility_name = "Slice Mode:"
	slice_mode_button.add_item("Free Slice", SliceMode.SLICE_FREE)
	slice_mode_button.add_item("Grid Slice", SliceMode.SLICE_GRID)
	slice_mode_button.add_item("Smart Slice", SliceMode.SLICE_SMART)
	slice_mode_button.item_selected.connect(_set_slice_mode)
	slice_mode_button.custom_minimum_size = Vector2i(48, 48)
	
	match last_slice_mode:
		0:
			slice_mode_button.select(SliceMode.SLICE_FREE)
		1:
			slice_mode_button.select(SliceMode.SLICE_FREE)
		2:
			slice_mode_button.select(SliceMode.SLICE_GRID)
		3:
			slice_mode_button.select(SliceMode.SLICE_SMART)
		_:
			slice_mode_button.select(SliceMode.SLICE_FREE)
	
	var last_pixel_snap = editor_settings.get_project_metadata("spriteframe_buddy_region_editor", "pixel_snap", false)
	cb_pixel_snap = CheckButton.new()
	cb_pixel_snap.text = "Pixel Snap"
	hb_tools.add_child(cb_pixel_snap)
	cb_pixel_snap.hide()
	cb_pixel_snap.button_pressed = last_pixel_snap
	
	var last_smart_style = editor_settings.get_project_metadata("spriteframe_buddy_region_editor", "smart_style", SmartSliceStyle.FIND_SHAPES)
	smart_style_button = OptionButton.new()
	smart_style_button.accessibility_name = "Smart Slice Style:"
	smart_style_button.add_item("Find Shapes", SmartSliceStyle.FIND_SHAPES)
	smart_style_button.add_item("Chroma Key", SmartSliceStyle.CHROMA_KEY)
	smart_style_button.selected = last_smart_style
	smart_style_button.item_selected.connect(_set_smart_slice_style)
	hb_tools.add_child(smart_style_button)
	smart_style_button.hide()
	smart_style_button.selected = last_smart_style
	
	var last_smart_style_color = editor_settings.get_project_metadata("spriteframe_buddy_region_editor", "smart_style_color", Color.RED)
	self.chroma_key_color = last_smart_style_color
	smart_style_color_button = ColorPickerButton.new()
	smart_style_color_button.accessibility_name = "Smart Slice Color:"
	smart_style_color_button.color = chroma_key_color
	smart_style_color_button.color_changed.connect(_set_smart_slice_color)
	smart_style_color_button.popup_closed.connect(_close_smart_slice_color)
	smart_style_color_button.custom_minimum_size = Vector2i(48, 48)
	hb_tools.add_child(smart_style_color_button)
	smart_style_color_button.hide()
	
	hb_grid = HBoxContainer.new()
	hb_tools.add_child(hb_grid)
	
	hb_grid.add_child(VSeparator.new())
	hb_grid.add_child(label("Offset:"))

	sb_off_x = SpinBox.new()
	sb_off_x.set_step(1)
	sb_off_x.set_suffix("px")
	sb_off_x.value_changed.connect(_set_snap_off_x)
	sb_off_x.set_accessibility_name("Offset X")
	hb_grid.add_child(sb_off_x)

	sb_off_y = SpinBox.new()
	sb_off_y.set_step(1)
	sb_off_y.set_suffix("px")
	sb_off_y.value_changed.connect(_set_snap_off_y)
	sb_off_y.set_accessibility_name("Offset Y")
	hb_grid.add_child(sb_off_y)

	hb_grid.add_child(VSeparator.new())
	hb_grid.add_child(label("Step:"))

	sb_step_x = SpinBox.new()
	sb_step_x.set_min(0)
	sb_step_x.set_step(1)
	sb_step_x.set_suffix("px")
	sb_step_x.value_changed.connect(_set_snap_step_x)
	sb_step_x.set_accessibility_name("Step X")
	hb_grid.add_child(sb_step_x)

	sb_step_y = SpinBox.new()
	sb_step_y.set_min(0)
	sb_step_y.set_step(1)
	sb_step_y.set_suffix("px")
	sb_step_y.value_changed.connect(_set_snap_step_y)
	sb_step_y.set_accessibility_name("Step Y")
	hb_grid.add_child(sb_step_y)

	hb_grid.add_child(VSeparator.new())
	hb_grid.add_child(label("Separation:"))
	
	sb_sep_x = SpinBox.new()
	sb_sep_x.set_min(0)
	sb_sep_x.set_step(1)
	sb_sep_x.set_suffix("px")
	sb_sep_x.value_changed.connect(_set_snap_sep_x)
	sb_sep_x.accessibility_name = "Separation X"
	hb_grid.add_child(sb_sep_x)

	sb_sep_y = SpinBox.new()
	sb_sep_y.set_min(0)
	sb_sep_y.set_step(1)
	sb_sep_y.set_suffix("px")
	sb_sep_y.value_changed.connect(_set_snap_sep_y)
	sb_sep_y.accessibility_name = "Separation Y"
	hb_grid.add_child(sb_sep_y)

	hb_grid.hide()

	# Restore grid snap parameters.
	_set_grid_parameters_clamping(false)
	grid_slice_offset = editor_settings.get_project_metadata("texture_region_editor", "snap_offset", Vector2())
	grid_slice_step = editor_settings.get_project_metadata("texture_region_editor", "snap_step", Vector2(8, 8))
	grid_slice_separation = editor_settings.get_project_metadata("texture_region_editor", "snap_separation", Vector2())
	sb_off_x.value = grid_slice_offset.x
	sb_off_y.value = grid_slice_offset.y
	sb_step_x.value = grid_slice_step.x
	sb_step_y.value = grid_slice_step.y
	sb_sep_x.value = grid_slice_separation.x
	sb_sep_y.value = grid_slice_separation.y
	
	# Default the zoom to match the editor scale, but don't dezoom on editor scales below 100% to prevent pixel art from looking bad.
	var EDSCALE = EditorInterface.get_editor_scale()
	draw_zoom = max(1.0, EDSCALE)
	max_draw_zoom = 128.0 * max(1.0, EDSCALE)
	min_draw_zoom = 0.01 * max(1.0, EDSCALE)

	texture_preview = PanelContainer.new()
	vb.add_child(texture_preview)
	texture_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	texture_preview.set_clip_contents(true)
	texture_preview.draw.connect(_texture_preview_draw)

	texture_overlay = TextureRegionEditorOverlay.new()
	texture_overlay.editor = self
	texture_preview.add_child(texture_overlay)
	texture_overlay.set_focus_mode(Control.FOCUS_CLICK)
	texture_overlay.draw.connect(_texture_overlay_draw)
	texture_overlay.gui_input.connect(_texture_overlay_input)
	texture_overlay.focus_exited.connect(panner.release_pan_key)

	var zoom_hb = HBoxContainer.new()
	texture_overlay.add_child(zoom_hb)
	zoom_hb.set_begin(Vector2(5, 5))

	zoom_out = Button.new()
	zoom_out.set_flat(true)
	zoom_out.set_tooltip_text("Zoom Out")
	zoom_out.pressed.connect(_zoom_out)
	zoom_hb.add_child(zoom_out)

	zoom_reset = Button.new()
	zoom_reset.set_flat(true)
	zoom_reset.set_tooltip_text("Zoom Reset")
	zoom_reset.pressed.connect(_zoom_reset)
	zoom_hb.add_child(zoom_reset)

	zoom_in = Button.new()
	zoom_in.set_flat(true)
	zoom_in.set_tooltip_text("Zoom In")
	zoom_in.pressed.connect(_zoom_in)
	zoom_hb.add_child(zoom_in)

	vscroll = VScrollBar.new()
	vscroll.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	vscroll.set_step(0.001)
	vscroll.value_changed.connect(_scroll_changed)
	texture_overlay.add_child(vscroll)

	hscroll = HScrollBar.new()
	hscroll.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hscroll.set_step(0.001)
	hscroll.value_changed.connect(_scroll_changed)
	texture_overlay.add_child(hscroll)
	
	_set_slice_mode(last_slice_mode)
	_set_smart_slice_style(last_smart_style)
	_set_smart_slice_color(last_smart_style_color)
	
	# Remember last position and zoom
	get_ok_button().pressed.connect(_on_ok_button)

func _on_ok_button() -> void:
	print("Remember: %.2f:%.2f" % [hscroll.value, vscroll.value])
	pan_pos_cache.set(_get_edited_object_texture().get_rid(), Vector2(hscroll.value, vscroll.value))
	pan_zoom_cache.set(_get_edited_object_texture().get_rid(), draw_zoom)

static func label(text:String) -> Label:
	var result = Label.new()
	result.text = text
	return result

##
## PORTED FUNCTIONS
##

func _get_offset_transform() -> Transform2D:
	var mtx = Transform2D()
	
	mtx.x *= draw_zoom
	mtx.y *= draw_zoom
	mtx.origin = -draw_ofs * draw_zoom
	
	return mtx

func _texture_preview_draw() -> void:
	var object_texture:Texture2D = _get_edited_object_texture()
	if object_texture == null:
		return

	var mtx:Transform2D = _get_offset_transform()

	RenderingServer.canvas_item_add_set_transform(texture_preview.get_canvas_item(), mtx)
	texture_preview.draw_rect(Rect2(Vector2(), object_texture.get_size()), Color(0.5, 0.5, 0.5, 0.5), false)
	texture_preview.draw_texture(object_texture, Vector2())
	RenderingServer.canvas_item_add_set_transform(texture_preview.get_canvas_item(), Transform2D())


func _texture_overlay_draw() -> void:
	var object_texture:Texture2D = _get_edited_object_texture()
	if object_texture == null:
		return
	
	var mtx:Transform2D = _get_offset_transform()
	var color:Color = get_theme_color("mono_color", "Editor")

	if should_grid_snap():
		var grid_color:Color = Color(color.r, color.g, color.b, color.a * 0.15)
		var s:Vector2 = texture_overlay.get_size()
		var last_cell:int = 0

		if grid_slice_step.x != 0:
			if grid_slice_separation.x == 0:
				for i in range(0, s.x):
					var a = (mtx.affine_inverse() * Vector2(i, 0)).x
					var cell:int = floori((a - grid_slice_offset.x) / grid_slice_step.x)
					
					if (i == 0):
						last_cell = cell
					if (last_cell != cell):
						texture_overlay.draw_line(Vector2(i, 0), Vector2(i, s.y), grid_color)
					last_cell = cell
			else:
				for i in range(0, s.x + grid_slice_separation.x):
					var a = (mtx.affine_inverse() * Vector2(i, 0)).x
					var cell:int = floori((a - grid_slice_offset.x) / (grid_slice_step.x + grid_slice_separation.x))
					if (i == 0):
						last_cell = cell
					if (last_cell != cell):
						texture_overlay.draw_rect(Rect2(i - grid_slice_separation.x * draw_zoom, 0, grid_slice_separation.x * draw_zoom, s.y), grid_color)
					last_cell = cell
		
		if (grid_slice_step.y != 0):
			if (grid_slice_separation.y == 0):
				for i in range(0, s.y):
					var a = (mtx.affine_inverse() * Vector2(0, i)).y
					var cell:int = floori((a - grid_slice_offset.y) / grid_slice_step.y)
					if (i == 0):
						last_cell = cell
					if (last_cell != cell):
						texture_overlay.draw_line(Vector2(0, i), Vector2(s.x, i), grid_color)
					last_cell = cell
			else:
				for i in range(0, s.y + grid_slice_separation.y):
					var a = (mtx.affine_inverse() * Vector2(0, i)).y
					var cell:int = floori((a - grid_slice_offset.y) / (grid_slice_step.y + grid_slice_separation.y))
					if (i == 0):
						last_cell = cell
					if (last_cell != cell):
						texture_overlay.draw_rect(Rect2(0, i - grid_slice_separation.y * draw_zoom, s.x, grid_slice_separation.y * draw_zoom), grid_color)
					last_cell = cell
	elif slice_mode == SliceMode.SLICE_SMART:
		for r in smartslice_cache:
			var endpoints:Array[Vector2] = [
				mtx.basis_xform(r.position),
				mtx.basis_xform(r.position + Vector2(r.size.x, 0)),
				mtx.basis_xform(r.position + r.size),
				mtx.basis_xform(r.position + Vector2(0, r.size.y))
			]
			for i in range(0, 4):
				var next = (i + 1) % 4
				texture_overlay.draw_line(endpoints[i] - draw_ofs * draw_zoom, endpoints[next] - draw_ofs * draw_zoom, Color(0.3, 0.7, 1, 1), 2)

	var select_handle:Texture2D = get_theme_icon("EditorHandle", "EditorIcons")

	var scroll_rect = Rect2(Vector2(), object_texture.get_size())

	var raw_endpoints:Array[Vector2] = [
		rect.position,
		rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size,
		rect.position + Vector2(0, rect.size.y)
	]
	var endpoints:Array[Vector2] = [
		mtx.basis_xform(raw_endpoints[0]),
		mtx.basis_xform(raw_endpoints[1]),
		mtx.basis_xform(raw_endpoints[2]),
		mtx.basis_xform(raw_endpoints[3])
	]
	
	for i in range(0, 4):
		var prev = (i + 3) % 4
		var next = (i + 1) % 4

		var ofs:Vector2 = ((endpoints[i] - endpoints[prev]).normalized() + ((endpoints[i] - endpoints[next]).normalized())).normalized()
		ofs *= sqrt(2) * (select_handle.get_size().x / 2)

		texture_overlay.draw_line(endpoints[i] - draw_ofs * draw_zoom, endpoints[next] - draw_ofs * draw_zoom, color, 2)

		# Corner handle
		texture_overlay.draw_texture(select_handle, (endpoints[i] + ofs - (select_handle.get_size() / 2)).floor() - draw_ofs * draw_zoom)

		ofs = (endpoints[next] - endpoints[i]) / 2
		ofs += (endpoints[next] - endpoints[i]).orthogonal().normalized() * (select_handle.get_size().x / 2)

		# Middle handle
		texture_overlay.draw_texture(select_handle, (endpoints[i] + ofs - (select_handle.get_size() / 2)).floor() - draw_ofs * draw_zoom)

		var temp = scroll_rect.expand(raw_endpoints[i])
		scroll_rect.position = temp.position
		scroll_rect.size = temp.size

	var scroll_margin = texture_overlay.get_size() / draw_zoom
	scroll_rect.position -= scroll_margin
	scroll_rect.size += scroll_margin * 2

	updating_scroll = true

	hscroll.set_min(scroll_rect.position.x)
	hscroll.set_max(scroll_rect.position.x + scroll_rect.size.x)
	if (abs(scroll_rect.position.x - (scroll_rect.position.x + scroll_rect.size.x)) <= scroll_margin.x):
		hscroll.hide()
	else:
		hscroll.show()
		hscroll.set_page(scroll_margin.x)
		hscroll.set_value(draw_ofs.x)

	vscroll.set_min(scroll_rect.position.y)
	vscroll.set_max(scroll_rect.position.y + scroll_rect.size.y)
	if (abs(scroll_rect.position.y - (scroll_rect.position.y + scroll_rect.size.y)) <= scroll_margin.y):
		vscroll.hide()
		draw_ofs.y = scroll_rect.position.y
	else:
		vscroll.show()
		vscroll.set_page(scroll_margin.y)
		vscroll.set_value(draw_ofs.y)

	var hmin:Vector2 = hscroll.get_combined_minimum_size()
	var vmin:Vector2 = vscroll.get_combined_minimum_size()

	hscroll.set_anchor_and_offset(SIDE_RIGHT, Control.ANCHOR_END, -vmin.x if vscroll.is_visible() else 0)
	vscroll.set_anchor_and_offset(SIDE_BOTTOM, Control.ANCHOR_END, -hmin.y if hscroll.is_visible() else 0)

	updating_scroll = false

	if request_center and hscroll.get_min() < 0:
		if pan_pos_cache.has(_get_edited_object_texture().get_rid()):
			print("Move to target point!")
			draw_zoom = pan_zoom_cache.get(_get_edited_object_texture().get_rid())
			var pos = pan_pos_cache.get(_get_edited_object_texture().get_rid())
			hscroll.value = pos.x
			vscroll.value = pos.y
			
			request_center = false
		else:
			# Center on the whole image.
			var center_x = (hscroll.get_min() + hscroll.get_max() - hscroll.get_page()) / 2
			var center_y = (vscroll.get_min() + vscroll.get_max() - vscroll.get_page()) / 2
			print("Centering view on (%.2f, %.2f)" % [center_x, center_y])
		
			# I wanted to add a thing to center on the current rect,
			# but the math is SO FUCKED and I gave up and made it just remember your last position.
		
			hscroll.set_value(center_x)
			vscroll.set_value(center_y)
			# This ensures that the view is updated correctly.
			_pan_callback.call_deferred(Vector2(1, 0), null)
			_scroll_changed.call_deferred(0.0)
			request_center = false

	if (node_ninepatch or res_stylebox):
		var margins:Array[int] = [0]
		if (node_ninepatch):
			margins[0] = node_ninepatch.get_patch_margin(SIDE_TOP)
			margins[1] = node_ninepatch.get_patch_margin(SIDE_BOTTOM)
			margins[2] = node_ninepatch.get_patch_margin(SIDE_LEFT)
			margins[3] = node_ninepatch.get_patch_margin(SIDE_RIGHT)
		elif (res_stylebox):
			margins[0] = res_stylebox.get_texture_margin(SIDE_TOP)
			margins[1] = res_stylebox.get_texture_margin(SIDE_BOTTOM)
			margins[2] = res_stylebox.get_texture_margin(SIDE_LEFT)
			margins[3] = res_stylebox.get_texture_margin(SIDE_RIGHT)

		var pos:Array[Vector2] = [
			mtx.basis_xform(Vector2(0, margins[0])) + Vector2(0, endpoints[0].y - draw_ofs.y * draw_zoom),
			-mtx.basis_xform(Vector2(0, margins[1])) + Vector2(0, endpoints[2].y - draw_ofs.y * draw_zoom),
			mtx.basis_xform(Vector2(margins[2], 0)) + Vector2(endpoints[0].x - draw_ofs.x * draw_zoom, 0),
			-mtx.basis_xform(Vector2(margins[3], 0)) + Vector2(endpoints[2].x - draw_ofs.x * draw_zoom, 0)
		]

		_draw_margin_line(pos[0], pos[0] + Vector2(texture_overlay.get_size().x, 0))
		_draw_margin_line(pos[1], pos[1] + Vector2(texture_overlay.get_size().x, 0))
		_draw_margin_line(pos[2], pos[2] + Vector2(0, texture_overlay.get_size().y))
		_draw_margin_line(pos[3], pos[3] + Vector2(0, texture_overlay.get_size().y))

func _draw_margin_line(p_from:Vector2, p_to:Vector2) -> void:
	# Margin line is a dashed line with a normalized dash length. This method works
	# for both vertical and horizontal lines.

	var EDSCALE = EditorInterface.get_editor_scale()
	var dash_size:Vector2 = (p_to - p_from).normalized() * 10
	var dash_thickness:int = round(2 * EDSCALE)
	var dash_color:Color = get_theme_color("mono_color", "Editor")
	var dash_bg_color:Color = dash_color.inverted() * Color(1, 1, 1, 0.5)
	var line_threshold:int = 200

	# Draw a translucent background line to make the foreground line visible on any background.
	texture_overlay.draw_line(p_from, p_to, dash_bg_color, dash_thickness)

	var dash_start:Vector2 = p_from
	while (dash_start.distance_squared_to(p_to) > line_threshold):
		texture_overlay.draw_line(dash_start, dash_start + dash_size, dash_color, dash_thickness)

		# Skip two size lengths, one for the drawn dash and one for the gap.
		dash_start += dash_size * 2

func _set_grid_parameters_clamping(p_enabled:bool) -> void:
	sb_off_x.allow_lesser = !p_enabled
	sb_off_x.allow_greater = !p_enabled
	sb_off_y.allow_lesser = !p_enabled
	sb_off_y.allow_greater = !p_enabled
	sb_step_x.allow_greater = !p_enabled
	sb_step_y.allow_greater = !p_enabled
	sb_sep_x.allow_greater = !p_enabled
	sb_sep_y.allow_greater = !p_enabled

func _get_overlapping_selection_handle(p_mouse_pos:Vector2) -> Control.CursorShape:
	var EDSCALE = EditorInterface.get_editor_scale()
	var handle_radius = (16 * EDSCALE) / draw_zoom
	var handle_offset = (8 * EDSCALE) / draw_zoom

	# Position of selection handles.
	# endpoint 0 is top-left, the others are defined clockwise
	var endpoints:Array[Vector2] = [
		rect.position + Vector2(-handle_offset, -handle_offset), # 
		rect.position + Vector2(rect.size.x / 2, 0) + Vector2(0, -handle_offset),
		rect.position + Vector2(rect.size.x, 0) + Vector2(handle_offset, -handle_offset),
		rect.position + Vector2(rect.size.x, rect.size.y / 2) + Vector2(handle_offset, 0),
		rect.position + rect.size + Vector2(handle_offset, handle_offset),
		rect.position + Vector2(rect.size.x / 2, rect.size.y) + Vector2(0, handle_offset),
		rect.position + Vector2(0, rect.size.y) + Vector2(-handle_offset, handle_offset),
		rect.position + Vector2(0, rect.size.y / 2) + Vector2(-handle_offset, 0)
	]

	var mouse_pos:Vector2 = _get_offset_transform().affine_inverse() * (p_mouse_pos)
	for i in range(8):
		if (mouse_pos.distance_to(endpoints[i]) <= handle_radius):
			return i
	return -1

func _get_overlapping_margin_line(p_mouse_pos:Vector2) -> Dictionary:
	var margins:Array[float] = [0,0,0,0]
	if (node_ninepatch):
		margins[0] = node_ninepatch.get_patch_margin(SIDE_TOP)
		margins[1] = node_ninepatch.get_patch_margin(SIDE_BOTTOM)
		margins[2] = node_ninepatch.get_patch_margin(SIDE_LEFT)
		margins[3] = node_ninepatch.get_patch_margin(SIDE_RIGHT)
	elif (res_stylebox):
		margins[0] = res_stylebox.get_texture_margin(SIDE_TOP)
		margins[1] = res_stylebox.get_texture_margin(SIDE_BOTTOM)
		margins[2] = res_stylebox.get_texture_margin(SIDE_LEFT)
		margins[3] = res_stylebox.get_texture_margin(SIDE_RIGHT)

	var pos = [
		rect.position + Vector2(0, margins[0]),
		rect.position + rect.size - Vector2(0, margins[1]),
		rect.position + Vector2(margins[2], 0),
		rect.position + rect.size - Vector2(margins[3], 0)
	]

	var mouse_pos:Vector2 = _get_offset_transform().affine_inverse() * (p_mouse_pos)
	var EDSCALE = EditorInterface.get_editor_scale()
	var line_thickness = (8 * EDSCALE) / draw_zoom

	var margin_index:int = -1
	if (abs(mouse_pos.y - pos[0].y) <= line_thickness):
		margin_index = 0
	elif (abs(mouse_pos.y - pos[1].y) <= line_thickness):
		margin_index = 1
	elif (abs(mouse_pos.x - pos[2].x) <= line_thickness):
		margin_index = 2
	elif (abs(mouse_pos.x - pos[3].x) <= line_thickness):
		margin_index = 3
	return {
		"index": margin_index,
		"margin": margins[margin_index]
	}

func _commit_drag():
	var undo_redo = plugin.get_undo_redo()
	
	if (edited_margin >= 0):
		undo_redo.create_action("Set Margin")
		var side = [ SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT ]
		if (node_ninepatch):
			undo_redo.add_do_method(node_ninepatch, "set_patch_margin", side[edited_margin], node_ninepatch.get_patch_margin(side[edited_margin]))
			undo_redo.add_undo_method(node_ninepatch, "set_patch_margin", side[edited_margin], prev_margin)
		elif (res_stylebox):
			undo_redo.add_do_method(res_stylebox, "set_texture_margin", side[edited_margin], res_stylebox.get_texture_margin(side[edited_margin]))
			undo_redo.add_undo_method(res_stylebox, "set_texture_margin", side[edited_margin], prev_margin)
			res_stylebox.emit_changed()
		edited_margin = -1
	else:
		undo_redo.create_action("Set Region Rect")
		if (node_ninepatch):
			undo_redo.add_do_method(node_ninepatch, "set_region_rect", node_ninepatch.get_region_rect())
			undo_redo.add_undo_method(node_ninepatch, "set_region_rect", rect_prev)
		elif (res_stylebox):
			undo_redo.add_do_method(res_stylebox, "set_region_rect", res_stylebox.get_region_rect())
			undo_redo.add_undo_method(res_stylebox, "set_region_rect", rect_prev)
		elif (res_atlas_texture):
			undo_redo.add_do_method(res_atlas_texture, "set_region", res_atlas_texture.get_region())
			undo_redo.add_undo_method(res_atlas_texture, "set_region", rect_prev)
		elif (node_sprite_2d):
			undo_redo.add_do_method(node_sprite_2d, "set_region_rect", node_sprite_2d.get_region_rect())
			undo_redo.add_undo_method(node_sprite_2d, "set_region_rect", rect_prev)
		elif (node_sprite_3d):
			undo_redo.add_do_method(node_sprite_3d, "set_region_rect", node_sprite_3d.get_region_rect())
			undo_redo.add_undo_method(node_sprite_3d, "set_region_rect", rect_prev)
		drag_index = -1

	undo_redo.add_do_method(self, "_update_rect")
	undo_redo.add_undo_method(self, "_update_rect")
	undo_redo.add_do_method(texture_overlay, "queue_redraw")
	undo_redo.add_undo_method(texture_overlay, "queue_redraw")
	undo_redo.commit_action()
	drag = false
	creating = false
	moving = false

func should_pixel_snap() -> bool:
	return cb_pixel_snap.button_pressed

func should_grid_snap() -> bool:
	return slice_mode == SliceMode.SLICE_GRID

func _texture_overlay_input(p_input:InputEvent) -> void:
	if (panner.gui_input(p_input, texture_overlay.get_global_rect())):
		return

	var mtx:Transform2D = _get_offset_transform()

	var cancel_drag:bool = false

	if is_instance_of(p_input, InputEventMouseButton):
		var mb = p_input as InputEventMouseButton
		if (mb.get_button_index() == MouseButton.MOUSE_BUTTON_LEFT):
			if (mb.is_pressed() and !panner.is_panning()):
				# Check if we click on any handle first.
				drag_from = mtx.affine_inverse() * (mb.get_position())
				if should_pixel_snap():
					drag_from = drag_from.snappedf(1)
				elif should_grid_snap():
					drag_from = snap_point(drag_from)
				
				drag = true
				drag_index = _get_overlapping_selection_handle(mb.get_position())
				rect_prev = _get_edited_object_region()

				if drag_index >= 0:
					pass
				else:
					# We didn't hit any handle, try other options.
					if node_ninepatch or res_stylebox:
						# For ninepatchable objects check if we are clicking on margin bars.
						var r = _get_overlapping_margin_line(mb.get_position())
						edited_margin = r.get("index")
						var margin = r.get("margin")

						if (edited_margin >= 0):
							prev_margin = margin
							drag_from = mb.get_position()
							drag = true

					if edited_margin < 0 and slice_mode == SliceMode.SLICE_SMART:
						# We didn't hit anything, but we're in the smart slice mode.
						# Select the located region.
						var point:Vector2 = mtx.affine_inverse() * (mb.get_position())
						var undo_redo = plugin.get_undo_redo()
						for E in smartslice_cache:
							if (E.has_point(point)):
								rect = E
								if (mb.is_command_or_control_pressed() and !(mb.shift_pressed or mb.alt_pressed)):
									var r := _get_edited_object_region()
									var temp = rect.expand(r.position).expand(r.end)
									rect.position = temp.position
									rect.size = temp.size

								undo_redo.create_action("Set Region Rect")
								if node_ninepatch:
									undo_redo.add_do_method(node_ninepatch, "set_region_rect", rect)
									undo_redo.add_undo_method(node_ninepatch, "set_region_rect", node_ninepatch.get_region_rect())
								elif res_stylebox:
									undo_redo.add_do_method(res_stylebox, "set_region_rect", rect)
									undo_redo.add_undo_method(res_stylebox, "set_region_rect", res_stylebox.get_region_rect())
								elif res_atlas_texture:
									undo_redo.add_do_method(res_atlas_texture, "set_region", rect)
									undo_redo.add_undo_method(res_atlas_texture, "set_region", res_atlas_texture.get_region())
								elif node_sprite_2d:
									undo_redo.add_do_method(node_sprite_2d, "set_region_rect", rect)
									undo_redo.add_undo_method(node_sprite_2d, "set_region_rect", node_sprite_2d.get_region_rect())
								elif node_sprite_3d:
									undo_redo.add_do_method(node_sprite_3d, "set_region_rect", rect)
									undo_redo.add_undo_method(node_sprite_3d, "set_region_rect", node_sprite_3d.get_region_rect())

								undo_redo.add_do_method(self, "_update_rect")
								undo_redo.add_undo_method(self, "_update_rect")
								undo_redo.add_do_method(texture_overlay, "queue_redraw")
								undo_redo.add_undo_method(texture_overlay, "queue_redraw")
								undo_redo.commit_action()
								break
					elif (edited_margin < 0):
						var point:Vector2 = mtx.affine_inverse() * (mb.get_position())
						if (rect.has_point(point)):
							drag_from = point
							drag = true
							moving = true
						else:
							# We didn't hit anything and it's not smart slice, which means we try to create a new region.
							creating = true
							rect = Rect2(drag_from, Vector2())
			elif (!mb.is_pressed() and drag):
				_commit_drag()
		elif (drag and mb.get_button_index() == MouseButton.MOUSE_BUTTON_RIGHT and mb.is_pressed()):
			cancel_drag = true

	if (drag and p_input and p_input.is_action_pressed("ui_cancel", false, true)):
		cancel_drag = true

	if cancel_drag:
		drag = false
		if (edited_margin >= 0):
			var side = [ SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT ]
			if node_ninepatch:
				node_ninepatch.set_patch_margin(side[edited_margin], prev_margin)
			if res_stylebox:
				res_stylebox.set_texture_margin(side[edited_margin], prev_margin)
			edited_margin = -1
		elif moving:
			moving = false
			_apply_rect(rect_prev)
			rect = rect_prev
			texture_preview.queue_redraw()
			texture_overlay.queue_redraw()
		else:
			_apply_rect(rect_prev)
			rect = rect_prev
			texture_preview.queue_redraw()
			texture_overlay.queue_redraw()
			drag_index = -1


	if drag and is_instance_of(p_input, InputEventMouseMotion):
		var mm = p_input as InputEventMouseMotion
		if mm.get_button_mask() == MouseButtonMask.MOUSE_BUTTON_MASK_LEFT:
			if edited_margin >= 0:
				var new_margin:float = 0

				if not should_grid_snap():
					if edited_margin == 0:
						new_margin = prev_margin + (mm.get_position().y - drag_from.y) / draw_zoom
					elif edited_margin == 1:
						new_margin = prev_margin - (mm.get_position().y - drag_from.y) / draw_zoom
					elif edited_margin == 2:
						new_margin = prev_margin + (mm.get_position().x - drag_from.x) / draw_zoom
					elif edited_margin == 3:
						new_margin = prev_margin - (mm.get_position().x - drag_from.x) / draw_zoom
					else:
						push_error("Unexpected edited_margin")
					
					if should_pixel_snap():
						new_margin = round(new_margin)
				else:
					var pos_snapped:Vector2 = snap_point(mtx.affine_inverse() * (mm.get_position()))
					var rect_rounded:Rect2 = Rect2(rect.position.round(), rect.size.round())

					if edited_margin == 0:
						new_margin = pos_snapped.y - rect_rounded.position.y
					elif edited_margin == 1:
						new_margin = rect_rounded.size.y + rect_rounded.position.y - pos_snapped.y
					elif edited_margin == 2:
						new_margin = pos_snapped.x - rect_rounded.position.x
					elif edited_margin == 3:
						new_margin = rect_rounded.size.x + rect_rounded.position.x - pos_snapped.x
					else:
						push_error("Unexpected edited_margin")
				
				if new_margin < 0:
					new_margin = 0
				var side = [ SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT ]
				if node_ninepatch:
					node_ninepatch.set_patch_margin(side[edited_margin], new_margin)
				if res_stylebox:
					res_stylebox.set_texture_margin(side[edited_margin], new_margin)
			elif moving:
				var new_pos:Vector2 = mtx.affine_inverse() * (mm.get_position())
				var delta:Vector2 = new_pos - drag_from
				rect.position = rect_prev.position + delta

				if should_pixel_snap():
					rect.position = rect.position.snappedf(1)
				elif should_grid_snap():
					rect.position = snap_point(rect.position)

				_apply_rect(rect)
				texture_preview.queue_redraw()
				texture_overlay.queue_redraw()
				return
			else:
				var new_pos:Vector2 = mtx.affine_inverse() * (mm.get_position())
				if should_pixel_snap():
					new_pos = new_pos.snappedf(1)
				elif should_grid_snap():
					new_pos = snap_point(new_pos)

				if (creating):
					rect = Rect2(drag_from, Vector2())
					var temp = rect.expand(new_pos)
					rect.position = temp.position
					rect.size = temp.size
					_apply_rect(rect)
					texture_preview.queue_redraw()
					texture_overlay.queue_redraw()
					return

				if (drag_index >= 0):
					var pivot_factors = [
						# These pivots need to match how `CanvasItemEditor` behaves.
						Vector2(1, 1), # drag_index == 0 (top left)
						Vector2(0, 1), # drag_index == 1 (top middle)
						Vector2(0, 1), # drag_index == 2 (top right)
						Vector2(0, 0), # drag_index == 3 (middle right)
						Vector2(0, 0), # drag_index == 4 (bottom right)
						Vector2(0, 0), # drag_index == 5 (bottom middle)
						Vector2(1, 0), # drag_index == 6 (bottom left)
						Vector2(1, 0), # drag_index == 7 (middle left)
					]

					var pivot = rect_prev.position + rect_prev.size * pivot_factors[drag_index]
					rect = Rect2(pivot, Vector2())

					var uniform:bool = Input.is_key_pressed(Key.KEY_SHIFT)
					var symmetric:bool = Input.is_key_pressed(Key.KEY_ALT)
					var lock_x:bool = !uniform and (drag_index == 1 or drag_index == 5)
					var lock_y:bool = !uniform and (drag_index == 3 or drag_index == 7)

					var center_prev:Vector2 = rect_prev.get_center()

					if (uniform):
						var drag_offset:Vector2 = new_pos - pivot
						var scale:Vector2 = drag_offset.abs() / rect_prev.size
						var uniform_scale:float = max(scale.x, scale.y)
						var new_size:Vector2 = rect_prev.size * uniform_scale * drag_offset.sign()

						new_pos = pivot + new_size
						if should_pixel_snap():
							new_pos = new_pos.snappedf(1)
						elif should_grid_snap():
							new_pos = snap_point(new_pos)
					else:
						if (lock_x):
							rect.size.x = rect_prev.size.x
							new_pos.x = center_prev.x
						elif (lock_y):
							rect.size.y = rect_prev.size.y
							new_pos.y = center_prev.y
					
					if (symmetric):
						var new_pos_mirrored:Vector2 = center_prev + (center_prev - new_pos)
						if (!lock_x):
							rect.position.x = new_pos_mirrored.x
						if (!lock_y):
							rect.position.y = new_pos_mirrored.y
					
					var temp = rect.expand(new_pos)
					rect.position = temp.position
					rect.size = temp.size
					_apply_rect(rect)
			texture_preview.queue_redraw()
			texture_overlay.queue_redraw()
		else:
			_commit_drag()

	if is_instance_of(p_input, InputEventMagnifyGesture):
		var magnify_gesture = p_input as InputEventMagnifyGesture
		_zoom_on_position(draw_zoom * magnify_gesture.get_factor(), magnify_gesture.get_position())

	if is_instance_of(p_input, InputEventPanGesture):
		var pan_gesture = p_input as InputEventPanGesture
		hscroll.set_value(hscroll.get_value() + hscroll.get_page() * pan_gesture.get_delta().x / 8)
		vscroll.set_value(vscroll.get_value() + vscroll.get_page() * pan_gesture.get_delta().y / 8)

func _pan_callback(p_scroll_vec:Vector2, p_event:InputEvent) -> void:
	p_scroll_vec /= draw_zoom
	hscroll.set_value(hscroll.get_value() - p_scroll_vec.x)
	vscroll.set_value(vscroll.get_value() - p_scroll_vec.y)

func _zoom_callback(p_zoom_factor:float, p_origin:Vector2, p_event:InputEvent) -> void:
	_zoom_on_position(draw_zoom * p_zoom_factor, p_origin)

func _input_from_window(p_event:InputEvent) -> void:
	if (!drag and p_event and p_event.is_action_pressed("ui_cancel", false, true)):
		hide()

func _scroll_changed(float) -> void:
	if (updating_scroll):
		return

	draw_ofs.x = hscroll.get_value()
	draw_ofs.y = vscroll.get_value()

	texture_preview.queue_redraw()
	texture_overlay.queue_redraw()

func _set_slice_mode(p_mode:SliceMode) -> void:
	print("Set slice mode: %s" % p_mode)
	self.slice_mode = p_mode

	hb_grid.visible = should_grid_snap()
	cb_pixel_snap.visible = not should_grid_snap()
	smart_style_button.visible = slice_mode == SliceMode.SLICE_SMART
	smart_style_color_button.visible = slice_mode == SliceMode.SLICE_SMART and smart_slice_style == SmartSliceStyle.CHROMA_KEY
	if (slice_mode == SliceMode.SLICE_SMART and is_visible() and smartslice_is_dirty):
		_update_smartslice()

	texture_overlay.queue_redraw()

func _set_smart_slice_style(p_style:SmartSliceStyle) -> void:
	print("Set smart slice style: %s" % p_style)
	smart_slice_style = p_style
	smart_style_color_button.visible = slice_mode == SliceMode.SLICE_SMART and smart_slice_style == SmartSliceStyle.CHROMA_KEY
	smartslice_is_dirty = true
	if (slice_mode == SliceMode.SLICE_SMART and is_visible() and smartslice_is_dirty):
		_update_smartslice()
		texture_overlay.queue_redraw()

func _set_smart_slice_color(color:Color) -> void:
	self.chroma_key_color = color
	smartslice_is_dirty = true
	# Don't actually do the redraw until we close the picker.
	# Bonus, we don't redraw if the color never changes!

func _close_smart_slice_color() -> void:
	if (slice_mode == SliceMode.SLICE_SMART and is_visible() and smartslice_is_dirty):
		_update_smartslice()
		texture_overlay.queue_redraw()

func _set_snap_off_x(p_val:float) -> void:
	grid_slice_offset.x = p_val
	texture_overlay.queue_redraw()

func _set_snap_off_y(p_val:float) -> void:
	grid_slice_offset.y = p_val
	texture_overlay.queue_redraw()

func _set_snap_step_x(p_val:float) -> void:
	grid_slice_step.x = p_val
	texture_overlay.queue_redraw()

func _set_snap_step_y(p_val:float) -> void:
	grid_slice_step.y = p_val
	texture_overlay.queue_redraw()

func _set_snap_sep_x(p_val:float) -> void:
	grid_slice_separation.x = p_val
	texture_overlay.queue_redraw()

func _set_snap_sep_y(p_val:float) -> void:
	grid_slice_separation.y = p_val
	texture_overlay.queue_redraw()

func _zoom_on_position(p_zoom:float, p_position:Vector2) -> void:
	if (p_zoom < min_draw_zoom or p_zoom > max_draw_zoom):
		return

	var prev_zoom = draw_zoom
	draw_zoom = p_zoom
	var ofs:Vector2 = p_position
	ofs = (ofs / prev_zoom) - (ofs / draw_zoom)
	draw_ofs = (draw_ofs + ofs).round()

	texture_preview.queue_redraw()
	texture_overlay.queue_redraw()

func _zoom_in() -> void:
	_zoom_on_position(draw_zoom * 1.5, texture_overlay.get_size() / 2.0)

func _zoom_reset() -> void:
	_zoom_on_position(1.0, texture_overlay.get_size() / 2.0)

func _zoom_out() -> void:
	_zoom_on_position(draw_zoom / 1.5, texture_overlay.get_size() / 2.0)

func _apply_rect(p_rect:Rect2) -> void:
	if node_sprite_2d:
		node_sprite_2d.set_region_rect(p_rect)
	elif node_sprite_3d:
		node_sprite_3d.set_region_rect(p_rect)
	elif node_ninepatch:
		node_ninepatch.set_region_rect(p_rect)
	elif res_stylebox:
		res_stylebox.set_region_rect(p_rect)
	elif res_atlas_texture:
		res_atlas_texture.set_region(p_rect)

func _update_rect() -> void:
	rect = _get_edited_object_region()

func _should_update_smartslice() -> bool:
	return slice_mode == SliceMode.SLICE_SMART and is_visible() and smartslice_is_dirty

func _update_smartslice() -> void:
	smartslice_is_dirty = false
	smartslice_cache.clear()

	var object_texture:Texture2D = _get_edited_object_texture()
	if object_texture == null:
		return
	
	# https://github.com/Delsin-Yu/GD-AtlasTexture-Manager/blob/fd805f3a9497c7954ec5a2b5f7087c7c34f25e6b/addons/AtlasTextureManager/atlastexture_manager.gd#L824
	
	match smart_slice_style:
		SmartSliceStyle.FIND_SHAPES:
			_smartslice_find_shapes(object_texture)
		SmartSliceStyle.CHROMA_KEY:
			_smartslice_chroma_key(object_texture)
		_:
			push_error("Unknown SmartSliceStyle: %s" % smart_slice_style)


func _smartslice_find_shapes(object_texture:Texture2D) -> void:
	var mask = BitMap.new()
	mask.create_from_image_alpha(object_texture.get_image(), find_shapes_threshold)
	var polygons:Array[PackedVector2Array] = mask.opaque_to_polygons(Rect2i(Vector2i.ZERO, mask.get_size()), find_shapes_epsilon)
	
	smartslice_cache = enclose_polygons(polygons, mask.get_size().x, mask.get_size().y)
	
	print("Found %d frames in %d polygons" % [smartslice_cache.size(), polygons.size()])

func _smartslice_chroma_key(object_texture:Texture2D) -> void:
	var mask = BitMap.new()
	mask_from_chroma_key(mask, object_texture.get_image(), chroma_key_color)
	var polygons:Array[PackedVector2Array] = mask.opaque_to_polygons(Rect2i(Vector2i.ZERO, mask.get_size()), find_shapes_epsilon)
	
	smartslice_cache = enclose_polygons(polygons, mask.get_size().x, mask.get_size().y)
	
	print("Found %d frames in %d polygons" % [smartslice_cache.size(), polygons.size()])

func _notification(p_what:int) -> void:
	match p_what:
		EditorSettings.NOTIFICATION_EDITOR_SETTINGS_CHANGED:
			if (EditorInterface.get_editor_settings().check_changed_settings_in_group("editors/panning")):
				panner.setup(
					EditorInterface.get_editor_settings().get_setting("editors/panning/sub_editors_panning_scheme"),
					EditorInterface.get_editor_settings().get_shortcut("canvas_item_editor/pan_view"),
					EditorInterface.get_editor_settings().get_setting("editors/panning/simple_panning"))
				panner.setup_warped_panning(self,
					EditorInterface.get_editor_settings().get_setting("editors/panning/warped_mouse_panning"))

		NOTIFICATION_ENTER_TREE:
			get_tree().node_removed.connect(_node_removed)

			hb_grid.set_visible(should_grid_snap())
			if _should_update_smartslice():
				_update_smartslice()

			panner.setup(
				EditorInterface.get_editor_settings().get_setting("editors/panning/sub_editors_panning_scheme"),
				EditorInterface.get_editor_settings().get_shortcut("canvas_item_editor/pan_view"),
				EditorInterface.get_editor_settings().get_setting("editors/panning/simple_panning"))
			panner.setup_warped_panning(self,
				EditorInterface.get_editor_settings().get_setting("editors/panning/warped_mouse_panning"))

		NOTIFICATION_EXIT_TREE:
			get_tree().node_removed.disconnect(_node_removed)
		
		NOTIFICATION_THEME_CHANGED:
			texture_preview.add_theme_stylebox_override("panel", get_theme_stylebox("TextureRegionPreviewBG", "EditorStyles"))
			texture_overlay.add_theme_stylebox_override("panel", get_theme_stylebox("TextureRegionPreviewFG", "EditorStyles"))

			zoom_out.set_button_icon(get_theme_icon("ZoomLess", "EditorIcons"))
			zoom_reset.set_button_icon(get_theme_icon("ZoomReset", "EditorIcons"))
			zoom_in.set_button_icon(get_theme_icon("ZoomMore", "EditorIcons"))

		NOTIFICATION_VISIBILITY_CHANGED:
			if _should_update_smartslice():
				_update_smartslice()

			if (!is_visible()):
				EditorInterface.get_editor_settings().set_project_metadata("texture_region_editor", "snap_offset", grid_slice_offset)
				EditorInterface.get_editor_settings().set_project_metadata("texture_region_editor", "snap_step", grid_slice_step)
				EditorInterface.get_editor_settings().set_project_metadata("texture_region_editor", "snap_separation", grid_slice_separation)
				EditorInterface.get_editor_settings().get_project_metadata("spriteframe_buddy_region_editor", "pixel_snap", )
				EditorInterface.get_editor_settings().get_project_metadata("spriteframe_buddy_region_editor", "slice_mode", slice_mode)
				EditorInterface.get_editor_settings().get_project_metadata("spriteframe_buddy_region_editor", "smart_style", smart_slice_style)

				EditorInterface.get_editor_settings().set_project_metadata("spriteframe_buddy_region_editor", "slice_mode", slice_mode)
				EditorInterface.get_editor_settings().set_project_metadata("spriteframe_buddy_region_editor", "pixel_snap", cb_pixel_snap.button_pressed)
				EditorInterface.get_editor_settings().set_project_metadata("spriteframe_buddy_region_editor", "smart_style", smart_slice_style)
				EditorInterface.get_editor_settings().set_project_metadata("spriteframe_buddy_region_editor", "smart_style_color", chroma_key_color)

		NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			if (drag):
				_commit_drag()

		NOTIFICATION_WM_WINDOW_FOCUS_IN:
			# This happens when the user leaves the Editor and returns,
			# they could have changed the textures, so the cache is cleared.
			_edit_region()

func _node_removed(p_node:Node) -> void:
	if (p_node == node_sprite_2d or p_node == node_sprite_3d or p_node == node_ninepatch):
		_clear_edited_object()
		hide()

func _clear_edited_object() -> void:
	if (node_sprite_2d):
		node_sprite_2d.texture_changed.disconnect(_texture_changed)
		node_sprite_2d.item_rect_changed.disconnect(_edit_region)
	if (node_sprite_3d):
		node_sprite_3d.texture_changed.disconnect(_texture_changed)
		node_sprite_3d.item_rect_changed.disconnect(_edit_region)
	if (node_ninepatch):
		node_ninepatch.texture_changed.disconnect(_texture_changed)
		node_ninepatch.item_rect_changed.disconnect(_edit_region)
	if (res_stylebox):
		res_stylebox.changed.disconnect(_texture_changed)
		res_stylebox.changed.disconnect(_edit_region)
	if (res_atlas_texture):
		res_atlas_texture.changed.disconnect(_texture_changed)
		res_atlas_texture.changed.disconnect(_edit_region)

	node_sprite_2d = null
	node_sprite_3d = null
	node_ninepatch = null
	res_stylebox = null
	res_atlas_texture = null

func edit(p_obj:Object) -> void:
	_clear_edited_object()

	if p_obj:
		var is_resource:bool = false
		if (is_instance_of(p_obj, Sprite2D)):
			node_sprite_2d = p_obj as Sprite2D
		elif (is_instance_of(p_obj, Sprite3D)):
			node_sprite_3d = p_obj as Sprite3D
		elif (is_instance_of(p_obj, NinePatchRect)):
			node_ninepatch = p_obj as NinePatchRect
		elif (is_instance_of(p_obj, StyleBoxTexture)):
			res_stylebox = p_obj as StyleBoxTexture
			is_resource = true
		elif (is_instance_of(p_obj, AtlasTexture)):
			res_atlas_texture = p_obj as AtlasTexture
			is_resource = true

		if (is_resource):
			p_obj.changed.connect(_texture_changed)
			p_obj.changed.connect(_edit_region)
		else:
			p_obj.texture_changed.connect(_texture_changed)
			p_obj.item_rect_changed.connect(_edit_region)
		_edit_region()

	texture_preview.queue_redraw()
	texture_overlay.queue_redraw()
	popup_centered_ratio(0.5)
	request_center = true

func _get_edited_object_texture() -> Texture2D:
	if node_sprite_2d != null:
		return node_sprite_2d.texture
	elif node_sprite_3d != null:
		return node_sprite_3d.texture
	elif node_ninepatch != null:
		return node_ninepatch.texture
	elif res_stylebox != null:
		return res_stylebox.texture
	elif res_atlas_texture != null:
		var atlas = res_atlas_texture.atlas
		return atlas
	else:
		return Texture2D.new()

func _get_edited_object_region() -> Rect2:
	var region:Rect2

	if node_ninepatch:
		region = node_ninepatch.get_region_rect()
	elif res_stylebox:
		region = res_stylebox.get_region_rect()
	elif res_atlas_texture:
		region = res_atlas_texture.get_region()
	elif node_sprite_2d:
		region = node_sprite_2d.get_region_rect()
	elif node_sprite_3d:
		region = node_sprite_3d.get_region_rect()

	var object_texture:Texture2D = _get_edited_object_texture()
	if region == Rect2() and object_texture:
		region = Rect2(Vector2(), object_texture.get_size())
	
	return region

func _texture_changed() -> void:
	if (!is_visible()):
		return
	_edit_region()

func _edit_region() -> void:
	var object_texture:Texture2D = _get_edited_object_texture()
	if object_texture == null:
		_set_grid_parameters_clamping(false)
		_zoom_reset()
		hscroll.hide()
		vscroll.hide()
		texture_preview.queue_redraw()
		texture_overlay.queue_redraw()
		return
	
	var filter:CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	if (node_ninepatch):
		filter = node_ninepatch.get_texture_filter_in_tree()
	elif (node_sprite_2d):
		filter = node_sprite_2d.get_texture_filter_in_tree()
	elif (node_sprite_3d):
		var filter_3d:StandardMaterial3D.TextureFilter = node_sprite_3d.get_texture_filter()
	
		match (filter_3d):
			StandardMaterial3D.TEXTURE_FILTER_NEAREST:
				filter = CanvasItem.TEXTURE_FILTER_NEAREST
			StandardMaterial3D.TEXTURE_FILTER_LINEAR:
				filter = CanvasItem.TEXTURE_FILTER_LINEAR
			StandardMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
				filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
			StandardMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
				filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			StandardMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC:
				filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC
			StandardMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC:
				filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
			_:
				# fallback to project default
				filter = CanvasItem.TEXTURE_FILTER_PARENT_NODE
	
	# occurs when get_texture_filter_in_tree reaches the scene root
	if (filter == CanvasItem.TEXTURE_FILTER_PARENT_NODE):
		var root:SubViewport = EditorInterface.get_editor_viewport_2d()
	
		if (root != null):
			var filter_default:Viewport.DefaultCanvasItemTextureFilter = root.get_default_canvas_item_texture_filter()
	
			# depending on default filter, set filter to match, otherwise fall back on nearest w/ mipmaps
			match filter_default:
				DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST:
					filter = CanvasItem.TEXTURE_FILTER_NEAREST
				DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR:
					filter = CanvasItem.TEXTURE_FILTER_LINEAR
				DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
					filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
					filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
				_:
					filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
		else:
			filter = CanvasItem.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	
	texture_preview.set_texture_filter(filter)
	texture_preview.set_texture_repeat(CanvasItem.TEXTURE_REPEAT_DISABLED)
	
	if slice_mode == SliceMode.SLICE_SMART and is_visible():
		smartslice_is_dirty = true
	
	# Avoiding clamping with mismatched min/max.
	_set_grid_parameters_clamping(false)
	var tex_size:Vector2 = object_texture.get_size()
	sb_off_x.min_value = -tex_size.x
	sb_off_x.max_value = tex_size.x
	sb_off_y.min_value = -tex_size.y
	sb_off_y.max_value = tex_size.y
	sb_step_x.max_value = tex_size.x
	sb_step_y.max_value = tex_size.y
	sb_sep_x.max_value = tex_size.x
	sb_sep_y.max_value = tex_size.y
	
	_set_grid_parameters_clamping(true)
	sb_off_x.value = grid_slice_offset.x
	sb_off_y.value = grid_slice_offset.y
	sb_step_x.value = grid_slice_step.x
	sb_step_y.value = grid_slice_step.y
	sb_sep_x.value = grid_slice_separation.x
	sb_sep_y.value = grid_slice_separation.y
	
	_update_rect()
	texture_preview.queue_redraw()
	texture_overlay.queue_redraw()

func snap_point(p_target:Vector2) -> Vector2:
	if should_grid_snap():
		p_target.x = snap_scalar_separation(grid_slice_offset.x, grid_slice_step.x, p_target.x, grid_slice_separation.x)
		p_target.y = snap_scalar_separation(grid_slice_offset.y, grid_slice_step.y, p_target.y, grid_slice_separation.y)

	return p_target

func shortcut_input(p_event:InputEvent) -> void:
	var k = p_event as InputEventKey
	if (k != null and k.is_pressed()):
		var handled = false

		# if (EditorInterface.get_editor_settings().is_shortcut("ui_undo", p_event)):
		# 	EditorNode::get_singleton()->undo()
		# 	handled = true

		# if (EditorInterface.get_editor_settings().is_shortcut("ui_redo", p_event)):
		# 	EditorNode::get_singleton()->redo()
		# 	handled = true

		if (handled):
			set_input_as_handled()

static func snap_scalar_separation(p_offset: float, p_step: float, p_target: float, p_separation: float) -> float:
	if (p_step != 0):
		var a:float = snapped(p_target - p_offset, p_step + p_separation) + p_offset
		var b:float = a
		if (p_target >= 0):
			b -= p_separation
		else:
			b += p_step
		return a if (abs(p_target - a) < abs(p_target - b)) else b
	return p_target

static func mask_from_chroma_key(target:BitMap, source:Image, key:Color) -> void:
	var _start = Time.get_ticks_usec()
	var width = source.get_width()
	var height = source.get_height()
	target.create(Vector2i(width, height))
	
	for x in range(0, width):
		for y in range(0, height):
			var pos = Vector2i(x, y)
			target.set_bitv(pos, not key.is_equal_approx(source.get_pixelv(pos)))
	var _dur = Time.get_ticks_usec() - _start
	print("Scanned %d pixels in %.2f us." % [width*height, _dur])

static func enclose_polygons(polygons:Array[PackedVector2Array], width:int, height:int) -> Array[Rect2]:
	var polygon_rects : Array[Rect2] = [];
	
	for polygon in polygons:
		var rect := Rect2(polygon[0], Vector2.ZERO);
		for index in range(1, polygon.size()):
			rect = rect.expand(polygon[index]);
		polygon_rects.append(rect);
	
	var polygon_count = polygon_rects.size()
	
	var index = 0
	while index < polygon_rects.size():
		var slice = polygon_rects[index]
		# Exclude wide slices
		if slice.size.x > width / 2:
			polygon_rects.erase(slice)
			continue
		# Exclude tall slices
		if slice.size.y > height / 2:
			polygon_rects.erase(slice)
			continue
			
		var is_enclosed := false;
		# Determine if the rect is fully inside another.
		for match_rect in polygon_rects:
			if match_rect == slice: continue;
			if !match_rect.encloses(slice): continue;
			is_enclosed = true;
			break;

		# Exclude enclosed rects.
		if is_enclosed:
			polygon_rects.erase(slice)
			continue
			
		# Else, keep the slice.
		#smartslice_cache.append(slice)
		index += 1
	return polygon_rects
