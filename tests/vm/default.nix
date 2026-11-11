{ pkgs, lib, mkModule }:
let
  mkAppBuilder =
    name:
    { pkgs, ... }:
    {
      package = pkgs.writeShellScriptBin name ''
        echo started > "$STATE_DIRECTORY/marker"
        exec ${pkgs.coreutils}/bin/sleep infinity
      '';
      devShell = pkgs.mkShell { };
      formatter = pkgs.writeShellScriptBin "${name}-formatter" "true";
      check = null;
      cacheDirectory = true;
    };

  systemApp = {
    name = "xnode-vm-test";
    version = "1.0.0";
    getArgs = _: { };
    module = { };
  };

  userApp = {
    name = "xnode-vm-user-test";
    version = "1.0.0";
    getArgs = _: { };
    module = {
      userService = true;
    };
  };
in
{
  system = pkgs.testers.runNixOSTest {
    name = "xnode-builders-module-system";

    nodes.machine =
      { config, utils, pkgs, ... }:
      {
        imports = [
          (mkModule {
            app = systemApp;
            appBuilder = mkAppBuilder systemApp.name;
          })
        ];

        services.xnode-vm-test.enable = true;
      };

    testScript = ''
      machine.wait_for_unit("xnode-vm-test.service")
      machine.wait_for_file("/var/lib/xnode-vm-test/marker")
      machine.succeed("getent passwd xnode-vm-test")
      machine.succeed("systemctl show -p NoNewPrivileges --value xnode-vm-test.service | grep -qx yes")
      machine.succeed("systemctl show -p CacheDirectory --value xnode-vm-test.service | grep -qx xnode-vm-test")
      machine.succeed("test -d /var/cache/xnode-vm-test")
    '';
  };

  user = pkgs.testers.runNixOSTest {
    name = "xnode-builders-module-user";

    nodes.machine =
      { config, utils, pkgs, ... }:
      {
        imports = [
          (mkModule {
            app = userApp;
            appBuilder = mkAppBuilder userApp.name;
          })
        ];

        services.xnode-vm-user-test.enable = true;

        # A user service needs a user with a running user manager. Lingering
        # starts it at boot, without a login session.
        users.users.testuser = {
          isNormalUser = true;
          uid = 1000;
          createHome = true;
          linger = true;
        };
      };

    testScript = ''
      # The user manager needs to be running before `systemctl --user` can be
      # used. Lingering starts it at boot.
      machine.wait_for_unit("user@1000.service")
      machine.wait_for_unit("xnode-vm-user-test.service", "testuser")
      machine.wait_for_file("/home/testuser/.local/state/xnode-vm-user-test/marker")
      machine.succeed("test -d /home/testuser/.cache/xnode-vm-user-test")
      assert machine.get_unit_property("xnode-vm-user-test.service", "NoNewPrivileges", "testuser") == "yes"
    '';
  };
}
