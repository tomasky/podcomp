///|
/// Volume mounts and network wiring: the two places where Compose's shorthand
/// syntax has to be unpacked before podman sees it.

///|
/// Translate one `volumes` entry into podman arguments.
pub fn mount_args(
  compose : Compose,
  cnt : @yaml.Yaml,
  volume : @yaml.Yaml,
) -> Array[String] {
  let mount = parse_mount(compose, cnt, volume)
  let args : Array[String] = []
  match mount.kind {
    "bind" =>
      match mount.source {
        Some(source) => {
          args.push("-v")
          args.push(volume_spec(source, mount.target, mount.options))
        }
        None => ()
      }
    "volume" => {
      let source = match mount.source {
        Some(s) => resolve_volume_name(compose, cnt, s, mount.target)
        None => anonymous_volume_name(compose, cnt, mount.target)
      }
      args.push("--mount")
      args.push(
        "type=volume,source=" +
        source +
        ",destination=" +
        mount.target +
        opts_suffix(mount.options),
      )
    }
    "tmpfs" => {
      args.push("--tmpfs")
      args.push(mount.target + tmpfs_suffix(mount.options))
    }
    _ => {
      // image, glob and anything else go through --mount.
      let source = mount.source.unwrap_or("")
      args.push("--mount")
      args.push(
        "type=" +
        mount.kind +
        ",source=" +
        source +
        ",destination=" +
        mount.target +
        opts_suffix(mount.options),
      )
    }
  }
  args
}

///|
/// `source:target` plus a comma-joined option list.
fn volume_spec(
  source : String,
  target : String,
  options : Array[String],
) -> String {
  if options.length() == 0 {
    source + ":" + target
  } else {
    source + ":" + target + ":" + options.join(",")
  }
}

///|
/// `,a,b` or the empty string.
fn opts_suffix(options : Array[String]) -> String {
  if options.length() == 0 {
    ""
  } else {
    "," + options.join(",")
  }
}

///|
/// `:size=...,mode=...` for a tmpfs mount.
fn tmpfs_suffix(options : Array[String]) -> String {
  if options.length() == 0 {
    ""
  } else {
    ":" + options.join(",")
  }
}

///|
/// Parse a short `SOURCE:TARGET[:OPTIONS]` string or a long mapping.
fn parse_mount(
  compose : Compose,
  cnt : @yaml.Yaml,
  volume : @yaml.Yaml,
) -> Mount {
  match volume {
    @yaml.Yaml::String(spec) => parse_short_mount(spec, compose.dirname)
    @yaml.Yaml::Map(m) => {
      let kind = match m.get("type") {
        Some(t) => y_str_or(t, "volume")
        None => "volume"
      }
      let source = match m.get("source") {
        Some(s) => y_str(s)
        None => None
      }
      let target = match m.get("target") {
        Some(t) => y_str_or(t, "")
        None => ""
      }
      let options : Array[String] = []
      if y_bool(m.get("read_only").unwrap_or(y_null())).unwrap_or(false) {
        options.push("ro")
      }
      match m.get("bind") {
        Some(bind) =>
          match y_map(bind) {
            Some(bm) => {
              match bm.get("propagation") {
                Some(p) =>
                  match y_str(p) {
                    Some(s) if s.length() > 0 => options.push(s)
                    _ => ()
                  }
                None => ()
              }
              match bm.get("selinux") {
                Some(p) =>
                  match y_str(p) {
                    Some(s) if s.length() > 0 => options.push(s)
                    _ => ()
                  }
                None => ()
              }
              if y_bool(bm.get("create_host_path").unwrap_or(y_null())).unwrap_or(
                  false,
                ) {
                ignore(cnt)
              }
            }
            None => ()
          }
        None => ()
      }
      match m.get("tmpfs") {
        Some(tmpfs) =>
          match y_map(tmpfs) {
            Some(tm) => {
              match tm.get("size") {
                Some(size) =>
                  match y_str(size) {
                    Some(s) => options.push("size=" + s)
                    None => ()
                  }
                None => ()
              }
              match tm.get("mode") {
                Some(mode) =>
                  match y_str(mode) {
                    Some(s) => options.push("mode=" + s)
                    None => ()
                  }
                None => ()
              }
            }
            None => ()
          }
        None => ()
      }
      { kind, source, target, options, }
    }
    _ => { kind: "volume", source: None, target: "", options: [], }
  }
}

///|
/// Parse the short mount form. A bare path is an anonymous volume; a path-like
/// source is a bind mount; anything else is a named volume.
pub fn parse_short_mount(spec : String, basedir : String) -> Mount {
  let parts = spec.split(":").to_array()
  let mut source : String? = None
  let mut target = spec
  let mut opts_text = ""
  match parts.length() {
    1 => target = spec
    2 =>
      if parts[1].has_prefix("/") {
        source = Some(parts[0].to_owned())
        target = parts[1].to_owned()
      } else {
        target = parts[0].to_owned()
        opts_text = parts[1].to_owned()
      }
    _ => {
      source = Some(parts[0].to_owned())
      target = parts[1].to_owned()
      opts_text = parts[2].to_owned()
    }
  }
  let options : Array[String] = []
  for opt in opts_text.split(",") {
    let o = opt.to_owned()
    if o.length() > 0 {
      options.push(o)
    }
  }
  match source {
    Some(src) =>
      if is_path_like(src) {
        {
          kind: "bind",
          source: Some(path_abspath(basedir, src)),
          target,
          options,
        }
      } else {
        { kind: "volume", source: Some(src), target, options, }
      }
    None => { kind: "volume", source: None, target, options, }
  }
}

///|
/// Whether a mount source names a host path rather than a named volume.
fn is_path_like(source : String) -> Bool {
  source.has_prefix("/") ||
  source.has_prefix("./") ||
  source.has_prefix("../") ||
  source.has_prefix("~")
}

///|
/// The podman name of a named volume: `name`, the external name, or the
/// project-prefixed default.
pub fn resolve_volume_name(
  compose : Compose,
  cnt : @yaml.Yaml,
  source : String,
  target : String,
) -> String {
  ignore(cnt)
  ignore(target)
  match compose.vols.get(source) {
    Some(vol) =>
      match y_get(vol, "name") {
        Some(n) =>
          match y_str(n) {
            Some(s) if s.length() > 0 => s
            _ => project_volume_name(compose, source, vol)
          }
        None => project_volume_name(compose, source, vol)
      }
    None => compose.project_name + "_" + source
  }
}

///|
fn project_volume_name(
  compose : Compose,
  source : String,
  vol : @yaml.Yaml,
) -> String {
  match y_get(vol, "external") {
    Some(ext) =>
      match ext {
        @yaml.Yaml::Map(m) =>
          match m.get("name") {
            Some(n) => y_str_or(n, source)
            None => source
          }
        @yaml.Yaml::Boolean(b) =>
          if b {
            source
          } else {
            compose.project_name + "_" + source
          }
        _ => compose.project_name + "_" + source
      }
    None => compose.project_name + "_" + source
  }
}

///|
/// A deterministic name for an anonymous volume.
fn anonymous_volume_name(
  compose : Compose,
  cnt : @yaml.Yaml,
  target : String,
) -> String {
  let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "service")
  compose.project_name + "_" + service + "_" + simple_hash(target)
}

///|
/// `--network` arguments for a container.
pub fn network_args(compose : Compose, cnt : @yaml.Yaml) -> Array[String] {
  let args : Array[String] = []
  match y_get(cnt, "network_mode") {
    Some(mode) =>
      match y_str(mode) {
        Some(m) =>
          if m.has_prefix("service:") {
            let other = m[8:].to_owned()
            match compose.container_names_by_service.get(other) {
              Some(names) =>
                if names.length() > 0 {
                  args.push("--network=container:" + names[0])
                }
              None => args.push("--network=" + m)
            }
          } else {
            args.push("--network=" + m)
          }
        None => ()
      }
    None => {
      let service_name = y_str_or(
        y_get(cnt, "service_name").unwrap_or(y_null()),
        "",
      )
      let aliases : Array[String] = ["alias=" + service_name]
      let nets = container_networks(compose, cnt)
      if nets.is_empty() {
        // No default network: fall back to podman's own bridge.
        args.push("--network=bridge:" + aliases.join(","))
      } else {
        for entry in nets {
          let (net, config) = entry
          let net_name = network_name(compose, net)
          let options : Array[String] = []
          options.append(aliases)
          match y_map(config) {
            Some(cm) => {
              match cm.get("ipv4_address") {
                Some(ip) =>
                  match y_str(ip) {
                    Some(s) if s.length() > 0 => options.push("ip=" + s)
                    _ => ()
                  }
                None => ()
              }
              match cm.get("ipv6_address") {
                Some(ip) =>
                  match y_str(ip) {
                    Some(s) if s.length() > 0 => options.push("ip6=" + s)
                    _ => ()
                  }
                None => ()
              }
              match cm.get("mac_address") {
                Some(mac) =>
                  match y_str(mac) {
                    Some(s) if s.length() > 0 => options.push("mac=" + s)
                    _ => ()
                  }
                None => ()
              }
              for net_alias in y_list_str(cm.get("aliases").unwrap_or(y_null())) {
                options.push("alias=" + net_alias)
              }
            }
            None => ()
          }
          args.push("--network=" + net_name + ":" + options.join(","))
        }
      }
    }
  }
  args
}

///|
/// The podman name of a top-level network, honouring `name` and `external`.
pub fn network_name(compose : Compose, net : String) -> String {
  let desc = match compose.networks.get(net) {
    Some(d) => d
    None => return default_network_name(compose, net)
  }
  match y_get(desc, "name") {
    Some(n) =>
      match y_str(n) {
        Some(s) if s.length() > 0 => return s
        _ => ()
      }
    None => ()
  }
  match y_get(desc, "external") {
    Some(ext) =>
      match ext {
        @yaml.Yaml::Map(m) =>
          match m.get("name") {
            Some(n) => return y_str_or(n, net)
            None => ()
          }
        @yaml.Yaml::Boolean(b) => if b { return net }
        _ => ()
      }
    None => ()
  }
  default_network_name(compose, net)
}

///|
/// `<project>_<net>` (or the compatibility spelling).
fn default_network_name(compose : Compose, net : String) -> String {
  if x_flag(compose, "default_net_name_compat") {
    join_name_parts(compose, [
      compose.project_name.replace(old="-", new=""),
      net,
    ])
  } else {
    format_name(compose, [net])
  }
}

///|
/// The networks a container joins: the service's `networks`, or the project's
/// default network.
pub fn container_networks(
  compose : Compose,
  cnt : @yaml.Yaml,
) -> Map[String, @yaml.Yaml] {
  match y_get(cnt, "networks") {
    Some(n) =>
      match n {
        @yaml.Yaml::Map(m) => m
        @yaml.Yaml::Array(_) => {
          let out : Map[String, @yaml.Yaml] = Map([])
          for item in y_list(n) {
            match y_str(item) {
              Some(s) => out[s] = y_obj([])
              None => ()
            }
          }
          out
        }
        _ => Map([])
      }
    None =>
      match compose.default_net {
        Some(net) => {
          let out : Map[String, @yaml.Yaml] = Map([])
          out[net] = y_obj([])
          out
        }
        None => Map([])
      }
  }
}

///|
/// Create the networks a container joins, unless they already exist.
pub async fn assert_networks(
  compose : Compose,
  podman : Podman,
  cnt : @yaml.Yaml,
) -> Unit raise Error {
  match y_get(cnt, "network_mode") {
    Some(_) => return
    None => ()
  }
  for entry in container_networks(compose, cnt) {
    let (net, _cfg) = entry
    let name = network_name(compose, net)
    match podman_try_output(podman, "network", ["exists", name]) {
      Some(_) => ()
      None => {
        let args : Array[String] = ["create"]
        match compose.networks.get(net) {
          Some(desc) => {
            match y_get(desc, "driver") {
              Some(d) =>
                match y_str(d) {
                  Some(s) if s.length() > 0 => {
                    args.push("--driver")
                    args.push(s)
                  }
                  _ => ()
                }
              None => ()
            }
            if y_bool(y_get(desc, "internal").unwrap_or(y_null())).unwrap_or(
                false,
              ) {
              args.push("--internal")
            }
            match y_get(desc, "driver_opts") {
              Some(opts) =>
                match y_map(opts) {
                  Some(om) =>
                    for e in om {
                      match y_str(e.1) {
                        Some(s) => {
                          args.push("--opt")
                          args.push(e.0 + "=" + s)
                        }
                        None => ()
                      }
                    }
                  None => ()
                }
              None => ()
            }
            for label in y_env_list(y_get(desc, "labels").unwrap_or(y_null())) {
              args.push("--label")
              args.push(label)
            }
          }
          None => ()
        }
        args.push("--label")
        args.push("io.podman.compose.project=" + compose.project_name)
        args.push("--label")
        args.push("com.docker.compose.project=" + compose.project_name)
        args.push(name)
        ignore(podman_run(podman, "network", args))
      }
    }
  }
}

///|
/// Create the named volumes a container mounts, unless they already exist.
pub async fn assert_volumes(
  compose : Compose,
  podman : Podman,
  cnt : @yaml.Yaml,
) -> Unit raise Error {
  for volume in y_list(y_get(cnt, "volumes").unwrap_or(y_null())) {
    let mount = parse_mount(compose, cnt, volume)
    if mount.kind != "volume" {
      continue
    }
    let key = match mount.source {
      Some(s) => s
      None => continue
    }
    let name = resolve_volume_name(compose, cnt, key, mount.target)
    match podman_try_output(podman, "volume", ["inspect", name]) {
      Some(_) => ()
      None => {
        let decl = compose.vols.get(key)
        let is_ext = match decl {
          Some(d) =>
            y_bool(y_get(d, "external").unwrap_or(y_null())).unwrap_or(false)
          None => false
        }
        if is_ext {
          raise fail(
            "external volume [" +
            name +
            "] does not exist; create it first with: podman volume create '" +
            name +
            "'",
          )
        }
        let args : Array[String] = [
          "create",
          "--label",
          "io.podman.compose.project=" + compose.project_name,
          "--label",
          "com.docker.compose.project=" + compose.project_name,
        ]
        match decl {
          Some(d) => {
            match y_get(d, "driver") {
              Some(dr) =>
                match y_str(dr) {
                  Some(s) if s.length() > 0 => {
                    args.push("--driver")
                    args.push(s)
                  }
                  _ => ()
                }
              None => ()
            }
            match y_get(d, "driver_opts") {
              Some(opts) =>
                match y_map(opts) {
                  Some(om) =>
                    for e in om {
                      match y_str(e.1) {
                        Some(s) => {
                          args.push("--opt")
                          args.push(e.0 + "=" + s)
                        }
                        None => ()
                      }
                    }
                  None => ()
                }
              None => ()
            }
            for label in y_env_list(y_get(d, "labels").unwrap_or(y_null())) {
              args.push("--label")
              args.push(label)
            }
          }
          None => ()
        }
        args.push(name)
        ignore(podman_run(podman, "volume", args))
      }
    }
  }
}
