# simplex-chat terminal CLI, from the official prebuilt Ubuntu release binary.
#
# nixpkgs carries no simplex-chat CLI (only the desktop GUI), and
# haskellPackages.simplexmq is a ~2021 release that predates the current SMP
# protocol, so the pinned release binary patched for the nix store is the
# only reproducible non-Docker option.
{ stdenv
, fetchurl
, autoPatchelfHook
, zlib
, gmp
, openssl
, libffi
, ncurses
}:

stdenv.mkDerivation rec {
  pname = "simplex-chat";
  version = "6.5.6";

  src = fetchurl {
    url = "https://github.com/simplex-chat/simplex-chat/releases/download/v${version}/simplex-chat-ubuntu-22_04-x86_64";
    sha256 = "0m0i8sww8blr7aa4q82lrbmvdaqvwib2scdjfp5cv6m32rk118za";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    zlib
    gmp
    openssl
    libffi
    ncurses
    stdenv.cc.cc.lib
  ];

  dontUnpack = true;
  dontStrip = true;

  installPhase = ''
    install -Dm755 $src $out/bin/simplex-chat
  '';
}
