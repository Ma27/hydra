import <nixpkgs/nixos/tests/make-test-python.nix> ({ pkgs, lib, ... }: let
  base = { pkgs, lib, config, ... }: {
    virtualisation.memorySize = 4096;
    imports = [ ./hydra-module.nix ];
    environment.systemPackages = [ pkgs.jq ];
    nix = {
      distributedBuilds = true;
      buildMachines = [{
        hostName = "localhost";
        systems = [ builtins.currentSystem ];
      }];
      binaryCaches = [];
    };
    services.hydra-dev = {
      enable = true;
      hydraURL = "example.com";
      notificationSender = "webmaster@example.com";
    };
  };
in {
  nodes = {
    original = { pkgs, lib, config, ... }: {
      imports = [ base ];
      services.hydra-dev.package = pkgs.hydra-unstable.overrideAttrs (old: rec {
        inherit (old) pname;
        src = pkgs.fetchFromGitHub {
          owner = "NixOS";
          repo = pname;
          rev = "bde8d81876dfc02143e5070e42c78d8f0d83d6f7";
          sha256 = "sha256-iurWIKPEza5ICsZOLVE1w6MoCohOqFifnedw/MafyI4=";
        };
      });
    };
    new = { pkgs, lib, config, ... }: {
      imports = [ base ];
      services.hydra-dev.package = (import ./.).defaultPackage.x86_64-linux;
    };
  };

  testScript = { nodes, ... }:
    let
      new = nodes.new.config.system.build.toplevel;

      username = "admin";
      password = "admin";
      project = "Test";
      jobset = "Test";

      credentials = pkgs.writeText "credentials.json" (builtins.toJSON {
        inherit username password;
      });

      proj_payload = pkgs.writeText "project.json" (builtins.toJSON {
        displayname = project;
        enabled = toString 1;
        visible = toString 1;
      });

      testexpr = pkgs.writeTextDir "test.nix" ''
        {
          ${lib.flip lib.concatMapStrings [ "demo1" "demo2" "demo3" "demo4" "demo5" ] (name: ''
            ${name} = let
              builder = builtins.toFile "builder.sh" '''
                echo ${name} > $out
              ''';
            in builtins.derivation {
              name = "drv-${name}";
              system = "${builtins.currentSystem}";
              builder = "/bin/sh";
              args = [ builder ];
              allowSubstitutes = false;
              preferLocalBuild = true;
              meta.maintainers = [
                { github = "Ma27"; email = "ma27@localhost"; }
              ];
              meta.outPath = placeholder "out";
            };
          '')}
        }
      '';

      jobset_payload = pkgs.writeText "jobset.json" (builtins.toJSON {
        description = jobset;
        checkinterval = toString 60;
        enabled = toString 1;
        visible = toString 1;
        keepnr = toString 1;
        enableemail = true;
        emailoverride = "hydra@localhost";
        nixexprinput = "test";
        nixexprpath = "test.nix";
        inputs.test = {
          value = "${testexpr}";
          type = "path";
        };
      });

      setupJobset = pkgs.writeShellScript "setup.sh" ''
        set -euxo pipefail

        echo >&2 "Creating user from $(<${credentials})..."
        curl >&2 --fail -X POST -d '@${credentials}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/login \
          -c /tmp/cookie.txt

        echo >&2 "\nCreating project from $(<${proj_payload})..."
        curl >&2 --fail -X PUT -d '@${proj_payload}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/project/${project} \
          -b /tmp/cookie.txt

        echo >&2 "\nCreating jobset from $(<${jobset_payload})..."
        curl >&2 --fail -X PUT -d '@${jobset_payload}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/jobset/${project}/${jobset} \
          -b /tmp/cookie.txt
      '';
    in ''
      original.start()

      # Setup
      original.wait_for_unit("multi-user.target")
      original.wait_for_unit("postgresql.service")
      original.wait_for_unit("hydra-init.service")

      original.wait_for_unit("hydra-queue-runner.service")
      original.wait_for_unit("hydra-evaluator.service")
      original.wait_for_unit("hydra-server.service")
      original.wait_for_open_port(3000)

      # Create demo data
      original.succeed("hydra-create-user ${username} --role admin --password ${password}")
      original.succeed("${setupJobset}")

      # Wait for builds to succeed
      for i in range(1, 6):
          original.wait_until_succeeds(
              f"curl -L -s http://localhost:3000/build/{i} -H 'Accept: application/json' "
              + "|  jq .buildstatus | xargs test 0 -eq"
          )

      # Confirm that email from maintainers exist
      maintainers_old = original.succeed(
          "su -l postgres -c 'psql -d hydra <<< \"select maintainers from builds limit 5;\"'"
      ).split("\n")[2:7]

      for row in maintainers_old:
          row_ = row.strip()
          assert (
              row_ == "ma27@localhost"
          ), f"Expected a single email to be present in `builds` table (got '{row_}')!"

      # Perform migration
      original.succeed(
          "${new}/bin/switch-to-configuration test >&2"
      )

      original.wait_for_unit("hydra-init.service")
      out = original.succeed("hydra-update-maintainers 2>&1")
      assert out.find("Migration seems to be done already") == -1

      # Check if new structure for maintainers works
      original.wait_for_open_port(3000)


      def check_table_len(table, expected):
          n = (
              original.succeed(
                  f"su -l postgres -c 'psql -d hydra <<< \"select count(*) from {table};\"'"
              )
              .split("\n")[2]
              .strip()
          )
          assert n == str(expected), f"Expected one entry in {table}, but got {n}!"


      check_table_len("maintainers", 1)
      check_table_len("buildsbymaintainers", 5)

      email = original.succeed(
          "curl -L http://localhost:3000/build/1 -H 'Accept: application/json' | jq '.maintainers.\"\".email' | xargs echo"
      ).strip()

      assert email == "ma27@localhost"

      # Check if rerun doesn't do anything
      out = original.succeed("hydra-update-maintainers 2>&1")
      assert out.find("Migration seems to be done already") != -1

      # Finish
      original.shutdown()
    '';
})
