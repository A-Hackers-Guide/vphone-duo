"""kernel_jb.py — Jailbreak extension patcher for iOS kernelcache."""

from .kernel_jb_base import KernelJBPatcherBase
from .kernel_jb_patch_amfi_trustcache import KernelJBPatchAmfiTrustcacheMixin
from .kernel_jb_patch_amfi_execve import KernelJBPatchAmfiExecveMixin
from .kernel_jb_patch_task_conversion import KernelJBPatchTaskConversionMixin
from .kernel_jb_patch_sandbox_extended import KernelJBPatchSandboxExtendedMixin
from .kernel_jb_patch_post_validation import KernelJBPatchPostValidationMixin
from .kernel_jb_patch_proc_security import KernelJBPatchProcSecurityMixin
from .kernel_jb_patch_proc_pidinfo import KernelJBPatchProcPidinfoMixin
from .kernel_jb_patch_port_to_map import KernelJBPatchPortToMapMixin
from .kernel_jb_patch_vm_fault import KernelJBPatchVmFaultMixin
from .kernel_jb_patch_vm_protect import KernelJBPatchVmProtectMixin
from .kernel_jb_patch_mac_mount import KernelJBPatchMacMountMixin
from .kernel_jb_patch_dounmount import KernelJBPatchDounmountMixin
from .kernel_jb_patch_bsd_init_auth import KernelJBPatchBsdInitAuthMixin
from .kernel_jb_patch_spawn_persona import KernelJBPatchSpawnPersonaMixin
from .kernel_jb_patch_task_for_pid import KernelJBPatchTaskForPidMixin
from .kernel_jb_patch_load_dylinker import KernelJBPatchLoadDylinkerMixin
from .kernel_jb_patch_shared_region import KernelJBPatchSharedRegionMixin
from .kernel_jb_patch_nvram import KernelJBPatchNvramMixin
from .kernel_jb_patch_secure_root import KernelJBPatchSecureRootMixin
from .kernel_jb_patch_thid_crash import KernelJBPatchThidCrashMixin
from .kernel_jb_patch_cred_label import KernelJBPatchCredLabelMixin
from .kernel_jb_patch_syscallmask import KernelJBPatchSyscallmaskMixin
from .kernel_jb_patch_hook_cred_label import KernelJBPatchHookCredLabelMixin
from .kernel_jb_patch_kcall10 import KernelJBPatchKcall10Mixin


class KernelJBPatcher(
    KernelJBPatchKcall10Mixin,
    KernelJBPatchHookCredLabelMixin,
    KernelJBPatchSyscallmaskMixin,
    KernelJBPatchCredLabelMixin,
    KernelJBPatchThidCrashMixin,
    KernelJBPatchSecureRootMixin,
    KernelJBPatchNvramMixin,
    KernelJBPatchSharedRegionMixin,
    KernelJBPatchLoadDylinkerMixin,
    KernelJBPatchTaskForPidMixin,
    KernelJBPatchSpawnPersonaMixin,
    KernelJBPatchBsdInitAuthMixin,
    KernelJBPatchDounmountMixin,
    KernelJBPatchMacMountMixin,
    KernelJBPatchVmProtectMixin,
    KernelJBPatchVmFaultMixin,
    KernelJBPatchPortToMapMixin,
    KernelJBPatchProcPidinfoMixin,
    KernelJBPatchProcSecurityMixin,
    KernelJBPatchPostValidationMixin,
    KernelJBPatchSandboxExtendedMixin,
    KernelJBPatchTaskConversionMixin,
    KernelJBPatchAmfiExecveMixin,
    KernelJBPatchAmfiTrustcacheMixin,
    KernelJBPatcherBase,
):
    def find_all(self):
        self.patches = []

        # Group A: Existing patches
        self.patch_amfi_cdhash_in_trustcache()
        self.patch_amfi_execve_kill_path()
        self.patch_task_conversion_eval_internal()
        self.patch_sandbox_hooks_extended()

        # Group B: Simple patches (string-anchored / pattern-matched)
        self.patch_post_validation_additional()
        self.patch_proc_security_policy()
        self.patch_proc_pidinfo()
        self.patch_convert_port_to_map()
        self.patch_vm_fault_enter_prepare()
        self.patch_vm_map_protect()
        self.patch_mac_mount()
        self.patch_dounmount()
        self.patch_bsd_init_auth()
        self.patch_spawn_validate_persona()
        self.patch_task_for_pid()
        self.patch_load_dylinker()
        self.patch_shared_region_map()
        self.patch_nvram_verify_permission()
        self.patch_io_secure_bsd_root()
        self.patch_thid_should_crash()

        # Group C: Complex shellcode patches
        self.patch_cred_label_update_execve()
        self.patch_syscallmask_apply_to_proc()
        self.patch_hook_cred_label_update_execve()
        self.patch_kcall10()

        return self.patches

    def apply(self):
        patches = self.find_all()
        for off, patch_bytes, _ in patches:
            self.data[off : off + len(patch_bytes)] = patch_bytes
        return len(patches)

    # ══════════════════════════════════════════════════════════════
    # Group A: Existing patches (unchanged)
    # ══════════════════════════════════════════════════════════════
