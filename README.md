This is a bash script that interactively exports or imports VM:s from virt-manager.  
All exports are compressed as 7zip archives and encrypted with the specified password.  

All backups will be created in the directory where the script is located.  

It uses gum (https://github.com/charmbracelet/gum) for the menu. Gum will be installed in ~/.local/bin if it is not installed already.  
An entry in ~/.bashrc or ~/.profile to add ~/.local/bin to PATH will also be created.  

If you are using Fedora Silverblue, a Podman container will be created (Where 7zip and xmlstarlet will be installed).  

If the variable CONTAINER_NAME in the script is empty, no container will be used.  
In that case, you will probably need to install 7zip and xmlstarlet.  

For options, see the script itself.  

When using Silverblue, the SELinux polices for the VM paths gets destroyed a bit when running Podman with that path.  
After the container is done, the following is set:  
<code>chcon -u system_u -r object_r -t virt_image_t -l s0 $folder_path</code>
I'm guessing there are better ways to do this, but it is what it is for now.  

**This script probably won't make your PC explode, but please use with care.**  
Tested on Fedora Silverblue and Pop!_OS