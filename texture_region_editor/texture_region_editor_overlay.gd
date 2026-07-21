extends Panel

class_name TextureRegionEditorOverlay

var editor:TextureRegionEditor

func _get_cursor_shape(position: Vector2) -> CursorShape:
	var drag_index = editor.drag_index
	if drag_index == -1:
		drag_index = editor._get_overlapping_selection_handle(position)
	
	match drag_index:
		0,4:
			return CURSOR_FDIAGSIZE
		2,6:
			return CURSOR_BDIAGSIZE
		1,5:
			return CURSOR_VSIZE
		3,7:
			return CURSOR_HSIZE
	
	var margin_index = editor.edited_margin
	if margin_index == -1:
		margin_index = editor._get_overlapping_margin_line(position)
	
	match margin_index:
		0:
			return CURSOR_VSIZE;
		1:
			return CURSOR_VSIZE;
		2:
			return CURSOR_HSIZE;
		3:
			return CURSOR_HSIZE;
	
	var mtx = editor._get_offset_transform();
	var point = mtx.affine_inverse() * (position);

	if (editor.rect.has_point(point) && editor.slice_mode != TextureRegionEditor.SliceMode.SLICE_SMART):
		return CURSOR_DRAG;

	return CURSOR_ARROW;
