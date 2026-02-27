# flake/images.nix
#
# Per-architecture image build targets.
#
# Generates packages from nixosConfigurations for each target architecture.
# Each nixosConfiguration carries its target system; this module groups
# configs by architecture and generates the full set of image packages
# for each.
#
# Packages per architecture:
#   packages.<system>.<mixtape-name>                    (raw)
#   packages.<system>.<mixtape-name>-qcow2              (qcow2)
#   packages.<system>.<mixtape-name>-kernel-artifacts   (direct-kernel boot)
#   packages.<system>.<mixtape-name>-dist               (all formats + mixtape.toml)
#
# Build with:
#   nix build .#packages.aarch64-linux.opencode-mixtape --impure
#   nix build .#packages.aarch64-linux.opencode-mixtape-qcow2 --impure
#   nix build .#packages.x86_64-linux.opencode-mixtape-cloud --impure
#   nix build .#packages.x86_64-linux.opencode-mixtape-cloud-qcow2 --impure

{ self, inputs, ... }:

let
  stereos-lib = import ../lib/dist.nix { inherit inputs; };

  # Target architectures for image builds.
  imageArchs = [ "aarch64-linux" "x86_64-linux" ];

  # Build the package set for a single architecture from matching
  # nixosConfigurations.  A configuration matches an architecture when
  # its pkgs.system equals that architecture.
  mkImagePackages = system:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      allConfigs = self.nixosConfigurations;

      # Filter to only configs built for this architecture.
      configsForArch = inputs.nixpkgs.lib.filterAttrs
        (_name: cfg: cfg.config.nixpkgs.system == system)
        allConfigs;

      mixtapeNames = builtins.attrNames configsForArch;

      # Raw images — canonical artifact
      rawPkgs = builtins.mapAttrs
        (_name: cfg: cfg.config.system.build.raw)
        configsForArch;

      # QCOW2 images — derived from raw, for QEMU/KVM
      qcow2Pkgs = builtins.mapAttrs
        (_name: cfg: cfg.config.system.build.qcow2)
        configsForArch;
      qcow2Named = builtins.listToAttrs (
        builtins.map (name: {
          name = "${name}-qcow2";
          value = qcow2Pkgs.${name};
        }) mixtapeNames
      );

      # Kernel artifacts (bzImage + initrd + cmdline) for direct-kernel boot.
      kernelArtifactPkgs = builtins.mapAttrs
        (_name: cfg: cfg.config.system.build.kernelArtifacts)
        configsForArch;
      kernelArtifactsNamed = builtins.listToAttrs (
        builtins.map (name: {
          name = "${name}-kernel-artifacts";
          value = kernelArtifactPkgs.${name};
        }) mixtapeNames
      );

      # Dist directories — all formats assembled into a single output.
      distPkgs = builtins.listToAttrs (
        builtins.map (name: {
          name = "${name}-dist";
          value = stereos-lib.mkDist {
            inherit pkgs system;
            name   = name;
            raw    = rawPkgs.${name};
            qcow2  = qcow2Pkgs.${name};
            kernel = kernelArtifactPkgs.${name};
          };
        }) mixtapeNames
      );
    in
      rawPkgs // qcow2Named // kernelArtifactsNamed // distPkgs;
in
{
  # Image packages are not per-system in the flake-parts sense — they target
  # specific Linux architectures regardless of the build host.  We expose
  # them via the top-level `flake` attrset.
  flake = {
    packages = builtins.listToAttrs (
      builtins.map (system: {
        name = system;
        value = mkImagePackages system;
      }) imageArchs
    );
  };
}
