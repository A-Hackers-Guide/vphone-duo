# Prepares iphone-duo.blend for VPhone's 3D Duo window.
#
#   blender -b iphone-duo.blend --python prepare_duo.py -- <out_dir>
#
# Keeps the master phone, rebuilds its materials as physically based Star White
# finishes, adds Camera Control and button hit zones, gives both displays 0..1
# UVs in panel orientation, and writes DuoModel.blend and DuoModel.usdz.
# Blender units stay as authored: 1 unit = 210.45 mm (164.6 mm open width).

import bpy, bmesh, math, os, sys
from mathutils import Vector

out_dir = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.getcwd()
os.makedirs(out_dir, exist_ok=True)
MM = 1 / 210.45  # Blender units per millimetre

# MARK: - Keep one phone

keep = set(bpy.data.collections["iphone-duo"].objects)
for ob in list(bpy.data.objects):
    if ob not in keep:
        bpy.data.objects.remove(ob, do_unlink=True)
for col in list(bpy.data.collections):
    if col.name != "iphone-duo":
        bpy.data.collections.remove(col)

# Stable names the app looks up.
rename = {
    "camera-side": "half_back", "right-side": "half_front", "middle-block": "hinge_spine",
    "screen": "display_outer", "screen-foldable": "display_inner", "back": "back_panel",
    "Plane.006": "camera_plateau", "Plane.008": "button_volume", "Plane.009": "button_side",
    "apple-logo": "apple_logo", "Armature": "hinge_rig",
}
for old, new in rename.items():
    bpy.data.objects[old].name = new

# MARK: - Materials

def principled(name, base, metallic, roughness, coat=0.0, coat_rough=0.03, spec=0.5, alpha=1.0, transmission=0.0, aniso=0.0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    b = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(b.outputs["BSDF"], out.inputs["Surface"])
    b.inputs["Base Color"].default_value = (*base, 1)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = roughness
    b.inputs["Specular IOR Level"].default_value = spec
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Coat Roughness"].default_value = coat_rough
    b.inputs["Alpha"].default_value = alpha
    b.inputs["Transmission Weight"].default_value = transmission
    b.inputs["Anisotropic"].default_value = aniso
    m.surface_render_method = "BLENDED" if alpha < 1 or transmission > 0 else "DITHERED"
    return m, nt, b

def srgb(r, g, b):
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r), f(g), f(b))

# Polished titanium (Ti F0 ~ 0.54/0.50/0.45, lifted toward Apple's bright silver finish).
TITANIUM = (0.72, 0.70, 0.67)
mat_frame, _, _ = principled("duo_titanium", TITANIUM, 1.0, 0.07)
mat_frame_edge, _, _ = principled("duo_titanium_chamfer", (0.80, 0.78, 0.75), 1.0, 0.035)
mat_logo, _, _ = principled("duo_logo", (0.86, 0.84, 0.80), 1.0, 0.10)
# Star White: warm white ceramic glass, frosted (dielectric, matte).
mat_back, _, _ = principled("duo_star_white", srgb(0.937, 0.929, 0.902), 0.0, 0.48, coat=0.15, coat_rough=0.35)
mat_glass, _, _ = principled("duo_lens_glass", (0.0, 0.0, 0.0), 0.0, 0.0, coat=1.0, alpha=0.35, spec=1.0)
mat_sapphire, _, _ = principled("duo_sapphire", srgb(0.70, 0.69, 0.67), 0.0, 0.02, coat=1.0, coat_rough=0.01)
mat_bezel, _, _ = principled("duo_bezel", (0.004, 0.004, 0.004), 0.0, 0.08, coat=1.0)
mat_black, _, _ = principled("duo_black", (0.0, 0.0, 0.0), 0.0, 0.35)
mat_hit, _, _ = principled("duo_hit", (1, 0, 1), 0.0, 1.0)

# Displays: placeholder emission the app replaces with the live guest frame.
def display_material(name):
    m, nt, b = principled(name, (0, 0, 0), 0.0, 0.06, coat=1.0, coat_rough=0.0)
    b.inputs["Emission Color"].default_value = (0.02, 0.02, 0.025, 1)
    b.inputs["Emission Strength"].default_value = 1.0
    return m
mat_disp_outer = display_material("duo_display_outer")
mat_disp_inner = display_material("duo_display_inner")

# Lens interiors keep their photographed detail, as dielectric glass, not metal.
old_screen = bpy.data.materials["screen"]
img = next(n.image for n in old_screen.node_tree.nodes if n.type == "TEX_IMAGE")
mat_lens, nt, b = principled("duo_lens_photo", (0, 0, 0), 0.0, 0.12, coat=1.0)
tex = nt.nodes.new("ShaderNodeTexImage"); tex.image = img
# The photographed lenses were shot bright; bring them down to deep coated glass.
gamma = nt.nodes.new("ShaderNodeGamma"); gamma.inputs["Gamma"].default_value = 2.2
nt.links.new(tex.outputs["Color"], gamma.inputs["Color"]); nt.links.new(gamma.outputs["Color"], b.inputs["Base Color"])

swap = {
    "apple-material": mat_back, "apple-material-sides": mat_frame,
    "apple-material-sides-lighter": mat_frame_edge, "apple-material-sides-darker": mat_logo,
    "glass": mat_glass, "black": mat_bezel, "less-black": mat_black, "screen": mat_lens,
}
for ob in bpy.data.objects:
    if ob.type != "MESH":
        continue
    for slot in ob.material_slots:
        if slot.material and slot.material.name in swap:
            slot.material = swap[slot.material.name]

# Camera rings are frame metal, not back glass.
for ob in bpy.data.objects:
    if ob.type == "MESH" and ob.name.startswith("Circle"):
        for slot in ob.material_slots:
            if slot.material == mat_back:
                slot.material = mat_frame

# The plateau's flash photo becomes a real flash window.
mat_flash, _, _ = principled("duo_flash", srgb(0.96, 0.93, 0.80), 0.0, 0.25, coat=1.0)
plateau = bpy.data.objects["camera_plateau"]
for slot in plateau.material_slots:
    if slot.material == mat_lens:
        slot.material = mat_flash

# MARK: - Display UVs (u right, v down, as the panel is seen)

def remap_display(ob, display_mat, view_from_negative_y):
    me = ob.data
    idx = next(i for i, s in enumerate(ob.material_slots) if s.material == mat_lens)
    ob.material_slots[idx].material = display_mat
    bm = bmesh.new(); bm.from_mesh(me)
    uv = bm.loops.layers.uv.active or bm.loops.layers.uv.new("UVMap")
    faces = [f for f in bm.faces if f.material_index == idx]
    mw = ob.matrix_world
    pts = [mw @ v.co for f in faces for v in f.verts]
    xmin, xmax = min(p.x for p in pts), max(p.x for p in pts)
    zmin, zmax = min(p.z for p in pts), max(p.z for p in pts)
    for f in faces:
        for l in f.loops:
            w = mw @ l.vert.co
            x, z = w.x, w.z
            u = (x - xmin) / (xmax - xmin) if view_from_negative_y else (xmax - x) / (xmax - xmin)
            l[uv].uv = (u, (z - zmin) / (zmax - zmin))  # USD/Metal flip v at load
    bm.to_mesh(me); bm.free()
    return (xmax - xmin, zmax - zmin)

# UVs come from world positions at rest, when both panels lie flat facing -Y (outer) and +Y (inner).
outer = remap_display(bpy.data.objects["display_outer"], mat_disp_outer, True)
inner = remap_display(bpy.data.objects["display_inner"], mat_disp_inner, False)
print(f"[duo] outer active area {outer[0]/MM:.2f} x {outer[1]/MM:.2f} mm, inner {inner[0]/MM:.2f} x {inner[1]/MM:.2f} mm")

# The live panels become objects of their own, so the app replaces a whole
# entity's material with the guest frame instead of guessing a slot index.
def split_panel(name, display_mat):
    src = bpy.data.objects[name]
    panel = src.copy(); panel.data = src.data.copy(); panel.name = name + "_panel"
    for col in src.users_collection:
        col.objects.link(panel)
    for ob, keep_display in ((panel, True), (src, False)):
        bm = bmesh.new(); bm.from_mesh(ob.data)
        idx = next(i for i, s in enumerate(ob.material_slots) if s.material == display_mat)
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if (f.material_index == idx) != keep_display], context="FACES")
        if keep_display:
            for f in bm.faces:
                f.material_index = 0
        bm.to_mesh(ob.data); bm.free()
    panel.data.materials.clear(); panel.data.materials.append(display_mat)
split_panel("display_outer", mat_disp_outer)
split_panel("display_inner", mat_disp_inner)

# MARK: - Camera Control and button hit zones

half_back = bpy.data.objects["half_back"]
side = bpy.data.objects["button_side"]
dg = bpy.context.evaluated_depsgraph_get()
def world_bounds(ob):
    e = ob.evaluated_get(dg); m = e.to_mesh(); pts = [e.matrix_world @ v.co for v in m.vertices]; e.to_mesh_clear()
    return (Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))),
            Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts))))

smin, smax = world_bounds(side)
bmin, bmax = world_bounds(half_back)
top_z = bmax.z
# Device tree: side button at 30.85 mm, Camera Control at 73.74 mm on the same edge.
cc_len, cc_w, cc_proud = 17.2 * MM, 3.6 * MM, 0.25 * MM
cc_center_z = (smin.z + smax.z) / 2 - (73.74 - 30.85) * MM
cc_y = (smin.y + smax.y) / 2
edge_x = bmin.x

def rounded_box(name, size, center, mat, parent, bevel):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    ob = bpy.context.active_object; ob.name = name; ob.scale = size
    bpy.ops.object.transform_apply(scale=True)
    mod = ob.modifiers.new("bevel", "BEVEL"); mod.width = bevel; mod.segments = 6; mod.limit_method = "NONE"
    bpy.ops.object.modifier_apply(modifier="bevel")
    bpy.ops.object.shade_smooth()
    ob.data.materials.append(mat)
    mw = ob.matrix_world.copy(); ob.parent = parent; ob.matrix_world = mw
    return ob

rounded_box("button_camera_control", (cc_proud * 2, cc_w, cc_len), (edge_x, cc_y, cc_center_z), mat_sapphire, half_back, cc_w * 0.49)
rounded_box("button_camera_control_ring", (cc_proud * 1.2, cc_w + 0.5 * MM, cc_len + 0.5 * MM), (edge_x + 0.05 * MM, cc_y, cc_center_z), mat_frame_edge, half_back, (cc_w + 0.5 * MM) * 0.49)

vmin, vmax = world_bounds(bpy.data.objects["button_volume"])
pad = 1.2 * MM
def hit(name, mn, mx):
    c = (mn + mx) / 2; s = (mx - mn) + Vector((pad, pad, pad)) * 2
    ob = rounded_box(name, s, c, mat_hit, half_back, 0.0001)
    ob.hide_render = True
    return ob

vmid_x = (vmin.x + vmax.x) / 2
# Volume up is the half nearer the free edge (device tree edge-0 origin).
hit("hit_volume_up", Vector((vmin.x, vmin.y, vmin.z)), Vector((vmid_x, vmax.y, vmax.z)))
hit("hit_volume_down", Vector((vmid_x, vmin.y, vmin.z)), Vector((vmax.x, vmax.y, vmax.z)))
hit("hit_side", smin, smax)
hit("hit_camera_control", Vector((edge_x - cc_proud, cc_y - cc_w / 2, cc_center_z - cc_len / 2)), Vector((edge_x + cc_proud, cc_y + cc_w / 2, cc_center_z + cc_len / 2)))

# MARK: - Clean up and export

for ob in bpy.data.objects:
    if ob.animation_data:
        ob.animation_data_clear()
for pb in bpy.data.objects["hinge_rig"].pose.bones:
    for c in list(pb.constraints):
        pb.constraints.remove(c)

bpy.ops.file.pack_all()
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(out_dir, "DuoModel.blend"), compress=True)
bpy.ops.object.select_all(action="SELECT")
bpy.ops.wm.usd_export(
    filepath=os.path.join(out_dir, "DuoModel.usdz"),
    selected_objects_only=False, export_animation=False, export_armatures=True, only_deform_bones=False,
    export_materials=True, generate_preview_surface=True, export_textures_mode="NEW",
    export_uvmaps=True, export_normals=True, convert_orientation=True, export_global_forward_selection="NEGATIVE_Z",
    export_global_up_selection="Y", root_prim_path="/DuoModel",
)
print("[duo] wrote", out_dir)
