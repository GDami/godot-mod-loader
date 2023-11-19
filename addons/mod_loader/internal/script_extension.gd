class_name _ModLoaderScriptExtension
extends Reference


# This Class provides methods for working with script extensions.
# Currently all of the included methods are internal and should only be used by the mod loader itself.

const LOG_NAME := "ModLoader:ScriptExtension"

const cached_parent_scripts := {}

# Sort script extensions by inheritance and load order and apply them in order
static func handle_script_extensions() -> void:
	var extension_paths := []
	for extension_path in ModLoaderStore.script_extensions:
		if File.new().file_exists(extension_path):
			extension_paths.push_back(extension_path)
		else:
			ModLoaderLog.error("The child script path '%s' does not exist" % [extension_path], LOG_NAME)
			
	# Sort by inheritance and load order
	extension_paths = _sort_extension_paths(extension_paths)
	
	# Load and install all extensions
	for extension in extension_paths:
		var script: Script = apply_extension(extension)
		_reload_vanilla_child_classes_for(script)


static func apply_extension(extension_path: String) -> Script:
	# Check path to file exists
	if not File.new().file_exists(extension_path):
		ModLoaderLog.error("The child script path '%s' does not exist" % [extension_path], LOG_NAME)
		return null

	var child_script: Script = ResourceLoader.load(extension_path)
	# Adding metadata that contains the extension script path
	# We cannot get that path in any other way
	# Passing the child_script as is would return the base script path
	# Passing the .duplicate() would return a '' path
	child_script.set_meta("extension_script_path", extension_path)

	# Force Godot to compile the script now.
	# We need to do this here to ensure that the inheritance chain is
	# properly set up, and multiple mods can chain-extend the same
	# class multiple times.
	# This is also needed to make Godot instantiate the extended class
	# when creating singletons.
	# The actual instance is thrown away.
	child_script.new()

	var parent_script: Script = child_script.get_base_script()
	var parent_script_path: String = parent_script.resource_path

	# We want to save scripts for resetting later
	# All the scripts are saved in order already
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderStore.saved_scripts[parent_script_path] = []
		# The first entry in the saved script array that has the path
		# used as a key will be the duplicate of the not modified script
		ModLoaderStore.saved_scripts[parent_script_path].append(parent_script.duplicate())

	ModLoaderStore.saved_scripts[parent_script_path].append(child_script)

	ModLoaderLog.info("Installing script extension: %s <- %s" % [parent_script_path, extension_path], LOG_NAME)
	child_script.take_over_path(parent_script_path)

	return child_script


static func _sort_extension_paths(unsorted_extensions:Array)->Array:
	var sorted_by_load_order = _sort_extensions_by_load_order(unsorted_extensions)
	var inheritance_order = _get_vanilla_inheritance_order(sorted_by_load_order)
	var sorted_by_both = _sort_extensions_with_load_order_and_inheritance(sorted_by_load_order, inheritance_order)
	
	return sorted_by_both


# Sorts all given extensions following only the current load order
static func _sort_extensions_by_load_order(extensions:Array)->Array:
	var extensions_sorted: = []
	
	for _mod_data in ModLoaderStore.mod_load_order:
		for script in extensions:
			var mod_id = script.trim_prefix(_ModLoaderPath.get_unpacked_mods_dir_path()).get_slice("/", 0)
			if mod_id == _mod_data.dir_name:
				extensions_sorted.push_back(script)
	
	return extensions_sorted


# Takes in an array of extension paths, and returns an array of the vanilla paths
# sorted in the order they should be extended (going down the inheritance tree)
static func _get_vanilla_inheritance_order(extensions:Array)->Array:
	var sorted := []
	var extensions_paths := []
	
	for script_extension in extensions:
		var parent_script_path = load(script_extension).get_base_script().resource_path
		cached_parent_scripts[script_extension] = parent_script_path
		if not parent_script_path in extensions_paths:
			extensions_paths.push_back(parent_script_path)
	
	for path in extensions_paths:
		var path_tree := []
		var parent_script:Script = load(path)
		
		while parent_script:
			if not parent_script.resource_path in path_tree:
				path_tree.push_back(parent_script.resource_path)
			parent_script = parent_script.get_base_script()
		
		var insert_from = -1
		for i in path_tree.size():
			if path_tree[i] in sorted:
				insert_from = i
				break
		
		if insert_from == -1:
			sorted.append_array(path_tree)
		else:
			var target_position = sorted.find(path_tree[insert_from])
			for i in insert_from:
				sorted.insert(target_position, path_tree[insert_from - i - 1])
				pass
	
	var to_remove := []
	for path in sorted:
		if not path in extensions_paths:
			to_remove.push_back(path)
	for path in to_remove:
		sorted.erase(path)
	
	sorted.invert()
	return sorted

# Iterates over the descending vanilla inheritance tree order for the to-be-extended scripts
# For each vanilla path sort the relevant extensions following the load order
static func _sort_extensions_with_load_order_and_inheritance(load_order_sorted_extension:Array, inheritance_order:Array)->Array:
	var sorted := []
	for path in inheritance_order:
		for extension in load_order_sorted_extension:
			if cached_parent_scripts[extension] == path:
				sorted.push_back(extension)
	
	return sorted


# Reload all children classes of the vanilla class we just extended
# Calling reload() the children of an extended class seems to allow them to be extended
# e.g if B is a child class of A, reloading B after apply an extender of A allows extenders of B to properly extend B, taking A's extender(s) into account
static func _reload_vanilla_child_classes_for(script: Script) -> void:
	if script == null:
		return
	var current_child_classes := []
	var actual_path: String = script.get_base_script().resource_path
	var classes: Array = ProjectSettings.get_setting("_global_script_classes")

	for _class in classes:
		if _class.path == actual_path:
			current_child_classes.push_back(_class)
			break

	for _class in current_child_classes:
		for child_class in classes:

			if child_class.base == _class.class:
				load(child_class.path).reload()


# Used to remove a specific extension
static func remove_specific_extension_from_script(extension_path: String) -> void:
	# Check path to file exists
	if not _ModLoaderFile.file_exists(extension_path):
		ModLoaderLog.error("The extension script path \"%s\" does not exist" % [extension_path], LOG_NAME)
		return

	var extension_script: Script = ResourceLoader.load(extension_path)
	var parent_script: Script = extension_script.get_base_script()
	var parent_script_path: String = parent_script.resource_path

	# Check if the script to reset has been extended
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderLog.error("The extension parent script path \"%s\" has not been extended" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has anything actually saved
	# If we ever encounter this it means something went very wrong in extending
	if not ModLoaderStore.saved_scripts[parent_script_path].size() > 0:
		ModLoaderLog.error("The extension script path \"%s\" does not have the base script saved, this should never happen, if you encounter this please create an issue in the github repository" % [parent_script_path], LOG_NAME)
		return

	var parent_script_extensions: Array = ModLoaderStore.saved_scripts[parent_script_path].duplicate()
	parent_script_extensions.remove(0)

	# Searching for the extension that we want to remove
	var found_script_extension: Script = null
	for script_extension in parent_script_extensions:
		if script_extension.get_meta("extension_script_path") == extension_path:
			found_script_extension = script_extension
			break

	if found_script_extension == null:
		ModLoaderLog.error("The extension script path \"%s\" has not been found in the saved extension of the base script" % [parent_script_path], LOG_NAME)
		return
	parent_script_extensions.erase(found_script_extension)

	# Preparing the script to have all other extensions reapllied
	_remove_all_extensions_from_script(parent_script_path)

	# Reapplying all the extensions without the removed one
	for script_extension in parent_script_extensions:
		apply_extension(script_extension.get_meta("extension_script_path"))


# Used to fully reset the provided script to a state prior of any extension
static func _remove_all_extensions_from_script(parent_script_path: String) -> void:
	# Check path to file exists
	if not _ModLoaderFile.file_exists(parent_script_path):
		ModLoaderLog.error("The parent script path \"%s\" does not exist" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has been extended
	if not ModLoaderStore.saved_scripts.has(parent_script_path):
		ModLoaderLog.error("The parent script path \"%s\" has not been extended" % [parent_script_path], LOG_NAME)
		return

	# Check if the script to reset has anything actually saved
	# If we ever encounter this it means something went very wrong in extending
	if not ModLoaderStore.saved_scripts[parent_script_path].size() > 0:
		ModLoaderLog.error("The parent script path \"%s\" does not have the base script saved, \nthis should never happen, if you encounter this please create an issue in the github repository" % [parent_script_path], LOG_NAME)
		return

	var parent_script: Script = ModLoaderStore.saved_scripts[parent_script_path][0]
	parent_script.take_over_path(parent_script_path)

	# Remove the script after it has been reset so we do not do it again
	ModLoaderStore.saved_scripts.erase(parent_script_path)


# Used to remove all extensions that are of a specific mod
static func remove_all_extensions_of_mod(mod: ModData) -> void:
	var _to_remove_extension_paths: Array = ModLoaderStore.saved_extension_paths[mod.manifest.get_mod_id()]
	for extension_path in _to_remove_extension_paths:
		remove_specific_extension_from_script(extension_path)
		ModLoaderStore.saved_extension_paths.erase(mod.manifest.get_mod_id())
