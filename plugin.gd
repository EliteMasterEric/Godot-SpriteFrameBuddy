@tool
extends EditorPlugin

## The last directory we selected with the FileDialog
static var last_atlas_path:String = ""
## The last region we selected with the Region Editor
static var region_cache:Dictionary[RID, Rect2]

static var spriteframes_panel:Node
static var spriteframes_addatlastexture:Button

var current_spriteframes:SpriteFrames = null

const TARGET_TYPES = ["SpriteFrames", "AnimatedSprite2D"]

func _enter_tree() -> void:
	attach_spriteframes()
	inject_buttons()
	
func attach_spriteframes() -> void:
	if spriteframes_panel != null:
		return
	
	var base = EditorInterface.get_base_control()
	spriteframes_panel = base.find_child("*SpriteFrames*", true, false)
	if spriteframes_panel != null:
		# Rename the panel because that's neat.
		spriteframes_panel.name = "Sprite Frames"
	else:
		push_error("Couldn't find SpriteFrames panel?")
		
func _handles(object):
	for x in TARGET_TYPES:
		if ClassDB.is_parent_class(object.get_class(), x):
			return true
	return false

func _edit(object: Object) -> void:
	if object == null:
		print("Dropping SpriteFrames...")
		current_spriteframes = null
	elif is_instance_of(object, SpriteFrames):
		current_spriteframes = object
		print("Got SpriteFrames directly! %s" % current_spriteframes.resource_path)
	elif is_instance_of(object, AnimatedSprite2D):
		current_spriteframes = object.sprite_frames
		print("Got SpriteFrames indirectly! %s" % current_spriteframes.resource_path)
	else:
		push_error("Got object of unknown type: %s" % object)

## Injects buttons into the SpriteFrames interface.
func inject_buttons() -> void:	
	# Main container
	var core = spriteframes_panel.get_child(0)
	# Left container containing the animation list
	var left_pane = core.get_child(0)
	# Right container where the animation frames are
	var right_pane = core.get_child(2)
	
	var right_pane_body = right_pane.get_child(1).get_child(0)
	var right_pane_toolbar = right_pane_body.get_child(0)
	var right_pane_listview = right_pane_body.get_child(1)
	
	# The buttons to play/pause an animation.
	var right_pane_toolbar_group_animpreview = right_pane_toolbar.get_child(0)
	# The buttons to add, copy, or delete frames.
	var right_pane_toolbar_group_frames:HBoxContainer = right_pane_toolbar.get_child(2)
	
	_inject_addatlastexture(right_pane_toolbar_group_frames)

func _inject_addatlastexture(target:HBoxContainer) -> void:
	if spriteframes_addatlastexture == null:
		spriteframes_addatlastexture = Button.new()
		target.add_child(spriteframes_addatlastexture)
	
	spriteframes_addatlastexture.tooltip_text = "Add Frame from Sprite Sheet"
	spriteframes_addatlastexture.icon = EditorInterface.get_base_control().get_theme_icon("AtlasTexture", "EditorIcons")
	spriteframes_addatlastexture.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	spriteframes_addatlastexture.pressed.connect(open_spritesheet_texture.bind(open_region_editor))
	target.move_child(spriteframes_addatlastexture, 2)
	
	# Hide the old frame fetcher because it sucks.
	target.get_child(1).hide()

func get_current_spriteframe_animation() -> String:
	# Main container
	var core = spriteframes_panel.get_child(0)
	# Left container containing the animation list
	var left_pane = core.get_child(0)
	# Right container where the animation frames are
	var right_pane = core.get_child(2)
	
	var left_pane_body = left_pane.get_child(1).get_child(0)
	var left_pane_tree:Tree = left_pane_body.get_child(2)
	
	var selected_tree_item:TreeItem = left_pane_tree.get_selected()
	var selected_item_text = selected_tree_item.get_text(0)
	
	return selected_item_text

func open_spritesheet_texture(callback:Callable) -> void:
	var dialog = EditorFileDialog.new()
	dialog.file_selected.connect(callback)
	dialog.title = "Open Sprite Sheet"
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.unresizable = false
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.size = Vector2(1280, 960)
	# See: https://github.com/godotengine/godot/pull/115133
	dialog.current_path = last_atlas_path
	dialog.hidden_files_toggle_enabled = false
	
	var extensions:Array[String] = []
	extensions.assign(ResourceLoader.get_recognized_extensions_for_type("Texture2D"))
	dialog.filters = extensions.map(func(ext): return "*.%s" % ext)
	dialog.popup_exclusive_centered(self)

func open_region_editor(path:String) -> void:
	last_atlas_path = path
	
	var resource = load(path)
	if is_instance_of(resource, Texture2D):
		var atlas_texture = AtlasTexture.new()
		atlas_texture.atlas = resource
		atlas_texture.region = Rect2(0, 0, 16, 16)
		if region_cache.has(atlas_texture.get_rid()):
			atlas_texture.region = region_cache.get(atlas_texture.get_rid())
		
		var tex_edit = TextureRegionEditor.new()
		tex_edit.plugin = self
		tex_edit.get_ok_button().pressed.connect(add_sprite_frame.bind(atlas_texture))
		add_child(tex_edit)
		tex_edit.edit(atlas_texture, )
	else:
		print("Resource: %s" % resource)

func add_sprite_frame(texture:AtlasTexture) -> void:
	if current_spriteframes == null:
		push_error("Couldn't attach to AtlasTexture for writing!")
	
	# Remember the region we used for next time.
	region_cache[texture.atlas.get_rid()] = texture.region
	
	var target = current_spriteframes
	var target_anim = get_current_spriteframe_animation()
	
	var frame_count = target.get_frame_count(target_anim);
	
	get_undo_redo().create_action("Add Frame", UndoRedo.MERGE_DISABLE, target)
	get_undo_redo().add_do_method(target, "add_frame", target_anim, texture, 1.0, -1)
	get_undo_redo().add_undo_method(target, "remove_frame", target_anim, frame_count)
	get_undo_redo().commit_action()
	
	var frame_count_after = target.get_frame_count(target_anim)
	refresh_sprite_frames_editor()

## This is a bit of a hack that forces to redraw the SpriteFramesEditor, so the
## changes can in the animation can be seen immediately.
func refresh_sprite_frames_editor() -> void:
	var animations_tree: Tree = spriteframes_panel.find_children("", "Tree", true, false).front()
	if not animations_tree:
		return

	var tree_item: TreeItem = animations_tree.get_selected()
	if not tree_item:
		return

	tree_item.select(0)
