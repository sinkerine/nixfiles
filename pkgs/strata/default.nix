{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  makeWrapper,
  python3,
  cudaPackages_13_0,
}:

let
  version = "0.2.18";
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
cudaPackages_13_0.backendStdenv.mkDerivation {
  pname = "strata";
  inherit version;

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "v${version}";
    hash = "sha256-CR1oBVBBk3cOTqYiwIRhMNZeU+asIVvRHoWnbw8ZiRM=";
  };

  patches = [ ./optional-nextn-predict-layers.patch ];

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
    cmake -G Ninja -S engine -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_COMPILER=${cudaPackages_13_0.cuda_nvcc}/bin/nvcc \
      -DCMAKE_CUDA_ARCHITECTURES=120 \
      -DCUDAToolkit_ROOT=${cudaPackages_13_0.cudatoolkit} \
      -DSTRATA_ENABLE_CUDA=ON \
      -DSTRATA_PORTABLE=ON \
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
    mkdir -p "$out/bin" "$out/share/strata" "$out/share/strata/third_party"
    install -Dm755 build/strata "$out/bin/strata"
    cp -R terminal/serve terminal/tools terminal/data terminal/strata_control "$out/share/strata/"
    cp -R engine/third_party/strata-gguf-py "$out/share/strata/third_party/"
    makeWrapper ${python}/bin/python "$out/bin/strata-server" \
      --set PYTHONPATH "$out/share/strata" \
      --set STRATA_GGUF_PY "$out/share/strata/third_party/strata-gguf-py" \
      --add-flags "$out/share/strata/serve/server.py"
    makeWrapper ${python}/bin/python "$out/bin/strata-tokenizer" \
      --set PYTHONPATH "$out/share/strata" \
      --set STRATA_GGUF_PY "$out/share/strata/third_party/strata-gguf-py" \
      --add-flags "$out/share/strata/tools/strata_tokenizer.py"
    runHook postInstall
  '';

  meta = {
    description = "CUDA inference server for Qwen3.8-Flash-Next and Qwen3.6-35B-A3B";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata-server";
  };
}
