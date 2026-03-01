{
  inputs = {
    xnode-builders.url = "github:Openmesh-Network/xnode-builders";
  };

  outputs =
    inputs:
    inputs.xnode-builders.language.auto {
      src = ./.;
      extraRequirements = [ "requirements.txt" ];
    };
}
