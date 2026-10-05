{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  makeWrapper,
  python3,
  cudaPackages_13_0,
}:

let
  version = "0.1.39";
  llamaCpp = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
  };
  python = python3.withPackages (ps: with ps; [
    jinja2
    numpy
    pillow
    psutil
    pyyaml
    regex
    requests
    tqdm
  ]);
in
stdenv.mkDerivation {
  pname = "strata";
  inherit version;

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-9jqmV+AbGKiOqW1DvKjqBLVXmJCI9o6WI85QoHj5vBI=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    makeWrapper
    cudaPackages_13_0.cuda_nvcc
  ];
  buildInputs = [ cudaPackages_13_0.cudatoolkit ];
  dontUseCmakeConfigure = true;

  configurePhase = ''
    runHook preConfigure
    cmake -G Ninja -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_COMPILER=${cudaPackages_13_0.cuda_nvcc}/bin/nvcc \
      -DCMAKE_CUDA_ARCHITECTURES=120 \
      -DCUDAToolkit_ROOT=${cudaPackages_13_0.cudatoolkit} \
      -DSTRATA_GGML_DIR=${llamaCpp} \
      -DSTRATA_ENABLE_CUDA=ON \
      -DSTRATA_BUILD_TESTS=OFF
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build build --target strata --parallel $NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/strata"
    install -Dm755 build/strata "$out/bin/strata"
    cp -R serve tools data "$out/share/strata/"
    makeWrapper ${python}/bin/python "$out/bin/strata-server" \
      --add-flags "$out/share/strata/serve/server.py"
    runHook postInstall
  '';

  meta = {
    description = "CUDA inference server for Qwen3.8-Flash-Next";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
}
