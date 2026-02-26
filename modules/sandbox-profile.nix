# modules/sandbox-profile.nix
#
# Pre-computes the Nix store closure for the gVisor sandbox profile at
# NixOS build time. This eliminates the need for agentd to run
# `nix-store -qR` at runtime to discover the closure.
#
# The closure manifest is installed to /etc/stereos/sandbox-closure.txt,
# which agentd reads as the fast path in pkg/sandbox/closure.go.
#
# The sandbox profile contains the same packages as the agent user's PATH
# (defined in agent.nix) plus any extra packages from mixtapes.

{ config, lib, pkgs, ... }:

let
  # Build the same package set as the agent user's PATH.
  # This mirrors the agentPackages list from agent.nix.
  agentPackages = with pkgs; [
    # Core POSIX utilities
    coreutils
    gnugrep
    gnused
    gawk
    findutils
    diffutils
    less
    which

    # Development essentials
    git
    curl
    jq
    ripgrep
    tree
    file
    unzip
    gnumake

    # Editors
    vim

    # Terminal multiplexer
    tmux

    # Process inspection
    htop
    procps

    # Networking
    openssh
    cacert

    # Shell (needed as the sandbox entrypoint)
    bash
  ];

  # Combine base packages with mixtape-specific extras.
  allPackages = agentPackages ++ config.stereos.agent.extraPackages;

  # Build a single environment from all packages.
  sandboxProfile = pkgs.buildEnv {
    name = "stereos-sandbox-profile";
    paths = allPackages;
    pathsToLink = [ "/bin" "/lib" "/share" "/etc" ];
  };

  # Use closureInfo to compute the full /nix/store closure at build time.
  # The store-paths file lists one store path per line.
  closureManifest = pkgs.closureInfo { rootPaths = [ sandboxProfile ]; };

in
{
  # Install the closure manifest to a well-known path that agentd reads.
  environment.etc."stereos/sandbox-closure.txt" = {
    source = "${closureManifest}/store-paths";
    mode = "0444";
  };
}
