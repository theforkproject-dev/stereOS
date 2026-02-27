# profiles/cloud.nix
#
# Cloud deployment profile for x86_64 KVM providers (Digital Ocean, etc.).
#
# Provides:
#   - BIOS/MBR boot (cloud providers like DO use SeaBIOS, not UEFI)
#   - MBR partition table on the disk image (replaces GPT+ESP from raw-efi.nix)
#   - Baked SSH deploy key for bootstrap access (no cloud-init needed)
#   - Serial console adjusted for x86_64 KVM (ttyS0 instead of ttyAMA0)
#   - Getty on ttyS0 for DO web console access
#
# The deploy key is read from ~/.config/stereos/deploy-key.pub at build
# time. If the file is missing, no keys are baked (build does not fail).
#
# Generate the key pair:
#   ssh-keygen -t ed25519 -f ~/.config/stereos/deploy-key -C "stereos-deploy"
#
# Usage:
#   Include this profile in mkMixtape's extraModules for cloud builds.
#   These builds should also set system = "x86_64-linux".
#
# REQUIRES --impure (uses builtins.getEnv for HOME).

{ config, lib, pkgs, modulesPath, ... }:

let
  deployKeyPath = builtins.getEnv "HOME" + "/.config/stereos/deploy-key.pub";
  deployKeys =
    let
      exists = builtins.pathExists deployKeyPath;
    in
      if exists then
        let raw = builtins.readFile deployKeyPath;
        in [ (lib.removeSuffix "\n" raw) ]
      else
        [];

  imageName = "stereos-${config.networking.hostName}";
in
{
  # -- SSH bootstrap key -----------------------------------------------------
  stereos.ssh.authorizedKeys = deployKeys;

  # -- BIOS/MBR boot --------------------------------------------------------
  # Cloud providers like Digital Ocean use SeaBIOS (BIOS), not UEFI.
  # Override the EFI-only GRUB config from boot.nix to install GRUB to the
  # MBR of /dev/vda (virtio block device).
  boot.loader.grub = {
    efiSupport = lib.mkForce false;
    efiInstallAsRemovable = lib.mkForce false;
    device = lib.mkForce "/dev/vda";
  };

  # -- MBR disk image --------------------------------------------------------
  # Override the EFI raw image from formats/raw-efi.nix with one that uses
  # an MBR partition table. SeaBIOS cannot boot from GPT+ESP.
  system.build.raw = lib.mkForce (
    import "${modulesPath}/../lib/make-disk-image.nix" {
      inherit lib config pkgs;

      name = imageName;
      baseName = "stereos";

      diskSize = "auto";
      additionalSpace = "1024M";
      format = "raw";

      # MBR partition table for BIOS boot
      partitionTableType = "legacy";

      copyChannel = false;
    }
  );

  # -- Serial console for x86_64 KVM ----------------------------------------
  # Cloud KVM hypervisors (DO, GCP, AWS) expose ttyS0 as the serial console,
  # not ttyAMA0 (ARM PL011 UART). Add ttyS0 so the DO web console and
  # `doctl compute ssh` serial access work correctly.
  #
  # boot.nix already sets: console=tty0 console=ttyAMA0,115200 console=hvc0
  # The kernel uses the *last* console= as /dev/console. On cloud x86_64,
  # ttyS0 is the right choice for /dev/console.
  boot.kernelParams = lib.mkAfter [ "console=ttyS0,115200" ];

  # -- Getty on serial console -----------------------------------------------
  # boot.nix disables all gettys for fast boot. Re-enable serial-getty on
  # ttyS0 so the DO web console provides a login prompt for debugging.
  systemd.services."serial-getty@ttyS0" = {
    enable = lib.mkForce true;
    wantedBy = [ "getty.target" ];
  };
}
