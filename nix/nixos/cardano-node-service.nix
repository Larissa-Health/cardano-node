{ config
, lib
, pkgs
, ... }:

with lib; with builtins;
let
  cfg = config.services.cardano-node;
  envConfig = cfg.environments.${cfg.environment};
  runtimeDir = i : if cfg.runtimeDir i == null then cfg.stateDir i else "${cfg.runDirBase}${lib.removePrefix cfg.runDirBase (cfg.runtimeDir i)}";
  suffixDir = base: i: "${base}${optionalString (i != 0) "-${toString i}"}";
  nullOrStr = types.nullOr types.str;
  funcToOr = t: types.either t (types.functionTo t);

  newTopology = i: {
    localRoots = map (g: {
      accessPoints = map (e: builtins.removeAttrs e ["valency"]) g.accessPoints;
      advertise = g.advertise or false;
      valency = g.valency or (length g.accessPoints);
      trustable = g.trustable or false;
    }) (cfg.producers ++ (cfg.instanceProducers i));
    publicRoots = map (g: {
      accessPoints = map (e: builtins.removeAttrs e ["valency"]) g.accessPoints;
      advertise = g.advertise or false;
    }) (cfg.publicProducers ++ (cfg.instancePublicProducers i));
    bootstrapPeers = cfg.bootstrapPeers;
  } // optionalAttrs (cfg.usePeersFromLedgerAfterSlot != null) {
    useLedgerAfterSlot = cfg.usePeersFromLedgerAfterSlot;
  } // optionalAttrs (cfg.peerSnapshotFile i != null) {
    peerSnapshotFile = cfg.peerSnapshotFile i;
  };

  oldTopology = i: {
    Producers = concatMap (g: map (a: {
        addr = a.address;
        inherit (a) port;
        valency = a.valency or 1;
      }) g.accessPoints) (
      cfg.producers ++ (cfg.instanceProducers i) ++ cfg.publicProducers ++ (cfg.instancePublicProducers i)
    );
  };

  assertNewTopology = i:
    let
      checkEval = tryEval (
        assert
          if cfg.bootstrapPeers == [] && all (e: e.trustable != true) ((newTopology i).localRoots)
          then false
          else true;
      newTopology i);
    in
      if checkEval.success
      then checkEval.value
      else abort "When bootstrapPeers is an empty list, at least one localRoot must be trustable, otherwise cardano node will fail to start.";

  selectTopology = i:
    if cfg.topology != null
    then cfg.topology
    else toFile "topology.yaml" (toJSON (if (cfg.useNewTopology) then assertNewTopology i else oldTopology i));

  topology = i:
    if cfg.useSystemdReload
    then "/etc/cardano-node/topology-${toString i}.yaml"
    else selectTopology i;

  mkScript = cfg:
    let baseConfig =
          recursiveUpdate
            (cfg.nodeConfig
             // (mapAttrs' (era: epoch:
               nameValuePair "Test${era}HardForkAtEpoch" epoch
             ) cfg.forceHardForks)
            // (optionalAttrs cfg.useNewTopology {
              EnableP2P = true;
              TargetNumberOfRootPeers = cfg.targetNumberOfRootPeers;
              TargetNumberOfKnownPeers = cfg.targetNumberOfKnownPeers;
              TargetNumberOfEstablishedPeers = cfg.targetNumberOfEstablishedPeers;
              TargetNumberOfActivePeers = cfg.targetNumberOfActivePeers;
              MaxConcurrencyBulkSync = 2;
            })) cfg.extraNodeConfig;
        baseInstanceConfig =
          i:
          ( if !cfg.useLegacyTracing
            then baseConfig //
                 { ## XXX: remove once legacy tracing is dropped
                   minSeverity = "Critical";
                   setupScribes = [];
                   setupBackends = [];
                   defaultScribes = [];
                   defaultBackends = [];
                   options = {};
                 }
            else baseConfig //
                 {
                   UseTraceDispatcher = false;
                 } //
                 (optionalAttrs (baseConfig ? hasEKG) {
                    hasEKG = baseConfig.hasEKG + i;
                 }) //
                 (optionalAttrs (baseConfig ? hasPrometheus) {
                   hasPrometheus = map (n: if isInt n then n + i else n) baseConfig.hasPrometheus;
                 })
            )
            // optionalAttrs (cfg.withUtxoHdLmdb i){
              LedgerDB = {
                Backend = "V1LMDB";
                LiveTablesPath = cfg.lmdbDatabasePath i;
              };
            };
    in i: let
    instanceConfig = recursiveUpdate (baseInstanceConfig i) (cfg.extraNodeInstanceConfig i);
    nodeConfigFile = if (cfg.nodeConfigFile != null) then cfg.nodeConfigFile
      else toFile "config-${toString cfg.nodeId}-${toString i}.json" (toJSON instanceConfig);
    consensusParams = {
      RealPBFT = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
      ];
      TPraos = [
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
      Cardano = [
        "${lib.optionalString (cfg.signingKey != null)
          "--signing-key ${cfg.signingKey}"}"
        "${lib.optionalString (cfg.delegationCertificate != null)
          "--delegation-certificate ${cfg.delegationCertificate}"}"
        "${lib.optionalString (cfg.vrfKey != null)
          "--shelley-vrf-key ${cfg.vrfKey}"}"
        "${lib.optionalString (cfg.kesKey != null)
          "--shelley-kes-key ${cfg.kesKey}"}"
        "${lib.optionalString (cfg.operationalCertificate != null)
          "--shelley-operational-certificate ${cfg.operationalCertificate}"}"
      ];
    };
    instanceDbPath = cfg.databasePath i;
    cmd = builtins.filter (x: x != "") [
      "${cfg.executable} run"
      "--config ${nodeConfigFile}"
      "--database-path ${instanceDbPath}"
      "--topology ${topology i}"
    ] ++ lib.optionals (!cfg.systemdSocketActivation) ([
      "--host-addr ${cfg.hostAddr}"
      "--port ${if (cfg.shareIpv4port || cfg.shareIpv6port) then toString cfg.port else toString (cfg.port + i)}"
      "--socket-path ${cfg.socketPath i}"
    ] ++ lib.optionals (cfg.ipv6HostAddr i != null) [
      "--host-ipv6-addr ${cfg.ipv6HostAddr i}"
    ]) ++ lib.optionals (cfg.tracerSocketPathAccept i != null) [
      "--tracer-socket-path-accept ${cfg.tracerSocketPathAccept i}"
    ] ++ lib.optionals (cfg.tracerSocketPathConnect i != null) [
      "--tracer-socket-path-connect ${cfg.tracerSocketPathConnect i}"
    ] ++ consensusParams.${cfg.nodeConfig.Protocol} ++ cfg.extraArgs ++ cfg.rtsArgs;
    in ''
      echo "Starting: ${concatStringsSep "\"\n   echo \"" cmd}"
      echo "..or, once again, in a single line:"
      echo "${toString cmd}"
      ${lib.optionalString (i > 0) ''
      # If exist copy state from existing instance instead of syncing from scratch:
      if [ ! -d ${instanceDbPath} ] && [ -d ${cfg.databasePath 0} ]; then
        echo "Copying existing immutable db from ${cfg.databasePath 0}"
        ${pkgs.rsync}/bin/rsync --archive --ignore-errors --exclude 'clean' ${cfg.databasePath 0}/ ${instanceDbPath}/ || true
      fi
      ''}
      ${toString cmd}'';
in {
  options = {
    services.cardano-node = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable cardano-node, a node implementing ouroboros protocols
          (the blockchain protocols running cardano).
        '';
      };

      instances = mkOption {
        type = types.int;
        default = 1;
        description = ''
          Number of instance of the service to run.
        '';
      };

      script = mkOption {
        type = types.str;
        default = mkScript cfg 0;
      };

      profiling = mkOption {
        type = types.enum ["none" "time" "time-detail" "space" "space-cost" "space-module" "space-closure" "space-type" "space-retainer" "space-bio" "space-heap"];
        default = "none";
      };

      eventlog = mkOption {
        type = types.bool;
        default = false;
      };

      asserts = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use an executable with asserts enabled.
        '';
      };

      cardanoNodePackages = mkOption {
        type = types.attrs;
        default = pkgs.cardanoNodePackages or (import ../. { inherit (pkgs) system; }).cardanoNodePackages;
        defaultText = "cardano-node packages";
        description = ''
          The cardano-node packages and library that should be used.
          Main usage is sharing optimization:
          reduce eval time when service is instantiated multiple times.
        '';
      };

      package = mkOption {
        type = types.package;
        default = if (cfg.profiling != "none")
          then cfg.cardanoNodePackages.cardano-node.passthru.profiled
          else if cfg.asserts then cfg.cardanoNodePackages.cardano-node.passthru.asserted
          else cfg.cardanoNodePackages.cardano-node;
        defaultText = "cardano-node";
        description = ''
          The cardano-node package that should be used
        '';
      };

      executable = mkOption {
        type = types.str;
        default = "exec ${cfg.package}/bin/cardano-node";
        defaultText = "cardano-node";
        description = ''
          The cardano-node executable invocation to use
        '';
      };

      environments = mkOption {
        type = types.attrs;
        default = cfg.cardanoNodePackages.cardanoLib.environments;
        description = ''
          environment node will connect to
        '';
      };

      environment = mkOption {
        type = types.enum (builtins.attrNames cfg.environments);
        default = "testnet";
        description = ''
          environment node will connect to
        '';
      };

      isProducer = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this node is intended to be a producer.
          Internal option for inter-module communication.
        '';
      };

      # Byron signing/delegation

      signingKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      delegationCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Delegation certificate
        '';
      };

      # Shelley kes/vrf keys and operation cert

      kesKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };
      vrfKey = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Signing key
        '';
      };

      operationalCertificate = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Operational certificate
        '';
      };

      hostAddr = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          The host address to bind to
        '';
      };

      ipv6HostAddr = mkOption {
        type = funcToOr nullOrStr;
        default = _: null;
        apply = ip: if (lib.isFunction ip) then ip else _: ip;
        description = ''
          The ipv6 host address to bind to. Set to null to disable.
        '';
      };

      additionalListenStream = mkOption {
        type = types.functionTo (types.listOf types.str);
        default = _: [];
        description = ''
          List of additional sockets to listen to. Only available with `systemdSocketActivation`.
        '';
      };

      stateDirBase = mkOption {
        type = types.str;
        default = "/var/lib/";
        description = ''
          Base directory to store blockchain data, for each instance.
        '';
      };

      stateDir = mkOption {
        type = funcToOr types.str;
        default = "${cfg.stateDirBase}cardano-node";
        apply = x : if (lib.isFunction x) then x else i: x;
        description = ''
          Directory to store blockchain data, for each instance.
        '';
      };

      runDirBase = mkOption {
        type = types.str;
        default = "/run/";
        description = ''
          Base runtime directory, for each instance.
        '';
      };

      runtimeDir = mkOption {
        type = funcToOr nullOrStr;
        default = i: ''${cfg.runDirBase}${suffixDir "cardano-node" i}'';
        apply = x : if lib.isFunction x then x else if x == null then _: null else "${cfg.runDirBase}${suffixDir "cardano-node" x}";
        description = ''
          Runtime directory relative to ${cfg.runDirBase}, for each instance
        '';
      };

      databasePath = mkOption {
        type = funcToOr types.str;
        default = i : "${cfg.stateDir i}/${cfg.dbPrefix i}";
        apply = x : if lib.isFunction x then x else _ : x;
        description = ''Node database path, for each instance.'';
      };

      lmdbDatabasePath = mkOption {
        type = funcToOr nullOrStr;
        default = null;
        apply = x : if lib.isFunction x then x else if x == null then _: null else _: x;
        description = ''
          Node UTxO-HD LMDB path for performant disk I/O, for each instance.
          This could point to a direct-access SSD, with a specifically created journal-less file system and optimized mount options.
        '';
      };

      socketPath = mkOption {
        type = funcToOr types.str;
        default = i : "${runtimeDir i}/node.socket";
        apply = x : if lib.isFunction x then x else _ : x;
        description = ''Local communication socket path, for each instance.'';
      };

      tracerSocketPathAccept = mkOption {
        type = funcToOr nullOrStr;
        default = null;
        apply = x : if lib.isFunction x then x else _ : x;
        description = ''
          Listen for incoming cardano-tracer connection on a local socket,
          for each instance.
        '';
      };

      tracerSocketPathConnect = mkOption {
        type = funcToOr nullOrStr;
        default = null;
        apply = x : if lib.isFunction x then x else _ : x;
        description = ''
          Connect to cardano-tracer listening on a local socket,
          for each instance.
        '';
      };

      socketGroup = mkOption {
        type = types.str;
        default = "cardano-node";
        description = ''
          systemd socket group owner.
          Note: only applies to sockets created by systemd
          (ie. when `systemdSocketActivation` is turned on).
        '';
      };

      systemdSocketActivation = mkOption {
        type = types.bool;
        default = false;
        description = ''Use systemd socket activation'';
      };

      extraServiceConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''
          Extra systemd service config (apply to all instances).
        '';
      };

      extraSocketConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''
          Extra systemd socket config (apply to all instances).
        '';
      };

      dbPrefix = mkOption {
        type = types.either types.str (types.functionTo types.str);
        default = suffixDir "db-${cfg.environment}";
        apply = x : if lib.isFunction x then x else suffixDir x;
        description = ''
          Prefix of database directories inside `stateDir`.
          (eg. for "db", there will be db-0, etc.).
        '';
      };

      port = mkOption {
        type = types.either types.int types.str;
        default = 3001;
        description = ''
          The port number
        '';
      };

      shareIpv4port = mkOption {
        type = types.bool;
        default = cfg.systemdSocketActivation;
        description = ''
          Should instances on same machine share ipv4 port.
          Default: true if systemd activated socket. Otherwise false.
          If false use port increments starting from `port`.
        '';
      };

      shareIpv6port = mkOption {
        type = types.bool;
        default = cfg.systemdSocketActivation;
        description = ''
          Should instances on same machine share ipv6 port.
          Default: true if systemd activated socket. Otherwise false.
          If false use port increments starting from `port`.
        '';
      };

      nodeId = mkOption {
        type = types.int;
        default = 0;
        description = ''
          The ID for this node
        '';
      };

      publicProducers = mkOption {
        type = types.listOf types.attrs;
        default = [];
        example = [{
          accessPoints = [{
            address = envConfig.relaysNew;
            port = envConfig.edgePort;
          }];
          advertise = false;
        }];
        description = ''Routes to public peers. Only used if slot < usePeersFromLedgerAfterSlot'';
      };

      instancePublicProducers = mkOption {
        type = types.functionTo (types.listOf types.attrs);
        default = _: [];
        description = ''Routes to public peers. Only used if slot < usePeersFromLedgerAfterSlot and specific to a given instance (when multiple instances are used).'';
      };

      producers = mkOption {
        type = types.listOf types.attrs;
        default = [];
        example = [{
          accessPoints = [{
            address = "127.0.0.1";
            port = 3001;
          }];
          advertise = false;
          valency = 1;
        }];
        description = ''Static routes to local peers.'';
      };

      instanceProducers = mkOption {
        type = types.functionTo (types.listOf types.attrs);
        default = _: [];
        description = ''
          Static routes to local peers, specific to a given instance (when multiple instances are used).
        '';
      };

      useNewTopology = mkOption {
        type = types.bool;
        default = cfg.nodeConfig.EnableP2P or false;
        description = ''
          Use new, p2p/ledger peers compatible topology.
        '';
      };

      useLegacyTracing = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Use the legacy tracing, based on iohk-monitoring-framework.
        '';
      };

      usePeersFromLedgerAfterSlot = mkOption {
        type = types.nullOr types.int;
        default = if cfg.kesKey != null then null
          else envConfig.usePeersFromLedgerAfterSlot or null;
        description = ''
          If set, bootstraps from public roots until it reaches given slot,
          then it switches to using the ledger as a source of peers. It maintains a connection to its local roots.
          Default to null for block producers.
        '';
      };

      bootstrapPeers = mkOption {
        type = types.nullOr (types.listOf types.attrs);
        default = map (e: {address = e.addr; inherit (e) port;}) envConfig.edgeNodes;
        description = ''
          If set, it will enable bootstrap peers.
          To disable, set this to null.
          To enable, set this to a list of attributes of address and port, example: [{ address = "addr"; port = 3001; }]
        '';
      };

      topology = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        description = ''
          Cluster topology. If not set `producers` array is used to generated topology file.
        '';
      };

      useSystemdReload = mkOption {
        type = types.bool;
        default = false;
        description = ''
          If set, systemd will reload cardano-node service units instead of restarting them
          if only the topology file has changed and p2p is in use.

          Cardano-node topology files will be stored in /etc as:
            /etc/cardano-node/topology-''${toString i}.yaml

          For peerSharing enabled networks, peer sharing files will be stored in /etc as:
            /etc/cardano-node/peer-sharing-''${toString i}.json

          Enabling this option will also allow direct topology edits for tests when a full
          service re-deployment is not desired.
        '';
      };

      nodeConfig = mkOption {
        type = types.attrs // {
          merge = loc: foldl' (res: def: recursiveUpdate res def.value) {};
        };
        default = envConfig.nodeConfig;
        description = ''Internal representation of the config.'';
      };

      targetNumberOfRootPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfRootPeers or 100;
        description = "Limits the maximum number of root peers the node will know about";
      };

      targetNumberOfKnownPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfKnownPeers or cfg.targetNumberOfRootPeers;
        description = ''
          Target number for known peers (root peers + peers known through gossip).
          Default to targetNumberOfRootPeers.
        '';
      };

      targetNumberOfEstablishedPeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfEstablishedPeers
          or (cfg.targetNumberOfKnownPeers / 2);
        description = ''Number of peers the node will be connected to, but not necessarily following their chain.
          Default to half of targetNumberOfKnownPeers.
        '';
      };

      targetNumberOfActivePeers = mkOption {
        type = types.int;
        default = cfg.nodeConfig.TargetNumberOfActivePeers or (2 * cfg.targetNumberOfEstablishedPeers / 5);
        description = ''Number of peers your node is actively downloading headers and blocks from.
          Default to 2/5 of targetNumberOfEstablishedPeers.
        '';
      };

      extraNodeConfig = mkOption {
        type = types.attrs // {
          merge = loc: foldl' (res: def: recursiveUpdate res def.value) {};
        };
        default = {};
        description = ''Additional node config.'';
      };

      extraNodeInstanceConfig = mkOption {
        type = types.functionTo types.attrs
          // {
            merge = loc: foldl' (res: def: i: recursiveUpdate (res i) (def.value i)) (i: {});
          };
        default = i: {};
        description = ''Additional node config for a particular instance.'';
      };

      nodeConfigFile = mkOption {
        type = nullOrStr;
        default = null;
        description = ''Actual configuration file (shell expression).'';
      };

      forceHardForks = mkOption {
        type = types.attrsOf types.int;
        default = {};
        description = ''
          A developer-oriented dictionary option to force hard forks for given eras at given epochs.  Maps capitalised era names (Shelley, Allegra, Mary, etc.) to hard fork epoch number.
          '';
      };

      withCardanoTracer = mkOption {
        type = types.bool;
        default = false;
      };

      withUtxoHdLmdb = mkOption {
        type = funcToOr types.bool;
        default = false;
        apply = x: if lib.isFunction x then x else _: x;
        description = ''On an UTxO-HD enabled node, the in-memory backend is the default. This activates the on-disk backend (LMDB) instead.'';
      };

      extraArgs = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''Extra CLI args for 'cardano-node'.'';
      };

      rts_flags_override = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''RTS flags override from profile content.'';
      };

      rtsArgs = mkOption {
        type = types.listOf types.str;
        default = [ "-N2" "-I0" "-A16m" "-qg" "-qb" "--disable-delayed-os-memory-return" ];
        apply = args: if (args != [] || cfg.profilingArgs != [] || cfg.rts_flags_override != []) then
          ["+RTS"] ++ cfg.profilingArgs ++ args ++ cfg.rts_flags_override ++ ["-RTS"]
          else [];
        description = ''Extra CLI args for 'cardano-node', to be surrounded by "+RTS"/"-RTS"'';
      };

      profilingArgs = mkOption {
        type = types.listOf types.str;
        default = let commonProfilingArgs = ["--machine-readable" "-tcardano-node.stats" "-pocardano-node"]
          ++ lib.optional (cfg.eventlog) "-l";
          in if cfg.profiling == "time" then ["-p"] ++ commonProfilingArgs
            else if cfg.profiling == "time-detail" then ["-P"] ++ commonProfilingArgs
            else if cfg.profiling == "space" then ["-h"] ++ commonProfilingArgs
            else if cfg.profiling == "space-cost" then ["-hc"] ++ commonProfilingArgs
            else if cfg.profiling == "space-module" then ["-hm"] ++ commonProfilingArgs
            else if cfg.profiling == "space-closure" then ["-hd"] ++ commonProfilingArgs
            else if cfg.profiling == "space-type" then ["-hy"] ++ commonProfilingArgs
            else if cfg.profiling == "space-retainer" then ["-hr"] ++ commonProfilingArgs
            else if cfg.profiling == "space-bio" then ["-hb"] ++ commonProfilingArgs
            else if cfg.profiling == "space-heap" then ["-hT"] ++ commonProfilingArgs
            else [];
        description = ''RTS profiling options'';
      };

      peerSnapshotFile = mkOption {
        type = funcToOr nullOrStr;
        default = i:
          # Node config in 10.5 will default to genesis mode for preview and preprod.
          if cfg.useNewTopology && elem cfg.environment ["preview" "preprod"]
          then
            if cfg.useSystemdReload
            then "peer-snapshot-${toString i}.json"
            else toFile "peer-snapshot.json" (toJSON (envConfig.peerSnapshot))
          else null;
        example = i: "/etc/cardano-node/peer-snapshot-${toString i}.json";
        apply = x: if lib.isFunction x then x else _: x;
        description = ''
          If set, cardano-node will load a peer snapshot file from the declared path which can
          be absolute or relative.  If a relative path is given, it will be interpreted relative
          to the location of the topology file which it is declared in.

          The peer snapshot file contains a snapshot of big ledger peers taken at some arbitrary slot.
          These are the largest pools that cumulatively hold 90% of total stake.

          A peer snapshot file can be generated with a `cardano-cli query ledger-peer-snapshot` command.
        '';
      };
    };
  };

  config = mkIf cfg.enable ( let
    lmdbPaths = filter (x: x != null) (map (e: cfg.lmdbDatabasePath e) (builtins.genList lib.trivial.id cfg.instances));
    genInstanceConf = f: listToAttrs (if cfg.instances > 1
      then genList (i: let n = "cardano-node-${toString i}"; in nameValuePair n (f n i)) cfg.instances
      else [ (nameValuePair "cardano-node" (f "cardano-node" 0)) ]); in lib.mkMerge [
    {
      users.groups.cardano-node.gid = 10016;
      users.users.cardano-node = {
        description = "cardano-node node daemon user";
        uid = 10016;
        group = "cardano-node";
        isSystemUser = true;
      };

      environment.etc = mkMerge [
        (mkIf cfg.useSystemdReload
          (foldl'
            (acc: i: recursiveUpdate acc {"cardano-node/topology-${toString i}.yaml".source = selectTopology i;}) {}
          (range 0 (cfg.instances - 1)))
        )
        (mkIf (cfg.useNewTopology && cfg.useSystemdReload)
          (foldl'
            (acc: i: recursiveUpdate acc {"cardano-node/peer-snapshot-${toString i}.json".source = toFile "peer-snapshot.json" (toJSON (envConfig.peerSnapshot));}) {}
          (range 0 (cfg.instances - 1)))
        )
      ];

      ## TODO:  use http://hackage.haskell.org/package/systemd for:
      ##   1. only declaring success after we perform meaningful init (local state recovery)
      ##   2. heartbeat & watchdog functionality
      systemd.services = genInstanceConf (n: i: recursiveUpdate {
        description   = "cardano-node node ${toString i} service";
        after         = [ "network-online.target" ]
          ++ (optional cfg.systemdSocketActivation "${n}.socket")
          ++ (optional (cfg.instances > 1) "cardano-node.service");
        requires = optional cfg.systemdSocketActivation "${n}.socket"
          ++ (optional (cfg.instances > 1) "cardano-node.service");
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        partOf = mkIf (cfg.instances > 1) ["cardano-node.service"];
        reloadTriggers = mkIf (cfg.useSystemdReload && cfg.useNewTopology) [ (selectTopology i) ];
        script = mkScript cfg i;
        serviceConfig = {
          User = "cardano-node";
          Group = "cardano-node";
          ExecReload = mkIf (cfg.useSystemdReload && cfg.useNewTopology) "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          Restart = "always";
          RuntimeDirectory = lib.mkIf (!cfg.systemdSocketActivation)
            (lib.removePrefix cfg.runDirBase (runtimeDir i));
          WorkingDirectory = cfg.stateDir i;
          # This assumes cfg.stateDirBase is a prefix of cfg.stateDir.
          # This is checked as an assertion below.
          StateDirectory =  lib.removePrefix cfg.stateDirBase (cfg.stateDir i);
          NonBlocking = lib.mkIf cfg.systemdSocketActivation true;
          # time to sleep before restarting a service
          RestartSec = 1;
        };
      } (cfg.extraServiceConfig i));

      systemd.sockets = genInstanceConf (n: i: lib.mkIf cfg.systemdSocketActivation (recursiveUpdate {
        description = "Socket of the ${n} service.";
        wantedBy = [ "sockets.target" ];
        partOf = [ "${n}.service" ];
        socketConfig = {
          ListenStream = [ "${cfg.hostAddr}:${toString (if cfg.shareIpv4port then cfg.port else cfg.port + i)}" ]
            ++ optional (cfg.ipv6HostAddr i != null) "[${cfg.ipv6HostAddr i}]:${toString (if cfg.shareIpv6port then cfg.port else cfg.port + i)}"
            ++ (cfg.additionalListenStream i)
            ++ [(cfg.socketPath i)];
          RuntimeDirectory = lib.removePrefix cfg.runDirBase (cfg.runtimeDir i);
          NoDelay = "yes";
          ReusePort = "yes";
          SocketMode = "0660";
          SocketUser = "cardano-node";
          SocketGroup = cfg.socketGroup;
          FreeBind = "yes";
        };
      } (cfg.extraSocketConfig i)));
    }
    {
      # oneshot service start allows to easily control all instances at once.
      systemd.services.cardano-node = lib.mkIf (cfg.instances > 1) {
        description = "Control all ${toString cfg.instances} at once.";
        enable  = true;
        wants = genList (i: "cardano-node-${toString i}.service") cfg.instances;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = "yes";
          User = "cardano-node";
          Group = "cardano-node";
          ExecStart = "${pkgs.coreutils}/bin/echo Starting ${toString cfg.instances} cardano-node instances";
          WorkingDirectory = cfg.stateDir i;
          StateDirectory =  lib.removePrefix cfg.stateDirBase (cfg.stateDir i);
        };
      };
    }
    {
      assertions = [
        {
          assertion = builtins.all (i : lib.hasPrefix cfg.stateDirBase (cfg.stateDir i))
                                   (builtins.genList lib.trivial.id cfg.instances);
          message = "The option services.cardano-node.stateDir should have ${cfg.stateDirBase}
                     as a prefix, for each instance!";
        }
        {
          assertion = (cfg.kesKey == null) == (cfg.vrfKey == null) && (cfg.kesKey == null) == (cfg.operationalCertificate == null);
          message = "Shelley Era: all of three [operationalCertificate kesKey vrfKey] options must be defined (or none of them).";
        }
        {
          assertion = !(cfg.systemdSocketActivation && cfg.useNewTopology);
          message = "Systemd socket activation cannot be used with p2p topology due to a systemd socket re-use issue.";
        }
        {
          assertion = (length lmdbPaths) == (length (lib.lists.unique lmdbPaths));
          message   = "When configuring multiple LMDB enabled nodes on one instance, lmdbDatabasePath must be unique.";
        }
      ];
    }
  ]);
}
