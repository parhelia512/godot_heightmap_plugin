@tool
extends Node3D

# Child node of the terrain, used to render numerous small objects on the ground
# such as grass or rocks. They do so by using a texture covering the terrain
# (a "detail map"), which is found in the terrain data itself.
# A terrain can have multiple detail maps, and you can choose which one will be
# used with `layer_index`.
# Details use instanced rendering within their own chunk grid, scattered around
# the player. Importantly, the position and rotation of this node don't matter,
# and they also do NOT scale with map scale. Indeed, scaling the heightmap
# doesn't mean we want to scale grass blades (which is not a use case I know of).

const HTerrainData = preload("./hterrain_data.gd")
const HT_DirectMultiMeshInstance = preload("./util/direct_multimesh_instance.gd")
const HT_DirectMeshInstance = preload("./util/direct_mesh_instance.gd")
const HT_Util = preload("./util/util.gd")
const HT_Logger = preload("./util/logger.gd")
# TODO Can't preload because it causes the plugin to fail loading if assets aren't imported
const DEFAULT_MESH_PATH = "res://addons/zylann.hterrain/models/grass_quad.obj"

# Cannot use `const` because `HTerrain` depends on the current script
var HTerrain = load("res://addons/zylann.hterrain/hterrain.gd")

const CHUNK_SIZE = 32
const DEFAULT_SHADER_PATH = "res://addons/zylann.hterrain/shaders/detail.gdshader"
const DEBUG = false

# These parameters are considered built-in,
# they are managed internally so they are not directly exposed
const _API_SHADER_PARAMS = {
	"u_terrain_heightmap": true,
	"u_terrain_detailmap": true,
	"u_terrain_normalmap": true,
	"u_terrain_globalmap": true,
	"u_terrain_inverse_transform": true,
	"u_terrain_normal_basis": true,
	"u_albedo_alpha": true,
	"u_view_distance": true,
	"u_ambient_wind": true
}

# TODO Should be renamed `map_index`
# Which detail map this layer will use
@export var layer_index := 0:
	get:
		return layer_index
	set(v):
		if layer_index == v:
			return
		layer_index = v
		if is_inside_tree():
			_update_material()
			HT_Util.update_configuration_warning(self, false)


# Texture to render on the detail meshes.
@export var texture : Texture:
	get:
		return texture
	set(tex):
		texture = tex
		_material.set_shader_parameter("u_albedo_alpha", tex)


# How far detail meshes can be seen.
# TODO Improve speed of _get_chunk_aabb() so we can increase the limit
# See https://github.com/Zylann/godot_heightmap_plugin/issues/155
@export_range(1.0, 500.0) var view_distance := 100.0:
	get:
		return view_distance
	set(v):
		if view_distance == v:
			return
		view_distance = maxf(v, 1.0)
		if is_inside_tree():
			_update_material()


# Custom shader to replace the default one.
@export var custom_shader : Shader:
	get:
		return custom_shader

	set(shader):
		if custom_shader == shader:
			return

		if custom_shader != null:
			if Engine.is_editor_hint():
				custom_shader.changed.disconnect(_on_custom_shader_changed)

		custom_shader = shader
		
		if custom_shader == null:
			_material.shader = load(DEFAULT_SHADER_PATH)
		else:
			_material.shader = custom_shader

			if Engine.is_editor_hint():
				# Ability to fork default shader
				if shader.code == "":
					shader.code = _default_shader.code
				
				custom_shader.changed.connect(_on_custom_shader_changed)
		
				notify_property_list_changed()


# Density modifier, to make more or less detail meshes appear overall.
@export_range(0, 10) var density := 4.0:
	get:
		return density
	set(v):
		v = clampf(v, 0, 10)
		if v == density:
			return
		density = v
		_multimesh_need_regen = true


# Sets the seed of the random number generator that populates the multimesh
@export var fixed_seed := 0:
	get:
		return fixed_seed
	set(v):
		if v == fixed_seed:
			return
		fixed_seed = v
		_multimesh_need_regen = true


# If false, the multimesh seed will be picked from current time.
# Otherwise, `fixed_seed` will be used.
# Defaults to `false` because that was the behavior on old versions.
@export var fixed_seed_enabled := false:
	get:
		return fixed_seed_enabled
	set(v):
		if v == fixed_seed_enabled:
			return
		fixed_seed_enabled = v
		_multimesh_need_regen = true


# Mesh used for every detail instance (for example, every grass patch).
# If not assigned, an internal quad mesh will be used.
# I would have called it `mesh` but that's too broad and conflicts with local vars ._.
@export var instance_mesh : Mesh:
	get:
		return instance_mesh
	set(p_mesh):
		if p_mesh == instance_mesh:
			return
		instance_mesh = p_mesh
		_multimesh.mesh = _get_used_mesh()


# Exposes rendering layers, similar to `VisualInstance.layers`
# (IMO this annotation is not specific enough, something might be off...)
@export_flags_3d_render var render_layers := 1:
	get:
		return render_layers
	set(mask):
		render_layers = mask
		for k in _chunks:
			var chunk : Chunk = _chunks[k]
			chunk.mmi.set_layer_mask(mask)


# Exposes shadow casting setting.
# Possible values are the same as the enum `GeometryInstance.SHADOW_CASTING_SETTING_*`.
# TODO Casting to `int` should not be necessary! Had to do it otherwise GDScript complains...
@export_enum("Off", "On", "DoubleSided", "ShadowsOnly") \
	var cast_shadow := int(GeometryInstance3D.SHADOW_CASTING_SETTING_ON):
	get:
		return cast_shadow
	set(option):
		if option == cast_shadow:
			return
		cast_shadow = option
		for k in _chunks:
			var chunk : Chunk = _chunks[k]
			chunk.mmi.set_cast_shadow(option)


class Chunk:
	var mmi: HT_DirectMultiMeshInstance
	var pending_update: bool = false
	var pending_aabb_update: bool = false


var _material: ShaderMaterial = null
var _default_shader: Shader = null

# Vector2i => Chunk
var _chunks := {}

var _multimesh: MultiMesh
var _multimesh_need_regen = true
var _multimesh_instance_pool : Array[HT_DirectMultiMeshInstance] = []
var _ambient_wind_time := 0.0
#var _auto_pick_index_on_enter_tree := Engine.is_editor_hint()
var _debug_wirecube_mesh: Mesh = null
var _debug_cubes := []
var _logger := HT_Logger.get_for(self)
var _prev_frame_cmin := Vector3i()
var _prev_frame_cmax := Vector3i()
var _pending_chunk_updates : Array[Vector2i] = []
var _force_chunk_updates_next_frame : bool = false


func _init():
	_default_shader = load(DEFAULT_SHADER_PATH)
	_material = ShaderMaterial.new()
	_material.shader = _default_shader
	
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# TODO Godot 3 had the option to specify color format, but Godot 4 no longer does...
	# I only need 8-bit, but Godot 4 uses 32-bit components colors...
	#_multimesh.color_format = MultiMesh.COLOR_8BIT
	_multimesh.use_colors = true


func _enter_tree():
	var terrain = _get_terrain()
	if terrain != null:
		terrain.transform_changed.connect(_on_terrain_transform_changed)

		#if _auto_pick_index_on_enter_tree:
		#	_auto_pick_index_on_enter_tree = false
		#	_auto_pick_index()
		
		# Register this detail layer in the terrain node (this does not create a new layer)
		terrain._internal_add_detail_layer(self)

	_update_material()


func _exit_tree():
	var terrain = _get_terrain()
	if terrain != null:
		terrain.transform_changed.disconnect(_on_terrain_transform_changed)
		# Unregister from terrain
		terrain._internal_remove_detail_layer(self)
	_update_material()
	for k in _chunks.keys():
		_recycle_chunk(k)
	_chunks.clear()


#func _auto_pick_index():
#	# Automatically pick an unused layer
#
#	var terrain = _get_terrain()
#	if terrain == null:
#		return
#
#	var terrain_data = terrain.get_data()
#	if terrain_data == null or terrain_data.is_locked():
#		return
#
#	var auto_index := layer_index
#	var others = terrain.get_detail_layers()
#
#	if len(others) > 0:
#		var used_layers := []
#		for other in others:
#			used_layers.append(other.layer_index)
#		used_layers.sort()
#
#		auto_index = used_layers[-1]
#		for i in range(1, len(used_layers)):
#			if used_layers[i - 1] - used_layers[i] > 1:
#				# Found a hole, take it instead
#				auto_index = used_layers[i] - 1
#				break
#
#	print("Auto picked ", auto_index, " ")
#	layer_index = auto_index


func _get_property_list() -> Array:
	# Dynamic properties coming from the shader
	var props := []
	if _material != null:
		var shader_params = _material.shader.get_shader_uniform_list(true)
		for p in shader_params:
			if _API_SHADER_PARAMS.has(p.name):
				continue
			var cp := {}
			for k in p:
				cp[k] = p[k]
			# See HTerrain._get_property_list for more information about this
			if cp.usage == PROPERTY_USAGE_GROUP:
				cp.hint_string = "shader_params/"
			else:
				cp.name = str("shader_params/", p.name)
			props.append(cp)
	return props


func _get(key: StringName):
	var key_str := String(key)
	if key_str.begins_with("shader_params/"):
		var param_name = key_str.substr(len("shader_params/"))
		return get_shader_param(param_name)


func _set(key: StringName, v):
	var key_str := String(key)
	if key_str.begins_with("shader_params/"):
		var param_name = key_str.substr(len("shader_params/"))
		set_shader_param(param_name, v)


func get_shader_param(param_name: String):
	return HT_Util.get_shader_material_parameter(_material, param_name)


func set_shader_param(param_name: String, v):
	_material.set_shader_parameter(param_name, v)


func _get_terrain():
	if is_inside_tree():
		return get_parent()
	return null


# Compat
func set_texture(tex: Texture):
	texture = tex


# Compat
func get_texture() -> Texture:
	return texture


# Compat
func set_layer_index(v: int):
	layer_index = v


# Compat
func get_layer_index() -> int:
	return layer_index


# Compat
func set_view_distance(v: float):
	return view_distance


# Compat
func get_view_distance() -> float:
	return view_distance


# Compat
func set_custom_shader(shader: Shader):
	custom_shader = shader


# Compat
func get_custom_shader() -> Shader:
	return custom_shader


# Compat
func set_instance_mesh(p_mesh: Mesh):
	instance_mesh = p_mesh


# Compat
func get_instance_mesh() -> Mesh:
	return instance_mesh


# Compat
func set_render_layer_mask(mask: int):
	render_layers = mask


# Compat
func get_render_layer_mask() -> int:
	return render_layers


func _get_used_mesh() -> Mesh:
	if instance_mesh == null:
		var mesh := load(DEFAULT_MESH_PATH) as Mesh
		if mesh == null:
			_logger.error(str("Failed to load default mesh: ", DEFAULT_MESH_PATH))
		return mesh
	return instance_mesh


# Compat
func set_density(v: float):
	density = v


# Compat
func get_density() -> float:
	return density


# Updates texture references and values that come from the terrain itself.
# This is typically used when maps are being swapped around in terrain data,
# so we can restore texture references that may break.
func update_material():
	_update_material()
	# Formerly update_ambient_wind, reset


func _notification(what: int):
	match what:
		NOTIFICATION_ENTER_WORLD:
			_set_world(get_world_3d())

		NOTIFICATION_EXIT_WORLD:
			_set_world(null)

		NOTIFICATION_VISIBILITY_CHANGED:
			_set_visible(visible)
			
		NOTIFICATION_PREDELETE:
			# Force DirectMeshInstances to be destroyed before the material.
			# Otherwise it causes RenderingServer errors...
			_chunks.clear()
			_multimesh_instance_pool.clear()


func _set_visible(v: bool):
	for k in _chunks:
		var chunk : Chunk = _chunks[k]
		chunk.mmi.set_visible(v)


func _set_world(w: World3D):
	for k in _chunks:
		var chunk : Chunk = _chunks[k]
		chunk.mmi.set_world(w)


func _on_terrain_transform_changed(gt: Transform3D):
	_update_material()

	var terrain = _get_terrain()
	if terrain == null:
		_logger.error("Detail layer is not child of a terrain!")
		return
	
	var terrain_transform : Transform3D = terrain.get_internal_transform_unscaled()

	# Update AABBs and transforms, because scale might have changed
	for k in _chunks:
		var chunk : Chunk = _chunks[k]
		var mmi := chunk.mmi
		var aabb := _get_chunk_aabb(terrain, Vector3(k.x * CHUNK_SIZE, 0, k.y * CHUNK_SIZE))
		# Nullify XZ translation because that's done by transform already
		aabb.position.x = 0
		aabb.position.z = 0
		mmi.set_aabb(aabb)
		mmi.set_transform(_get_chunk_transform(terrain_transform, k.x, k.y))


func process(delta: float, viewer_pos: Vector3):
	var terrain = _get_terrain()
	if terrain == null:
		_logger.error("DetailLayer processing while terrain is null!")
		return

	if _multimesh_need_regen:
		print("Regen multimesh")
		_regen_multimesh()
		_multimesh_need_regen = false
		# Crash workaround for Godot 3.1
		# See https://github.com/godotengine/godot/issues/32500
		for k in _chunks:
			var chunk : Chunk = _chunks[k]
			chunk.mmi.set_multimesh(_multimesh)

	# Detail layers are unaffected by ground map_scale
	var terrain_transform_without_map_scale : Transform3D = \
		terrain.get_internal_transform_unscaled()
	var local_viewer_pos : Vector3 = \
		terrain_transform_without_map_scale.affine_inverse() * viewer_pos

	var viewer_cpos := Vector3i(local_viewer_pos / CHUNK_SIZE)

	var cr := int(view_distance) / CHUNK_SIZE + 1

	var cmin := viewer_cpos - Vector3i(cr, cr, cr)
	var cmax := viewer_cpos + Vector3i(cr, cr, cr)

	var terrain_data : HTerrainData = terrain.get_data()
	var map_res := terrain_data.get_resolution()
	var map_scale : Vector3 = terrain.map_scale

	var terrain_size_v2i := Vector2i(map_res * map_scale.x, map_res * map_scale.z)
	var terrain_num_chunks_v2i := terrain_size_v2i / CHUNK_SIZE
	
	cmin.x = clampi(cmin.x, 0, terrain_num_chunks_v2i.x)
	cmin.z = clampi(cmin.z, 0, terrain_num_chunks_v2i.y)
	
	cmax.x = clampi(cmax.x, 0, terrain_num_chunks_v2i.x)
	cmax.z = clampi(cmax.z, 0, terrain_num_chunks_v2i.y)
	
	# This algorithm isn't the most efficient ever.
	# Maybe we could switch to a clipbox algorithm eventually, and updating only when the viewer
	# changes chunk position?

	if DEBUG and visible:
		_debug_cubes.clear()
		#for cz in range(cmin_z, cmax_z):
			#for cx in range(cmin_x, cmax_x):
				#_add_debug_cube(terrain, _get_chunk_aabb(terrain, Vector3(cx, 0, cz) * CHUNK_SIZE),
					#terrain_transform_without_map_scale)
		for k in _chunks:
			var aabb := _get_chunk_aabb(terrain, Vector3(k.x, 0, k.y) * CHUNK_SIZE)
			_add_debug_cube(terrain, aabb, terrain_transform_without_map_scale)
		
		_add_debug_cube(terrain, 
			AABB(local_viewer_pos - Vector3(1,1,1), Vector3(2,2,2)), 
			terrain_transform_without_map_scale)
	
	var time_enter := 0
	var time_exit := 0
	
	# Only update when the camera moves across chunks
	if cmin != _prev_frame_cmin or cmax != _prev_frame_cmax or _force_chunk_updates_next_frame:
		_force_chunk_updates_next_frame = false
		
		for cz in range(cmin.z, cmax.z):
			for cx in range(cmin.x, cmax.x):
		
				var cpos2d := Vector2i(cx, cz)
				if _chunks.has(cpos2d):
					continue
		
				var aabb := _get_chunk_aabb(terrain, Vector3(cx, 0, cz) * CHUNK_SIZE)
				var d := _get_approx_distance_to_chunk_aabb(aabb, local_viewer_pos)
		
				if d < view_distance:
					_load_chunk(terrain_transform_without_map_scale, cx, cz, aabb)
		
		for k in _chunks:
			var chunk : Chunk = _chunks[k]
			# TODO Maybe we shouldn't include chunks that were just loaded above?
			if not chunk.pending_update:
				chunk.pending_update = true
				_pending_chunk_updates.append(k)
		
	_process_pending_updates(terrain, local_viewer_pos)
	
	# Update time manually, so we can accelerate the animation when strength is increased,
	# without causing phase jumps (which would be the case if we just scaled TIME)
	var ambient_wind_frequency = 1.0 + 3.0 * terrain.ambient_wind
	_ambient_wind_time += delta * ambient_wind_frequency
	var awp = _get_ambient_wind_params()
	_material.set_shader_parameter("u_ambient_wind", awp)
	
	_prev_frame_cmin = cmin
	_prev_frame_cmax = cmax


func on_heightmap_region_changed(rect: Rect2i) -> void:
	# Whether chunks should be loaded or not and their AABB may change,
	# even if the camera didn't move
	_force_chunk_updates_next_frame = true
	
	# The AABB of existing chunks may change
	var cmin : Vector2i = rect.position / CHUNK_SIZE
	var cmax : Vector2i = ceildiv_vec2i_int(rect.end, CHUNK_SIZE)
	for cz in range(cmin.y, cmax.y):
		for cx in range(cmin.x, cmax.x):
			var cpos := Vector2i(cx, cz)
			var chunk : Chunk = _chunks.get(cpos)
			if chunk != null and not chunk.pending_update:
				chunk.pending_update = true
				chunk.pending_aabb_update = true
				_pending_chunk_updates.append(cpos)


static func ceildiv(x: int, d: int) -> int:
	assert(d > 0);
	if x < 0:
		return (x - d + 1) / d
	return x / d


static func ceildiv_vec2i_int(v: Vector2i, d: int) -> Vector2i:
	return Vector2i(ceildiv(v.x, d), ceildiv(v.y, d))


func _process_pending_updates(terrain, local_viewer_pos: Vector3):
	# Defer this over multiple frames
	var budget_us := 1000
	var time_before := Time.get_ticks_usec()
	
	while _pending_chunk_updates.size() > 0:
		var cpos : Vector2i = _pending_chunk_updates.pop_back()
		var chunk : Chunk = _chunks[cpos]
		chunk.pending_update = false
		
		var aabb := _get_chunk_aabb(terrain, Vector3(cpos.x, 0, cpos.y) * CHUNK_SIZE)
		var d := _get_approx_distance_to_chunk_aabb(aabb, local_viewer_pos)
		if d > view_distance:
			_recycle_chunk(cpos)
		elif chunk.pending_aabb_update:
			chunk.pending_aabb_update = false
			chunk.mmi.set_aabb(aabb)
		
		if Time.get_ticks_usec() - time_before > budget_us:
			break


# It would be nice if Godot had "AABB.distance_squared_to(vec3)"...
# Using an approximation here cuz GDScript is slow.
static func _get_approx_distance_to_chunk_aabb(aabb: AABB, pos: Vector3) -> float:
	# Distance to center is faster but has issues with very large map scale.
	# Detail chunks are based on cached vertical bounds.
	# Usually it works fine on moderate scales, but on huge map scales,
	# vertical bound chunks cover such large areas that detail chunks often
	# stay exceedingly tall, in turn causing their centers to be randomly
	# far from the ground, and then getting unloaded because assumed too far away
	#return aabb.get_center().distance_to(pos)
	
	if aabb.has_point(pos):
		return 0.0
	var delta := (pos - aabb.get_center()).abs() - aabb.size * 0.5
	return maxf(delta.x, maxf(delta.y, delta.z))


# Gets local-space AABB of a detail chunk.
# This only apply map_scale in Y, because details are not affected by X and Z map scale.
func _get_chunk_aabb(terrain, lpos: Vector3) -> AABB:
	var terrain_scale = terrain.map_scale
	var terrain_data = terrain.get_data()
	var origin_cells_x := int(lpos.x / terrain_scale.x)
	var origin_cells_z := int(lpos.z / terrain_scale.z)
	# We must at least sample 1 cell, in cases where map_scale is greater than the size of our 
	# chunks. This is quite an extreme situation though
	var size_cells_x := int(ceilf(CHUNK_SIZE / terrain_scale.x))
	var size_cells_z := int(ceilf(CHUNK_SIZE / terrain_scale.z))
	
	var aabb = terrain_data.get_region_aabb(
		origin_cells_x, origin_cells_z, size_cells_x, size_cells_z)
	
	aabb.position = Vector3(lpos.x, lpos.y + aabb.position.y * terrain_scale.y, lpos.z)
	aabb.size = Vector3(CHUNK_SIZE, aabb.size.y * terrain_scale.y, CHUNK_SIZE)
	return aabb


func _get_chunk_transform(terrain_transform: Transform3D, cx: int, cz: int) -> Transform3D:
	var lpos := Vector3(cx, 0, cz) * CHUNK_SIZE
	# `terrain_transform` should be the terrain's internal transform, without `map_scale`.
	var trans := Transform3D(
		terrain_transform.basis,
		terrain_transform.origin + terrain_transform.basis * lpos)
	return trans


func _load_chunk(terrain_transform_without_map_scale: Transform3D, cx: int, cz: int, aabb: AABB):
	aabb.position.x = 0
	aabb.position.z = 0

	var mmi : HT_DirectMultiMeshInstance = null
	if len(_multimesh_instance_pool) != 0:
		mmi = _multimesh_instance_pool[-1]
		_multimesh_instance_pool.pop_back()
	else:
		mmi = HT_DirectMultiMeshInstance.new()
		mmi.set_world(get_world_3d())
		mmi.set_multimesh(_multimesh)

	var trans := _get_chunk_transform(terrain_transform_without_map_scale, cx, cz)
	
	mmi.set_material_override(_material)
	mmi.set_transform(trans)
	mmi.set_aabb(aabb)
	mmi.set_layer_mask(render_layers)
	mmi.set_cast_shadow(cast_shadow)
	mmi.set_visible(visible)
	
	var chunk := Chunk.new()
	chunk.mmi = mmi
	_chunks[Vector2i(cx, cz)] = chunk


func _recycle_chunk(cpos2d: Vector2i):
	var chunk : Chunk = _chunks[cpos2d]
	_chunks.erase(cpos2d)
	chunk.mmi.set_visible(false)
	_multimesh_instance_pool.append(chunk.mmi)


func _get_ambient_wind_params() -> Vector2:
	var aw := 0.0
	var terrain = _get_terrain()
	if terrain != null:
		aw = terrain.ambient_wind
	# amplitude, time
	return Vector2(aw, _ambient_wind_time)


func _update_material():
	# Sets API shader properties. Custom properties are assumed to be set already
	_logger.debug("Updating detail layer material")

	var terrain_data : HTerrainData = null
	var terrain = _get_terrain()
	var it := Transform3D()
	var normal_basis := Basis()

	if terrain != null:
		var gt : Transform3D = terrain.get_internal_transform()
		it = gt.affine_inverse()
		terrain_data = terrain.get_data()
		# This is needed to properly transform normals if the terrain is scaled.
		# However we don't want to pick up rotation because it's already factored in the instance
		#normal_basis = gt.basis.inverse().transposed()
		normal_basis = Basis().scaled(terrain.map_scale).inverse().transposed()

	var mat := _material

	mat.set_shader_parameter("u_terrain_inverse_transform", it)
	mat.set_shader_parameter("u_terrain_normal_basis", normal_basis)
	mat.set_shader_parameter("u_albedo_alpha", texture)
	mat.set_shader_parameter("u_view_distance", view_distance)
	mat.set_shader_parameter("u_ambient_wind", _get_ambient_wind_params())

	var heightmap_texture : Texture = null
	var normalmap_texture : Texture = null
	var detailmap_texture : Texture = null
	var globalmap_texture : Texture = null

	if terrain_data != null:
		if terrain_data.is_locked():
			_logger.error("Terrain data locked, can't update detail layer now")
			return

		heightmap_texture = terrain_data.get_texture(HTerrainData.CHANNEL_HEIGHT)
		normalmap_texture = terrain_data.get_texture(HTerrainData.CHANNEL_NORMAL)

		if layer_index < terrain_data.get_map_count(HTerrainData.CHANNEL_DETAIL):
			detailmap_texture = terrain_data.get_texture(HTerrainData.CHANNEL_DETAIL, layer_index)

		if terrain_data.get_map_count(HTerrainData.CHANNEL_GLOBAL_ALBEDO) > 0:
			globalmap_texture = terrain_data.get_texture(HTerrainData.CHANNEL_GLOBAL_ALBEDO)
	else:
		_logger.error("Terrain data is null, can't update detail layer completely")

	mat.set_shader_parameter("u_terrain_heightmap", heightmap_texture)
	mat.set_shader_parameter("u_terrain_detailmap", detailmap_texture)
	mat.set_shader_parameter("u_terrain_normalmap", normalmap_texture)
	mat.set_shader_parameter("u_terrain_globalmap", globalmap_texture)


func _add_debug_cube(terrain: Node3D, aabb: AABB, terrain_transform_without_scale: Transform3D):
	var world : World3D = terrain.get_world_3d()

	if _debug_wirecube_mesh == null:
		_debug_wirecube_mesh = HT_Util.create_wirecube_mesh()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_wirecube_mesh.surface_set_material(0, mat)
	
	# Flat terrain makes cubes invisible
	aabb.size.y = maxf(aabb.size.y, 1.0)

	var debug_cube := HT_DirectMeshInstance.new()
	debug_cube.set_mesh(_debug_wirecube_mesh)
	debug_cube.set_world(world)
	#aabb.position.y += 0.2*randf()
	debug_cube.set_transform(terrain_transform_without_scale \
		* Transform3D(Basis().scaled(aabb.size), aabb.position))

	_debug_cubes.append(debug_cube)


func _regen_multimesh():
	# We modify the existing multimesh instead of replacing it.
	# DirectMultiMeshInstance does not keep a strong reference to them,
	# so replacing would break pooled instances.
	
	var rng := RandomNumberGenerator.new()
	if fixed_seed_enabled:
		rng.seed = fixed_seed
	else:
		rng.randomize()
	
	_generate_multimesh(CHUNK_SIZE, density, _get_used_mesh(), _multimesh, rng)


func is_layer_index_valid() -> bool:
	var terrain = _get_terrain()
	if terrain == null:
		return false
	var data = terrain.get_data()
	if data == null:
		return false
	return layer_index >= 0 and layer_index < data.get_map_count(HTerrainData.CHANNEL_DETAIL)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()

	var terrain = _get_terrain()
	if not (is_instance_of(terrain, HTerrain)):
		warnings.append("This node must be child of an HTerrain node")
		return warnings

	var data = terrain.get_data()
	if data == null:
		warnings.append("The terrain has no data")
		return warnings

	if data.get_map_count(HTerrainData.CHANNEL_DETAIL) == 0:
		warnings.append("The terrain does not have any detail map")
		return warnings

	if layer_index < 0 or layer_index >= data.get_map_count(HTerrainData.CHANNEL_DETAIL):
		warnings.append("Layer index is out of bounds")
		return warnings

	var tex = data.get_texture(HTerrainData.CHANNEL_DETAIL, layer_index)
	if tex == null:
		warnings.append("The terrain does not have a map assigned in slot {0}" \
			.format([layer_index]))

	return warnings


# Compat
func set_cast_shadow(option: int):
	cast_shadow = option


# Compat
func get_cast_shadow() -> int:
	return cast_shadow


func _on_custom_shader_changed():
	notify_property_list_changed()


static func _generate_multimesh(
		resolution: int, density: float, mesh: Mesh, multimesh: MultiMesh, 
		rng: RandomNumberGenerator):
	
	assert(multimesh != null)
	
	var position_randomness := 0.5
	var scale_randomness := 0.0
	#var color_randomness = 0.5

	var cell_count := resolution * resolution
	var idensity := int(density)
	var random_instance_count := int(cell_count * (density - floorf(density)))
	var total_instance_count := cell_count * idensity + random_instance_count
	
	multimesh.instance_count = total_instance_count
	multimesh.mesh = mesh
	
	# First pass ensures uniform spread
	var i := 0
	for z in resolution:
		for x in resolution:
			for j in idensity:
				var pos := Vector3(x, 0, z)
				pos.x += rng.randf_range(-position_randomness, position_randomness)
				pos.z += rng.randf_range(-position_randomness, position_randomness)
	
				multimesh.set_instance_color(i, Color(1, 1, 1))
				multimesh.set_instance_transform(i, \
					Transform3D(_get_random_instance_basis(scale_randomness, rng), pos))
				i += 1
	
	# Second pass adds the rest
	for j in random_instance_count:
		var pos = Vector3(rng.randf_range(0, resolution), 0, rng.randf_range(0, resolution))
		multimesh.set_instance_color(i, Color(1, 1, 1))
		multimesh.set_instance_transform(i, \
			Transform3D(_get_random_instance_basis(scale_randomness, rng), pos))
		i += 1


static func _get_random_instance_basis(scale_randomness: float, rng: RandomNumberGenerator) -> Basis:
	var sr := rng.randf_range(0, scale_randomness)
	var s := 1.0 + (sr * sr * sr * sr * sr) * 50.0

	var basis := Basis()
	basis = basis.scaled(Vector3(1, s, 1))
	basis = basis.rotated(Vector3(0, 1, 0), rng.randf_range(0, PI))
	
	return basis
