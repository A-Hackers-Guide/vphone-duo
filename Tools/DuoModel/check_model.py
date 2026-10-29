"""Validate the Duo model with OpenUSD's validators, and check its parts."""
import collections
import sys
from pxr import Usd, UsdSkel, UsdValidation

path = sys.argv[1]
stage = Usd.Stage.Open(path)
registry = UsdValidation.ValidationRegistry()
context = UsdValidation.ValidationContext(registry.GetOrLoadAllValidators())
found = context.Validate(stage)
by_type = collections.Counter(str(e.GetType()).rsplit(".", 1)[-1] for e in found)
print("validation:", dict(by_type) or "clean")
for e in found:
    if "Error" in str(e.GetType()):
        print("  ERROR", e.GetName(), "|", e.GetMessage()[:180])
names = {p.GetName() for p in stage.Traverse()}
need = ["half_back", "half_front", "hinge_rig", "display_outer_panel", "display_inner_panel",
        "button_volume", "button_side", "button_camera_control", "hinge_spine"]
missing = [n for n in need if n not in names]
skeletons = [p for p in stage.Traverse() if p.IsA(UsdSkel.Skeleton)]
print(f"prims {len(names)}, skeletons {len(skeletons)}, missing parts {missing or 'none'}")
errors = sum(n for t, n in by_type.items() if "Error" in t)
sys.exit(1 if errors or missing or not skeletons else 0)
