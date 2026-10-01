# Package Environment

The VM has no package manager by default. To install one:

1. In the menu bar, choose **Apps > Install Bootstrap…** and select the **roothide** layout (**rootless** is deprecated). This installs Irisin in the VM.
2. For the first installation, select all of the following packages in Irisin at once, press and hold the install button, and choose **Bootstrap Install**:

   - `apt`
   - `bash`
   - `uikittools`
   - `launchctl`
   - `openssh-server`

   Install them together in one pass. Several of these packages depend on one another, and `openssh-server` declares some dependencies circularly, so installing them one by one can fail partway.
3. After the first installation, install further packages normally.

If the first installation fails, do not repair it in place. Choose **Apps > Uninstall Bootstrap…**, then start again from step 1.

## Remove the Environment

Choose **Apps > Uninstall Bootstrap…**. The VM restarts after removal.

Hold Option while opening the **Apps** menu to see two more options:

- **Install Bootstrap from File…:** Installs from a local Irisin `.deb`.
- **Uninstall Bootstrap Without Restarting…:** Removes the environment without restarting the VM.
