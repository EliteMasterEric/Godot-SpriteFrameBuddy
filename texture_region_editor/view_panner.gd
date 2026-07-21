extends RefCounted

## https://github.com/godotengine/godot/blob/c12e51972a41665743be79c7d3e3fd5c871d97f3/scene/gui/view_panner.cpp
class_name ViewPanner

enum ControlScheme {
	SCROLL_ZOOMS,
	SCROLL_PANS,
}

enum PanAxis {
	PAN_AXIS_BOTH,
	PAN_AXIS_HORIZONTAL,
	PAN_AXIS_VERTICAL,
}

enum DragType {
	DRAG_TYPE_NONE,
	DRAG_TYPE_PAN,
	DRAG_TYPE_ZOOM,
}

enum ZoomStyle {
	ZOOM_VERTICAL,
	ZOOM_HORIZONTAL,
}

var scroll_speed:int = 32
var scroll_zoom_factor:float = 1.1
var pan_axis:PanAxis = PanAxis.PAN_AXIS_BOTH

var pan_key_pressed:bool = false
var force_drag:bool = false

var drag_type:DragType = DragType.DRAG_TYPE_NONE

var zoom_style:ZoomStyle = ZoomStyle.ZOOM_VERTICAL

var drag_zoom_position:Vector2
var drag_zoom_sensitivity_factor:float = -0.01

var enable_rmb:bool = false
var simple_panning_enabled:bool = false

var pan_view_shortcut:Shortcut

var pan_callback:Callable
var zoom_callback:Callable

var control_scheme:ControlScheme = ControlScheme.SCROLL_ZOOMS
var warped_panning_owner:Node = null

func gui_input(p_event:InputEvent, p_canvas_rect:Rect2) -> bool:
	if is_instance_of(p_event, InputEventMouseButton):
		var mb = p_event as InputEventMouseButton
		var right = 1 if mb.get_button_index() == MouseButton.MOUSE_BUTTON_WHEEL_RIGHT else 0
		var left = 1 if mb.get_button_index() == MouseButton.MOUSE_BUTTON_WHEEL_LEFT else 0
		var down = 1 if mb.get_button_index() == MouseButton.MOUSE_BUTTON_WHEEL_DOWN else 0
		var up = 1 if mb.get_button_index() == MouseButton.MOUSE_BUTTON_WHEEL_UP else 0
		
		var scroll_vec:Vector2 = Vector2(right-left, down-up)
		# Moving the scroll wheel sends two events: one with pressed as true,
		# and one with pressed as false. Make sure we only process one of them.
		if (scroll_vec != Vector2() && mb.is_pressed()):
			if (control_scheme == ControlScheme.SCROLL_PANS):
				if (mb.is_ctrl_pressed()):
					if (scroll_vec.y != 0):
						# Compute the zoom factor.
						var zoom_factor:float = 1.0 if mb.get_factor() <= 0 else mb.get_factor()
						zoom_factor = ((scroll_zoom_factor - 1.0) * zoom_factor) + 1.0
						var zoom:float = 1.0 / scroll_zoom_factor if scroll_vec.y > 0 else scroll_zoom_factor
						zoom_callback.call(zoom, mb.get_position(), p_event)
						return true
				else:
					var panning:Vector2 = scroll_vec * mb.get_factor()
					if (pan_axis == PanAxis.PAN_AXIS_HORIZONTAL):
						panning = Vector2(panning.x + panning.y, 0)
					elif (pan_axis == PanAxis.PAN_AXIS_VERTICAL):
						panning = Vector2(0, panning.x + panning.y)
					elif (mb.is_shift_pressed()):
						panning = Vector2(panning.y, panning.x)
					pan_callback.call(-panning * scroll_speed, p_event)
					return true
			else:
				if (mb.is_ctrl_pressed()):
					var panning:Vector2 = scroll_vec * mb.get_factor()
					if (pan_axis == PanAxis.PAN_AXIS_HORIZONTAL):
						panning = Vector2(panning.x + panning.y, 0)
					elif (pan_axis == PanAxis.PAN_AXIS_VERTICAL):
						panning = Vector2(0, panning.x + panning.y)
					elif (mb.is_shift_pressed()):
						panning = Vector2(panning.y, panning.x)
					pan_callback.call(-panning * scroll_speed, p_event)
					return true
				elif (!mb.is_shift_pressed() && scroll_vec.y != 0):
					# Compute the zoom factor.
					var zoom_factor:float = 1.0 if mb.get_factor() <= 0 else mb.get_factor()
					zoom_factor = ((scroll_zoom_factor - 1.0) * zoom_factor) + 1.0
					var zoom:float = 1.0 / scroll_zoom_factor if scroll_vec.y > 0 else scroll_zoom_factor
					zoom_callback.call(zoom, mb.get_position(), p_event)
					return true

		# Alt is not used for button presses, so ignore it.
		if (mb.is_alt_pressed()):
			return false

		drag_type = DragType.DRAG_TYPE_NONE

		var is_drag_zoom_event:bool = mb.get_button_index() == MouseButton.MOUSE_BUTTON_MIDDLE && mb.is_ctrl_pressed()

		if (is_drag_zoom_event):
			if (mb.is_pressed()):
				drag_type = DragType.DRAG_TYPE_ZOOM
				drag_zoom_position = mb.get_position()
			return true

		var is_drag_pan_event:bool = (mb.get_button_index() == MouseButton.MOUSE_BUTTON_MIDDLE
			or (enable_rmb && mb.get_button_index() == MouseButton.MOUSE_BUTTON_RIGHT)
			or (!simple_panning_enabled && mb.get_button_index() == MouseButton.MOUSE_BUTTON_LEFT && is_panning())
			or (force_drag && mb.get_button_index() == MouseButton.MOUSE_BUTTON_LEFT))

		if (is_drag_pan_event):
			if (mb.is_pressed()):
				drag_type = DragType.DRAG_TYPE_PAN
			return mb.get_button_index() != MouseButton.MOUSE_BUTTON_LEFT or mb.is_pressed() # Don't consume LMB release events (it fixes some selection problems).

	if is_instance_of(p_event, InputEventMouseMotion):
		var mm = p_event as InputEventMouseMotion
		if (drag_type == DragType.DRAG_TYPE_PAN):
			var warped_panning_viewport:Viewport = warped_panning_owner.get_viewport() if warped_panning_owner else null
			if (warped_panning_viewport && p_canvas_rect.has_area()):
				pan_callback.call(wrap_mouse_in_rect(warped_panning_viewport, mm.get_relative(), p_canvas_rect), p_event)
			else:
				pan_callback.call(mm.get_relative(), p_event)
			return true
		elif (drag_type == DragType.DRAG_TYPE_ZOOM):
			var drag_zoom_distance:float = 0.0
			if (zoom_style == ZoomStyle.ZOOM_VERTICAL):
				drag_zoom_distance = mm.get_relative().y
			elif (zoom_style == ZoomStyle.ZOOM_HORIZONTAL):
				drag_zoom_distance = mm.get_relative().x * -1.0 # Needs to be flipped to match the 3D horizontal zoom style.
			var drag_zoom_factor:float = 1.0 + (drag_zoom_distance * scroll_zoom_factor * drag_zoom_sensitivity_factor)
			zoom_callback.call(drag_zoom_factor, drag_zoom_position, p_event)
			return true

	if is_instance_of(p_event, InputEventMagnifyGesture):
		var magnify_gesture = p_event as InputEventMagnifyGesture
		# Zoom gesture
		zoom_callback.call(magnify_gesture.get_factor(), magnify_gesture.get_position(), p_event)
		return true

	if is_instance_of(p_event, InputEventPanGesture):
		var pan_gesture = p_event as InputEventPanGesture
		if (pan_gesture.is_ctrl_pressed()):
			# Zoom gesture.
			var pan_zoom_factor:float = 1.02
			var zoom_direction:float = pan_gesture.get_delta().x - pan_gesture.get_delta().y
			if (zoom_direction == 0):
				return true

			var zoom:float = 1.0 / pan_zoom_factor if zoom_direction < 0 else pan_zoom_factor
			zoom_callback.call(zoom, pan_gesture.get_position(), p_event)
			return true
		pan_callback.call(-pan_gesture.get_delta() * scroll_speed, p_event)

	if is_instance_of(p_event, InputEventScreenDrag):
		var screen_drag = p_event as InputEventScreenDrag
		if Input.is_emulating_mouse_from_touch() or Input.is_emulating_touch_from_mouse():
			# This set of events also generates/is generated by
			# InputEventMouseButton/InputEventMouseMotion events which will be processed instead.
			pass
		else:
			pan_callback.call(screen_drag.get_relative(), p_event)

	if is_instance_of(p_event, InputEventKey):
		var k = p_event as InputEventKey
		if (pan_view_shortcut && pan_view_shortcut.matches_event(k)):
			pan_key_pressed = k.is_pressed()
			if (simple_panning_enabled or Input.get_mouse_button_mask() == MouseButtonMask.MOUSE_BUTTON_MASK_LEFT):
				if (pan_key_pressed):
					drag_type = DragType.DRAG_TYPE_PAN
				if (drag_type == DragType.DRAG_TYPE_PAN):
					drag_type = DragType.DRAG_TYPE_NONE
			return true
	return false

func release_pan_key() -> void:
	pan_key_pressed = false
	if (drag_type == DragType.DRAG_TYPE_PAN):
		drag_type = DragType.DRAG_TYPE_NONE

func set_callbacks(p_pan_callback:Callable, p_zoom_callback:Callable) -> void:
	pan_callback = p_pan_callback
	zoom_callback = p_zoom_callback

func set_control_scheme(p_scheme:ControlScheme) -> void:
	control_scheme = p_scheme

func set_enable_rmb(p_enable:bool) -> void:
	enable_rmb = p_enable

func set_pan_shortcut(p_shortcut:Shortcut) -> void:
	pan_view_shortcut = p_shortcut
	pan_key_pressed = false

func set_simple_panning_enabled(p_enabled:bool) -> void:
	simple_panning_enabled = p_enabled

func set_scroll_speed(p_scroll_speed:int) -> void:
	if p_scroll_speed <= 0:
		push_error("invalid scroll_speed: %s" % [p_scroll_speed])
		return
	scroll_speed = p_scroll_speed

func set_scroll_zoom_factor(p_scroll_zoom_factor:float) -> void:
	if p_scroll_zoom_factor <= 0:
		push_error("invalid scroll_zoom_factor: %s" % [p_scroll_zoom_factor])
		return
	scroll_zoom_factor = p_scroll_zoom_factor

func set_pan_axis(p_pan_axis:PanAxis) -> void:
	pan_axis = p_pan_axis

func set_zoom_style(p_zoom_style:ZoomStyle) -> void:
	zoom_style = p_zoom_style

func setup(p_scheme:ControlScheme, p_shortcut:Shortcut, p_simple_panning:bool) -> void:
	set_control_scheme(p_scheme)
	set_pan_shortcut(p_shortcut)
	set_simple_panning_enabled(p_simple_panning)

func setup_warped_panning(p_owner:Node, p_allowed:bool) -> void:
	warped_panning_owner = p_owner if p_allowed else null

func is_panning() -> bool:
	return drag_type == DragType.DRAG_TYPE_PAN or pan_key_pressed

func set_force_drag(p_force:bool) -> void:
	force_drag = p_force

func _init() -> void:
	var event = InputEventKey.new()
	event.device = -1
	event.keycode = KEY_SPACE
	
	pan_view_shortcut = Shortcut.new()
	pan_view_shortcut.events = [
		event
	]

static func wrap_mouse_in_rect(viewport:Viewport, p_relative:Vector2, p_rect:Rect2) -> Vector2:
	# Move the mouse cursor from its current position to a location bounded by `p_rect`
	# in accordance with a heuristic that takes the traveled distance `p_relative` of the mouse
	# into account.

	# All parameters are in viewport coordinates.
	# p_relative denotes the distance to the previous mouse position.
	# p_rect denotes the area, in which the mouse should be confined in.

	# The relative distance reported for the next event after a warp is in the boundaries of the
	# size of the rect on that axis, but it may be greater, in which case there's no problem as
	# fmod() will warp it, but if the pointer has moved in the opposite direction between the
	# pointer relocation and the subsequent event, the reported relative distance will be less
	# than the size of the rect and thus fmod() will be disabled for handling the situation.
	# And due to this mouse warping mechanism being stateless, we need to apply some heuristics
	# to detect the warp: if the relative distance is greater than the half of the size of the
	# relevant rect (checked per each axis), it will be considered as the consequence of a former
	# pointer warp.

	var rel_sign:Vector2 = Vector2(1 if p_relative.x >= 0.0 else -1, 1 if p_relative.y >= 0.0 else -1)
	var warp_margin:Vector2 = p_rect.size * 0.5
	var rel_warped:Vector2 = Vector2(
		fmod(p_relative.x + rel_sign.x * warp_margin.x, p_rect.size.x) - rel_sign.x * warp_margin.x,
		fmod(p_relative.y + rel_sign.y * warp_margin.y, p_rect.size.y) - rel_sign.y * warp_margin.y
	)

	var pos_local:Vector2 = viewport.get_mouse_position() - p_rect.position
	var pos_warped:Vector2 = Vector2(
		fposmod(pos_local.x, p_rect.size.x),
		fposmod(pos_local.y, p_rect.size.y)
	)
	if (pos_warped != pos_local):
		viewport.warp_mouse(pos_warped + p_rect.position)
	return rel_warped
