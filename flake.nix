{
  description = "The purely functional package manager";

  inputs.make-package.url = "github:matthewbauer/make-package.nix";

  outputs = { self, make-package }: make-package.makePackagesFlake {} {
    nix = { stdenv, ... }: rec {
      pname = "nix";
      version = "2.4pre20200622_334e26b";

      outputs = [ "out" "dev" "man" "doc" ];

      depsBuildHost = [
        "pkgconfig"
        "autoreconfHook"
        "autoconf-archive"
        "bison"
        "flex"
        "libxml2"
        "libxslt"
        "docbook5"
        "docbook_xsl_ns"
        "jq"
      ];
      depsHostTarget = [
        "curl"
        "openssl"
        "sqlite"
        "xz"
        "bzip2"
        "nlohmann_json"
        "brotli"
        "boost"
        "editline"
        "libsodium"
        "libarchive"
        "gtest"
      ] ++ stdenv.lib.optional stdenv.hostPlatform.isLinux "libseccomp";
      depsHostTargetPropagated = [ "boehmgc" ];

      src = self;

      configureFlags = [
        "--with-store-dir=/nix/store"
        "--localstatedir=/nix/"
        "--sysconfdir=/etc"
        "--disable-init-state"
        "--enable-gc"
        "--with-system=${stdenv.hostPlatform.system}"
      ];

      makeFlags = [ "profiledir=${placeholder "out"}/etc/profile.d" ];

      installFlags = [ "sysconfdir=${placeholder "out"}/etc" ];
    };
  };
}
