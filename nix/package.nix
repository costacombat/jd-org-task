{
  lib,
  stdenvNoCC,
  makeWrapper,
  emacs-nox,
  coreutils,
  emacs ? emacs-nox,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "ot";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../bin
      ../lisp
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  # Byte-compile ot.el; a warning fails the build
  buildPhase = ''
    runHook preBuild
    ${lib.getExe' emacs "emacs"} -Q --batch -L lisp \
      --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/ot.el
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/emacs/site-lisp
    cp lisp/ot.el lisp/ot.elc $out/share/emacs/site-lisp/
    cp bin/ot $out/bin/ot
    wrapProgram $out/bin/ot \
      --set-default OT_EMACS ${lib.getExe' emacs "emacs"} \
      --set-default OT_EMACSCLIENT ${lib.getExe' emacs "emacsclient"} \
      --set-default OT_LISP $out/share/emacs/site-lisp \
      --prefix PATH : ${lib.makeBinPath [ coreutils ]}
    runHook postInstall
  '';

  # `system.services.<name>.imports = [ pkgs.ot.services.default ];`
  passthru.services.default = {
    imports = [ (lib.modules.importApply ./service.nix { }) ];
    ot.package = finalAttrs.finalPackage;
  };

  meta = {
    description = "Org tasks from the shell, through a small Emacs";
    mainProgram = "ot";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.unix;
  };
})
