# Renders DuoModel.blend at several hinge angles under a studio environment.
#
#   blender -b DuoModel.blend --python render_previews.py -- <renders_dir> [--hdri <out.exr>]
#
# The fold here is the same mapping the app uses: hinge angle 180 (flat) to 0
# (closed); each of the 12 bend bones per side turns (180 - angle) / 24 degrees
# and each half turns 12 times that.

import bpy, math, os, sys
import numpy as np
from mathutils import Euler, Quaternion, Vector

args = sys.argv[sys.argv.index("--") + 1:]
out_dir = args[0]
hdri_out = args[args.index("--hdri") + 1] if "--hdri" in args else None
os.makedirs(out_dir, exist_ok=True)

sc = bpy.context.scene
sc.render.engine = "BLENDER_EEVEE"
sc.eevee.taa_render_samples = 64
sc.render.resolution_x, sc.render.resolution_y = 1400, 900
sc.render.film_transparent = False
sc.view_settings.view_transform = "AgX"
sc.view_settings.look = "AgX - Base Contrast"
sc.view_settings.exposure = -0.35
sc.eevee.use_raytracing = True
sc.eevee.ray_tracing_options.resolution_scale = "1"

# MARK: - Studio: soft key, rim strips, dark gradient floor reflections

world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
sc.world = world
world.use_nodes = True
wn = world.node_tree; wn.nodes.clear()
L = wn.links.new
wo = wn.nodes.new("ShaderNodeOutputWorld")
tc = wn.nodes.new("ShaderNodeTexCoord"); sep = wn.nodes.new("ShaderNodeSeparateXYZ"); L(tc.outputs["Generated"], sep.inputs[0])
# Reflection studio: bright horizon band, soft overhead, darker floor.
studio = wn.nodes.new("ShaderNodeValToRGB"); cr = studio.color_ramp
cr.elements[0].position = 0.0; cr.elements[0].color = (0.05, 0.05, 0.055, 1)
cr.elements[1].position = 1.0; cr.elements[1].color = (0.75, 0.76, 0.78, 1)
e = cr.elements.new(0.47); e.color = (0.18, 0.18, 0.19, 1)
e = cr.elements.new(0.52); e.color = (1.6, 1.6, 1.62, 1)
e = cr.elements.new(0.60); e.color = (0.35, 0.35, 0.37, 1)
mr = wn.nodes.new("ShaderNodeMapRange"); mr.inputs["From Min"].default_value = -1; mr.inputs["From Max"].default_value = 1
L(sep.outputs["Z"], mr.inputs["Value"]); L(mr.outputs["Result"], studio.inputs["Fac"])
# Backdrop the camera sees: deep graphite gradient.
back = wn.nodes.new("ShaderNodeValToRGB"); br = back.color_ramp
br.elements[0].position = 0.3; br.elements[0].color = (0.006, 0.006, 0.007, 1)
br.elements[1].position = 0.8; br.elements[1].color = (0.045, 0.046, 0.05, 1)
L(mr.outputs["Result"], back.inputs["Fac"])
lp = wn.nodes.new("ShaderNodeLightPath"); mix = wn.nodes.new("ShaderNodeMixRGB")
L(lp.outputs["Is Camera Ray"], mix.inputs["Fac"]); L(studio.outputs["Color"], mix.inputs[1]); L(back.outputs["Color"], mix.inputs[2])
bg = wn.nodes.new("ShaderNodeBackground"); L(mix.outputs["Color"], bg.inputs["Color"]); L(bg.outputs["Background"], wo.inputs["Surface"])
bg.inputs["Strength"].default_value = 1.0

def softbox(name, loc, rot, size, energy, color=(1, 1, 1)):
    l = bpy.data.lights.new(name, "AREA"); l.shape = "RECTANGLE"; l.size, l.size_y = size; l.energy = energy; l.color = color
    o = bpy.data.objects.new(name, l); sc.collection.objects.link(o); o.location = loc; o.rotation_euler = rot
    return o
center = Vector((0.0, -0.15, 0.28))
def aim(o, target=center):
    o.rotation_euler = (target - o.location).to_track_quat("-Z", "Y").to_euler()
for o in (
    softbox("key", (1.4, -2.2, 1.6), (0, 0, 0), (1.6, 1.0), 380),
    softbox("fill", (-2.0, -1.6, 0.9), (0, 0, 0), (1.2, 1.2), 120, (0.95, 0.97, 1.0)),
    softbox("rim_top", (0.0, 1.4, 2.4), (0, 0, 0), (3.0, 0.25), 700),
    softbox("rim_left", (-2.2, 1.2, 0.6), (0, 0, 0), (0.25, 2.5), 500),
    softbox("strip_right", (2.4, 0.6, 0.6), (0, 0, 0), (0.18, 2.5), 420),
):
    aim(o)

# MARK: - Orientation test pattern on both displays

def test_image(name, w, h):
    img = bpy.data.images.new(name, w, h)
    y, x = np.mgrid[0:h, 0:w]
    px = np.zeros((h, w, 4), np.float32); px[..., 3] = 1
    u, v = x / w, 1 - y / h  # v = 0 at the top of the panel
    base = np.stack([0.05 + 0.25 * u, 0.08 + 0.2 * (1 - v), 0.35 + 0.4 * v], -1)
    px[..., :3] = base
    q = 0.18
    px[(u < q) & (v < q), :3] = (1, 0.05, 0.05)      # top left: red
    px[(u > 1 - q) & (v < q), :3] = (0.05, 1, 0.1)   # top right: green
    px[(u < q) & (v > 1 - q), :3] = (0.1, 0.2, 1)    # bottom left: blue
    grid = ((x // max(1, w // 12)) + (y // max(1, w // 12))) % 2 == 0
    px[grid & (u > 0.3) & (u < 0.7) & (v > 0.3) & (v < 0.7), :3] *= 1.6
    img.pixels = px.ravel()
    return img
for name, (w, h) in (("duo_display_outer", (466, 678)), ("duo_display_inner", (890, 626))):
    m = bpy.data.materials[name]; nt = m.node_tree
    b = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = test_image(name + "_test", w, h)
    nt.links.new(t.outputs["Color"], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 1.3

# MARK: - Fold

rig = bpy.data.objects["hinge_rig"]
chains = [["Bone"] + [f"Bone.{i:03d}" for i in range(1, 13)], [f"Bone.{i:03d}" for i in range(13, 26)]]
def set_hinge(angle_deg):
    t = math.radians((180 - angle_deg) / 24)
    for chain in chains:
        for i, name in enumerate(chain):
            pb = rig.pose.bones[name]
            if i == 12:
                pb.rotation_mode = "QUATERNION"; pb.rotation_quaternion = (1, 0, 0, 0)
            elif pb.rotation_mode == "QUATERNION":
                pb.rotation_quaternion = Quaternion((0, 0, 1), t)
            else:
                pb.rotation_euler = Euler((0, 0, t))
    bpy.data.objects["half_back"].rotation_euler.y = -12 * t
    bpy.data.objects["half_front"].rotation_euler.y = 12 * t
    bpy.context.view_layer.update()

for o in bpy.data.objects:
    if o.name.startswith("hit_"):
        o.hide_render = True

cam_data = bpy.data.cameras.new("cam"); cam_data.lens = 70
cam = bpy.data.objects.new("cam", cam_data); sc.collection.objects.link(cam); sc.camera = cam
def shoot(name, angle, eye, target=center):
    set_hinge(angle)
    cam.location = eye; cam.rotation_euler = (Vector(target) - Vector(eye)).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = os.path.join(out_dir, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("[duo] rendered", name)

ENV_ONLY = "--env-only" in args
if not ENV_ONLY: shoot("01_open_inner", 180, (0.35, 2.3, 0.75), (0.0, -0.13, 0.28))
if not ENV_ONLY: shoot("02_open_back", 180, (-0.5, -2.3, 0.75), (0.0, -0.15, 0.28))
if not ENV_ONLY: shoot("03_half_open_110", 110, (1.6, 1.5, 0.9), (0.0, -0.05, 0.28))
if not ENV_ONLY: shoot("04_closed_outer", 0, (1.0, -2.1, 0.55), (0.0, -0.15, 0.28))
if not ENV_ONLY: shoot("05_closed_edge_buttons", 0, (-1.8, -1.0, 1.0), (0.0, -0.15, 0.28))
if not ENV_ONLY: set_hinge(0)
def wcenter(n):
    o = bpy.data.objects[n]; e = o.evaluated_get(bpy.context.evaluated_depsgraph_get()); m = e.to_mesh()
    c = sum((e.matrix_world @ v.co for v in m.vertices), Vector()) / len(m.vertices); e.to_mesh_clear(); return c
if not ENV_ONLY:
    cc, hb = wcenter("button_camera_control"), wcenter("back_panel")
    out = (cc - hb); out.z = 0; out.normalize()
    eye = cc + out * 1.4 + Vector((0, 0, 0.25)) + out.cross(Vector((0, 0, 1))) * 0.45
    shoot("06_free_edge_controls", 0, tuple(eye), tuple(cc + Vector((0, 0, 0.06))))

# MARK: - Environment map for the app's image-based lighting

if hdri_out:
    for o in list(bpy.data.objects):
        if o.type in ("MESH", "ARMATURE"):
            o.hide_render = True
    cam.location = center; cam.rotation_euler = (math.radians(90), 0, 0)
    cam_data.type = "PANO"; cam_data.panorama_type = "EQUIRECTANGULAR"
    sc.render.engine = "CYCLES"; sc.cycles.samples = 24; sc.cycles.device = "CPU"
    # Lights must be visible to camera rays for reflections; give each a matching emissive card.
    for o in [o for o in bpy.data.objects if o.type == "LIGHT"]:
        bpy.ops.mesh.primitive_plane_add(size=1, location=o.location, rotation=o.rotation_euler)
        card = bpy.context.active_object; card.scale = (o.data.size, o.data.size_y, 1)
        mat = bpy.data.materials.new(o.name + "_card"); mat.use_nodes = True
        nt = mat.node_tree; nt.nodes.clear(); e = nt.nodes.new("ShaderNodeEmission"); oo = nt.nodes.new("ShaderNodeOutputMaterial")
        e.inputs["Strength"].default_value = o.data.energy / (o.data.size * o.data.size_y) / 40
        e.inputs["Color"].default_value = (*o.data.color, 1)
        nt.links.new(e.outputs[0], oo.inputs[0]); card.data.materials.append(mat)
    sc.render.resolution_x, sc.render.resolution_y = 1024, 512
    sc.view_settings.view_transform = "Standard"; sc.view_settings.look = "None"
    sc.render.image_settings.file_format = "OPEN_EXR"; sc.render.image_settings.color_depth = "16"
    sc.render.filepath = hdri_out
    bpy.ops.render.render(write_still=True)
    print("[duo] wrote environment", hdri_out)
