# Berkeley SoftFloat and TestFloat, release 3e, from ucb-bar's mirrors.
#
# Builds testfloat_gen and testfloat_ver from the stock Linux-x86_64-GCC
# Makefiles. Those Makefiles are plain C and build on any Linux, aarch64
# included. SoftFloat is built with SPECIALIZE_TYPE=RISCV so NaN handling
# matches the RISC-V rules Harbor's FPU follows.
{
  lib,
  stdenv,
  fetchFromGitHub,
}:

let
  softfloatSrc = fetchFromGitHub {
    owner = "ucb-bar";
    repo = "berkeley-softfloat-3";
    rev = "a0c6494cdc11865811dec815d5c0049fba9d82a8";
    hash = "sha256-TO1DhvUMd2iP5gvY9Hqy9Oas0Da7lD0oRVPBlfAzc90=";
  };

  testfloatSrc = fetchFromGitHub {
    owner = "ucb-bar";
    repo = "berkeley-testfloat-3";
    rev = "a9c849f1b0eb0264b626d9686ffae167d996e3be";
    hash = "sha256-/rCTt+EAjQ/coi+pDpdZjCafS2cHNi9o7swIEeBNtDk=";
  };
in
stdenv.mkDerivation {
  pname = "testfloat";
  version = "3e";

  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    mkdir -p work
    cp -r ${softfloatSrc} work/berkeley-softfloat-3
    cp -r ${testfloatSrc} work/berkeley-testfloat-3
    chmod -R u+w work

    make -C work/berkeley-softfloat-3/build/Linux-x86_64-GCC SPECIALIZE_TYPE=RISCV
    make -C work/berkeley-testfloat-3/build/Linux-x86_64-GCC

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m755 work/berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_gen $out/bin/testfloat_gen
    install -D -m755 work/berkeley-testfloat-3/build/Linux-x86_64-GCC/testfloat_ver $out/bin/testfloat_ver
    runHook postInstall
  '';

  meta = {
    description = "Berkeley TestFloat IEEE 754 test vector generator and verifier";
    homepage = "https://github.com/ucb-bar/berkeley-testfloat-3";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
  };
}
