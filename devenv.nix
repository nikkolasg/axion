{ pkgs, config, ... }:

let
  simplex-chat = pkgs.callPackage ./nix/simplex-chat.nix { };
  root = config.devenv.root;
in
{
  # Env vars used by every script and process in this demo.
  env = {
    DEMO_ROOT = root;
    RUN_DIR = "${root}/run";
    ZEBRA_RPC_URL = "http://127.0.0.1:18232";
    # NOTE: no ZAINO_* variables here — zainod treats every ZAINO_-prefixed
    # env var as a config override and rejects unknown keys.
    # zaino's build uses bindgen, which must find nix's libclang rather than
    # whatever the host system provides.
    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
  };

  packages = [
    simplex-chat
    pkgs.jq
    pkgs.curl
    pkgs.sqlite
    pkgs.protobuf
    pkgs.pkg-config
    pkgs.openssl
    pkgs.grpcurl
    pkgs.clang
    pkgs.qrencode
  ];

  languages.rust.enable = true;
  languages.rust.channel = "stable";

  # Background infrastructure: `devenv up` starts the whole stack.
  processes = {
    zebrad = {
      exec = "bash ${root}/scripts/run-zebrad.sh";
      process-compose = {
        # demo-setup kills the container to swap in Bob's miner address;
        # process-compose must bring it straight back up.
        availability.restart = "always";
        readiness_probe = {
          exec.command = ''curl -sf -H "content-type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo","params":[]}' http://127.0.0.1:18232'';
          initial_delay_seconds = 3;
          period_seconds = 2;
          failure_threshold = 60;
        };
      };
    };

    zainod = {
      exec = "bash ${root}/scripts/run-zainod.sh";
      process-compose = {
        availability.restart = "always";
        depends_on.zebrad.condition = "process_healthy";
      };
    };

    smp-server.exec = "bash ${root}/scripts/run-smp.sh";

    # restart=always lets demo-reset-pairing kill the CLIs after wiping
    # their databases; process-compose brings them back with fresh profiles.
    simplex-alice = {
      exec = "bash ${root}/scripts/run-simplex.sh alice 5226";
      process-compose = {
        availability.restart = "always";
        depends_on.smp-server.condition = "process_started";
      };
    };

    simplex-bob = {
      exec = "bash ${root}/scripts/run-simplex.sh bob 5227";
      process-compose = {
        availability.restart = "always";
        depends_on.smp-server.condition = "process_started";
      };
    };

    # Second sender, for the two-senders unlinkability scene.
    simplex-carol = {
      exec = "bash ${root}/scripts/run-simplex.sh carol 5228";
      process-compose = {
        availability.restart = "always";
        depends_on.smp-server.condition = "process_started";
      };
    };
  };

  scripts = {
    # Factory reset: stop the stack and wipe all demo state under run/.
    demo-reset.exec = "bash ${root}/scripts/demo-reset.sh";
    demo-setup.exec = "bash ${root}/scripts/demo-setup.sh";
    demo-noise.exec = "bash ${root}/scripts/demo-noise.sh";
    demo-pay.exec = "bash ${root}/scripts/demo-pay.sh";
    demo-race.exec = "bash ${root}/scripts/demo-race.sh";
    # Video-friendly single-window pieces (one actor per window):
    demo-watch-oob.exec = "bash ${root}/scripts/watch-oob.sh";
    demo-watch-scan.exec = "bash ${root}/scripts/watch-scan.sh";
    demo-pair-alice.exec = "bash ${root}/scripts/pair-alice.sh";
    demo-pair-bob.exec = "bash ${root}/scripts/pair-bob.sh";
    demo-reset-pairing.exec = "bash ${root}/scripts/reset-pairing.sh";
    # No recovery scene: seed-only recovery is disabled until the Step 3
    # encrypted backup exists (the wallet gates it behind `unstable-recovery`).
    demo-unlinkability.exec = "bash ${root}/scripts/demo-unlinkability.sh";
    demo-scaling.exec = "bash ${root}/scripts/demo-scaling.sh";
  };
}
