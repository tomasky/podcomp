///|
/// Turning one container description into the argument list `podman` sees.
/// This is the heart of the tool: every Compose field that maps onto a podman
/// flag is translated here.

///|
/// A parsed volume/mount description.
struct Mount {
  kind : String
  source : String?
  target : String
  options : Array[String]
}

///|
/// The argument list for `podman create`/`run`, following the reference
/// implementation's ordering closely enough that the output is comparable.
pub fn container_to_args(
  compose : Compose,
  cnt : @yaml.Yaml,
  detached : Bool,
  no_deps : Bool,
) -> Array[String] raise Error {
  let args : Array[String] = []
  let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
  args.push("--name=" + name)
  if detached {
    args.push("-d")
  }
  match y_get(cnt, "pod") {
    Some(pod) =>
      match y_str(pod) {
        Some(p) if p.length() > 0 => args.push("--pod=" + p)
        _ => ()
      }
    None => ()
  }
  if !no_deps {
    let dep_names = y_list_str(y_get(cnt, "_deps").unwrap_or(y_null()))
    if dep_names.length() > 0 {
      let csv : Array[String] = []
      for d in dep_names {
        match compose.container_names_by_service.get(d) {
          Some(names) =>
            for n in names {
              csv.push(n)
            }
          None => ()
        }
      }
      if csv.length() > 0 {
        args.push("--requires=" + csv.join(","))
      }
    }
  }
  for item in y_list_str(y_get(cnt, "security_opt").unwrap_or(y_null())) {
    args.push("--security-opt")
    args.push(item)
  }
  for item in y_list_str(y_get(cnt, "annotations").unwrap_or(y_null())) {
    args.push("--annotation")
    args.push(item)
  }
  if y_bool(y_get(cnt, "read_only").unwrap_or(y_null())).unwrap_or(false) {
    args.push("--read-only")
  }
  match y_get(cnt, "http_proxy") {
    Some(v) => if y_bool(v) is Some(false) { args.push("--http-proxy=false") }
    None => ()
  }
  for label in y_list_str(y_get(cnt, "labels").unwrap_or(y_null())) {
    args.push("--label")
    args.push(label)
  }
  push_pairs(
    args,
    "--cap-add",
    y_list_str(y_get(cnt, "cap_add").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--cap-drop",
    y_list_str(y_get(cnt, "cap_drop").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--group-add",
    y_list_str(y_get(cnt, "group_add").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--device",
    y_list_str(y_get(cnt, "devices").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--device-cgroup-rule",
    y_list_str(y_get(cnt, "device_cgroup_rules").unwrap_or(y_null())),
  )
  push_pairs(args, "--dns", y_list_str(y_get(cnt, "dns").unwrap_or(y_null())))
  push_pairs(
    args,
    "--dns-opt",
    y_list_str(y_get(cnt, "dns_opt").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--dns-search",
    y_list_str(y_get(cnt, "dns_search").unwrap_or(y_null())),
  )
  // env_file entries are read and expanded inline.
  for env_file in y_list(y_get(cnt, "env_file").unwrap_or(y_null())) {
    let (path, required) = env_file_path(env_file)
    if path.length() == 0 {
      continue
    }
    let full = path_abspath(compose.dirname, path)
    if !@fs.path_exists(full) {
      if required {
        raise fail("env file at \{full} does not exist")
      }
      continue
    }
    for entry in compose_env_file(compose, full) {
      args.push("-e")
      args.push(entry.0 + "=" + entry.1)
    }
  }
  for item in y_env_list(y_get(cnt, "environment").unwrap_or(y_null())) {
    if item.contains_char('=') {
      args.push("-e")
      args.push(item)
    } else {
      match compose.environ.get(item) {
        Some(value) => {
          args.push("-e")
          args.push(item + "=" + value)
        }
        None => ()
      }
    }
  }
  for item in y_list_str(y_get(cnt, "tmpfs").unwrap_or(y_null())) {
    args.push("--tmpfs")
    args.push(item)
  }
  for mount in container_mounts(compose, cnt) {
    for arg in mount_arg(compose, cnt, mount) {
      args.push(arg)
    }
  }
  for arg in network_args(compose, cnt) {
    args.push(arg)
  }
  match y_get(cnt, "logging") {
    Some(logging) =>
      match y_map(logging) {
        Some(lm) => {
          let driver = match lm.get("driver") {
            Some(d) => y_str_or(d, "k8s-file")
            None => "k8s-file"
          }
          args.push("--log-driver=" + driver)
          match lm.get("options") {
            Some(options) =>
              match y_map(options) {
                Some(om) =>
                  for entry in om {
                    args.push(
                      "--log-opt=" + entry.0 + "=" + y_str_or(entry.1, ""),
                    )
                  }
                None => ()
              }
            None => ()
          }
        }
        None => ()
      }
    None => ()
  }
  for secret in y_list(y_get(cnt, "secrets").unwrap_or(y_null())) {
    for arg in secret_args(secret) {
      args.push(arg)
    }
  }
  push_pairs(
    args,
    "--add-host",
    y_list_str(y_get(cnt, "extra_hosts").unwrap_or(y_null())),
  )
  push_pairs(
    args,
    "--expose",
    y_list_str(y_get(cnt, "expose").unwrap_or(y_null())),
  )
  if y_bool(y_get(cnt, "publishall").unwrap_or(y_null())).unwrap_or(false) {
    args.push("-P")
  }
  for port in y_list(y_get(cnt, "ports").unwrap_or(y_null())) {
    match port_to_str(port) {
      Some(spec) => {
        args.push("-p")
        args.push(spec)
      }
      None => ()
    }
  }
  match y_get(cnt, "userns_mode") {
    Some(v) =>
      match y_str(v) {
        Some(s) => {
          args.push("--userns")
          args.push(s)
        }
        None => ()
      }
    None => ()
  }
  match y_get(cnt, "user") {
    Some(v) =>
      match y_str(v) {
        Some(s) => {
          args.push("-u")
          args.push(s)
        }
        None => ()
      }
    None => ()
  }
  match y_get(cnt, "working_dir") {
    Some(v) =>
      match y_str(v) {
        Some(s) => {
          args.push("-w")
          args.push(s)
        }
        None => ()
      }
    None => ()
  }
  push_opt(args, "--hostname", y_get(cnt, "hostname"))
  push_opt(args, "--shm-size", y_get(cnt, "shm_size"))
  if y_bool(y_get(cnt, "stdin_open").unwrap_or(y_null())).unwrap_or(false) {
    args.push("-i")
  }
  push_opt(args, "--stop-signal", y_get(cnt, "stop_signal"))
  match y_get(cnt, "stop_grace_period") {
    Some(v) =>
      match y_str(v) {
        Some(s) =>
          match str_to_seconds(s) {
            Some(seconds) => {
              args.push("--stop-timeout")
              args.push(seconds.to_string())
            }
            None => ()
          }
        None => ()
      }
    None => ()
  }
  match y_get(cnt, "sysctls") {
    Some(v) =>
      match v {
        @yaml.Yaml::Map(m) =>
          for entry in m {
            args.push("--sysctl")
            args.push(entry.0 + "=" + y_str_or(entry.1, ""))
          }
        @yaml.Yaml::Array(_) => push_pairs(args, "--sysctl", y_list_str(v))
        _ => ()
      }
    None => ()
  }
  if y_bool(y_get(cnt, "tty").unwrap_or(y_null())).unwrap_or(false) {
    args.push("--tty")
  }
  if y_bool(y_get(cnt, "privileged").unwrap_or(y_null())).unwrap_or(false) {
    args.push("--privileged")
  }
  push_opt(args, "--pid", y_get(cnt, "pid"))
  match y_get(cnt, "pull_policy") {
    Some(v) =>
      match y_str(v) {
        Some(policy) => if policy != "build" { args.push("--pull=" + policy) }
        None => ()
      }
    None => ()
  }
  push_opt(args, "--restart", y_get(cnt, "restart"))
  for ulimit in ulimit_args(y_get(cnt, "ulimits").unwrap_or(y_null())) {
    args.push("--ulimit")
    args.push(ulimit)
  }
  for arg in resource_args(cnt) {
    args.push(arg)
  }
  if y_bool(y_get(cnt, "init").unwrap_or(y_null())).unwrap_or(false) {
    args.push("--init")
  }
  push_opt(args, "--init-path", y_get(cnt, "init-path"))
  push_opt(args, "--ipc", y_get(cnt, "ipc"))
  match y_get(cnt, "entrypoint") {
    Some(v) =>
      match v {
        @yaml.Yaml::String(s) => {
          args.push("--entrypoint")
          args.push(json_string_array(shell_split(s)))
        }
        @yaml.Yaml::Array(_) => {
          args.push("--entrypoint")
          args.push(json_string_array(y_list_str(v)))
        }
        _ => ()
      }
    None => ()
  }
  push_opt(args, "--platform", y_get(cnt, "platform"))
  push_opt(args, "--runtime", y_get(cnt, "runtime"))
  push_opt(args, "--cpuset-cpus", y_get(cnt, "cpuset"))
  for arg in healthcheck_args(y_get(cnt, "healthcheck")) {
    args.push(arg)
  }
  for uidmap in y_list_str(y_get(cnt, "x-podman.uidmaps").unwrap_or(y_null())) {
    args.push("--uidmap")
    args.push(uidmap)
  }
  for gidmap in y_list_str(y_get(cnt, "x-podman.gidmaps").unwrap_or(y_null())) {
    args.push("--gidmap")
    args.push(gidmap)
  }
  if y_bool(y_get(cnt, "x-podman.no_hosts").unwrap_or(y_null())).unwrap_or(
      false,
    ) {
    args.push("--no-hosts")
  }
  // The image, then the command.
  match y_get(cnt, "x-podman.rootfs") {
    Some(rootfs) =>
      match y_str(rootfs) {
        Some(s) => {
          args.push("--rootfs")
          args.push(s)
        }
        None => ()
      }
    None =>
      match y_get(cnt, "image") {
        Some(image) => args.push(y_str_or(image, ""))
        None => ()
      }
  }
  match y_get(cnt, "command") {
    Some(v) =>
      match v {
        @yaml.Yaml::String(s) =>
          for part in shell_split(s) {
            args.push(part)
          }
        _ =>
          for part in y_list_str(v) {
            args.push(part)
          }
      }
    None => ()
  }
  args
}

///|
/// Append `flag value` for every value in `values`.
fn push_pairs(
  args : Array[String],
  flag : String,
  values : Array[String],
) -> Unit {
  for v in values {
    args.push(flag)
    args.push(v)
  }
}

///|
/// Append `flag value` when a scalar is present.
fn push_opt(args : Array[String], flag : String, value : @yaml.Yaml?) -> Unit {
  match value {
    Some(v) =>
      match y_str(v) {
        Some(s) => {
          args.push(flag)
          args.push(s)
        }
        None => ()
      }
    None => ()
  }
}

///|
/// Split an `env_file` entry into its path and whether it is required.
fn env_file_path(entry : @yaml.Yaml) -> (String, Bool) {
  match entry {
    @yaml.Yaml::String(s) => (s, true)
    @yaml.Yaml::Map(m) => {
      let path = match m.get("path") {
        Some(p) => y_str_or(p, "")
        None => ""
      }
      let required = match m.get("required") {
        Some(r) => y_bool(r).unwrap_or(true)
        None => true
      }
      (path, required)
    }
    _ => ("", true)
  }
}

///|
/// Render a `ports` entry as `[[ip:]published:]target[/proto]`.
fn port_to_str(port : @yaml.Yaml) -> String? {
  match port {
    @yaml.Yaml::String(s) => Some(s)
    @yaml.Yaml::Integer(i) => Some(i.to_string())
    @yaml.Yaml::Map(m) => {
      let target = match m.get("target") {
        Some(t) => y_str_or(t, "")
        None => ""
      }
      if target.length() == 0 {
        return None
      }
      let protocol = match m.get("protocol") {
        Some(p) => y_str_or(p, "tcp")
        None => "tcp"
      }
      let out = StringBuilder()
      match m.get("host_ip") {
        Some(ip) =>
          match y_str(ip) {
            Some(s) if s.length() > 0 => {
              out.write_string(s)
              out.write_char(':')
            }
            _ => ()
          }
        None => ()
      }
      match m.get("published") {
        Some(published) =>
          match y_str(published) {
            Some(s) if s.length() > 0 => {
              out.write_string(s)
              out.write_char(':')
            }
            _ => ()
          }
        None => ()
      }
      out.write_string(target)
      out.write_char('/')
      out.write_string(protocol)
      Some(out.to_string())
    }
    _ => None
  }
}

///|
/// Secret references become `--secret` flags.
fn secret_args(secret : @yaml.Yaml) -> Array[String] {
  let args : Array[String] = []
  match secret {
    @yaml.Yaml::String(s) => {
      args.push("--secret")
      args.push(s)
    }
    @yaml.Yaml::Map(m) => {
      let source = match m.get("source") {
        Some(s) => y_str_or(s, "")
        None => ""
      }
      if source.length() == 0 {
        return args
      }
      let spec = StringBuilder()
      spec.write_string(source)
      match m.get("target") {
        Some(t) =>
          match y_str(t) {
            Some(target) if target.length() > 0 =>
              spec.write_string(",target=" + target)
            _ => ()
          }
        None => ()
      }
      args.push("--secret")
      args.push(spec.to_string())
    }
    _ => ()
  }
  args
}

///|
/// `ulimits` in either the scalar, list or mapping form.
fn ulimit_args(v : @yaml.Yaml) -> Array[String] {
  let out : Array[String] = []
  match v {
    @yaml.Yaml::Null | @yaml.Yaml::BadValue => ()
    @yaml.Yaml::String(s) => out.push(s)
    @yaml.Yaml::Map(m) =>
      for entry in m {
        out.push(entry.0 + "=" + norm_ulimit(entry.1))
      }
    @yaml.Yaml::Array(_) =>
      for entry in y_dict(v) {
        out.push(entry.0 + "=" + norm_ulimit(entry.1))
      }
    _ => ()
  }
  out
}

///|
fn norm_ulimit(v : @yaml.Yaml) -> String {
  match v {
    @yaml.Yaml::Map(m) => {
      let soft = match m.get("soft") {
        Some(s) => y_str_or(s, "")
        None => ""
      }
      let hard = match m.get("hard") {
        Some(h) => y_str_or(h, "")
        None => soft
      }
      let soft = if soft.length() == 0 { hard } else { soft }
      soft + ":" + hard
    }
    _ => y_str_or(v, "")
  }
}

///|
/// CPU and memory limits from `deploy.resources.limits`.
fn resource_args(cnt : @yaml.Yaml) -> Array[String] {
  let out : Array[String] = []
  match y_get(cnt, "deploy") {
    Some(deploy) =>
      match y_get(deploy, "resources") {
        Some(resources) =>
          match y_get(resources, "limits") {
            Some(limits) => {
              match y_get(limits, "cpus") {
                Some(cpus) =>
                  match y_str(cpus) {
                    Some(s) => {
                      out.push("--cpus")
                      out.push(s)
                    }
                    None => ()
                  }
                None => ()
              }
              match y_get(limits, "memory") {
                Some(memory) =>
                  match y_str(memory) {
                    Some(s) => {
                      out.push("--memory")
                      out.push(s)
                    }
                    None => ()
                  }
                None => ()
              }
            }
            None => ()
          }
        None => ()
      }
    None => ()
  }
  out
}

///|
/// The `healthcheck` block.
fn healthcheck_args(healthcheck : @yaml.Yaml?) -> Array[String] {
  let out : Array[String] = []
  let hm = match healthcheck.bind(y_map) {
    Some(m) => m
    None => return out
  }
  let disable = match hm.get("disable") {
    Some(d) => y_bool(d).unwrap_or(false)
    None => false
  }
  if disable {
    out.push("--no-healthcheck")
  } else {
    match hm.get("test") {
      Some(hc) => apply_healthcheck_test(out, hc)
      None => ()
    }
  }
  push_opt(out, "--health-interval", hm.get("interval"))
  push_opt(out, "--health-timeout", hm.get("timeout"))
  push_opt(out, "--health-start-period", hm.get("start_period"))
  push_opt(out, "--health-startup-interval", hm.get("start_interval"))
  match hm.get("retries") {
    Some(r) =>
      match y_str(r) {
        Some(s) => {
          out.push("--health-retries")
          out.push(s)
        }
        None => ()
      }
    None => ()
  }
  out
}

///|
/// The `test:` of a healthcheck: a shell string, or a `CMD`/`CMD-SHELL` list.
fn apply_healthcheck_test(out : Array[String], hc : @yaml.Yaml) -> Unit {
  match hc {
    @yaml.Yaml::String(s) => {
      out.push("--health-cmd")
      out.push(json_string_array(["CMD-SHELL", s]))
    }
    @yaml.Yaml::Array(_) => {
      let parts = y_list_str(hc)
      if parts.length() > 0 {
        let kind = parts[0]
        let rest : Array[String] = []
        for i in 1..<parts.length() {
          rest.push(parts[i])
        }
        if kind == "NONE" {
          out.push("--no-healthcheck")
        } else if kind == "CMD" || kind == "CMD-SHELL" {
          out.push("--health-cmd")
          out.push(json_string_array(rest))
        }
      }
    }
    _ => ()
  }
}

///|
/// Convert `"90s"`, `"1m30s"`, `"500ms"` or a bare number to seconds.
pub fn str_to_seconds(text : String) -> Int32? {
  let s = text.trim().to_owned()
  if s.length() == 0 {
    return None
  }
  let mut total = 0
  let number = StringBuilder()
  let mut i = 0
  let chars = s.to_array()
  let mut saw_unit = false
  while i < chars.length() {
    let c = chars[i]
    if (c >= '0' && c <= '9') || c == '.' {
      number.write_char(c)
      i += 1
      continue
    }
    let value = @string.parse_double(number.to_string()) catch {
      _ => return None
    }
    number.reset()
    saw_unit = true
    match c {
      'h' => total = total + (value * 3600.0).to_int()
      'm' =>
        // `ms` is milliseconds; a lone `m` is minutes.
        if i + 1 < chars.length() && chars[i + 1] == 's' {
          i += 1
        } else {
          total = total + (value * 60.0).to_int()
        }
      's' => total = total + value.to_int()
      _ => return None
    }
    i += 1
  }
  if !number.is_empty() {
    let value = @string.parse_double(number.to_string()) catch {
      _ => return None
    }
    total = total + value.to_int()
  } else if !saw_unit {
    return None
  }
  Some(total)
}

///|
/// A JSON array of strings, for `--entrypoint` and `--health-cmd`, which podman
/// expects in that form.
fn json_string_array(items : Array[String]) -> String {
  let out = StringBuilder()
  out.write_char('[')
  let mut first = true
  for item in items {
    if !first {
      out.write_char(',')
    }
    first = false
    out.write_char('"')
    for c in item {
      match c {
        '"' => out.write_string("\\\"")
        '\\' => out.write_string("\\\\")
        '\n' => out.write_string("\\n")
        '\t' => out.write_string("\\t")
        '\r' => out.write_string("\\r")
        _ => out.write_char(c)
      }
    }
    out.write_char('"')
  }
  out.write_char(']')
  out.to_string()
}
