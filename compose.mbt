///|
/// Loading a Compose project: find the files, read the environment, merge and
/// interpolate the documents, then expand services into the containers that
/// will actually be handed to `podman`.

///|
/// The default compose file names, in the order Docker Compose probes them.
pub let default_compose_files : Array[String] = [
  "compose.yaml", "compose.yml", "compose.override.yaml", "compose.override.yml",
  "podman-compose.yaml", "podman-compose.yml", "docker-compose.yml", "docker-compose.yaml",
  "docker-compose.override.yml", "docker-compose.override.yaml",
]

///|
/// A loaded project, ready for a command to run against.
pub struct Compose {
  mut project_name : String
  mut dirname : String
  mut files : Array[String]
  mut environ : Map[String, String]
  mut services : Map[String, @yaml.Yaml]
  mut deps : Map[String, Array[String]]
  mut container_names_by_service : Map[String, Array[String]]
  mut containers : Array[@yaml.Yaml]
  mut container_by_name : Map[String, @yaml.Yaml]
  mut networks : Map[String, @yaml.Yaml]
  mut vols : Map[String, @yaml.Yaml]
  mut declared_secrets : Map[String, @yaml.Yaml]
  mut default_net : String?
  mut pods : Array[String]
  mut merged_yaml : @yaml.Yaml
  mut x_podman : Map[String, @yaml.Yaml]
  podman_version : String?
  mut pod_args : Array[String]
  // `.env` files are read once per path, not once per service that references
  // them.
  env_file_cache : Map[String, Map[String, String]]
}

///|
pub fn new_compose() -> Compose {
  {
    project_name: "",
    dirname: "",
    files: [],
    environ: Map([]),
    services: Map([]),
    deps: Map([]),
    container_names_by_service: Map([]),
    containers: [],
    container_by_name: Map([]),
    networks: Map([]),
    vols: Map([]),
    declared_secrets: Map([]),
    default_net: Some("default"),
    pods: [],
    merged_yaml: y_map_v(Map([])),
    x_podman: Map([]),
    podman_version: None,
    pod_args: [],
    env_file_cache: Map([]),
  }
}

///|
/// The project label prefix, matching what the reference implementation writes
/// so `podman ps --filter label=...` finds containers either tool created.
pub fn compose_labels(compose : Compose) -> Array[String] {
  [
    "io.podman.compose.project=" + compose.project_name,
    "io.podman.compose.version=" + version,
    "PODMAN_SYSTEMD_UNIT=podman-compose@\{compose.project_name}.service",
    "com.docker.compose.project=" + compose.project_name,
    "com.docker.compose.project.working_dir=" + compose.dirname,
    "com.docker.compose.project.config_files=" + compose.files.join(","),
  ]
}

///|
/// `true` when the compatibility setting is enabled.
fn x_flag(compose : Compose, key : String) -> Bool {
  match compose.x_podman.get(key) {
    Some(v) => y_bool(v).unwrap_or(false)
    None => false
  }
}

///|
/// The separator used between the project name and a service name.
fn name_separator(compose : Compose) -> String {
  if x_flag(compose, "name_separator_compat") {
    "-"
  } else {
    "_"
  }
}

///|
/// Join name parts with the configured separator.
pub fn join_name_parts(compose : Compose, parts : Array[String]) -> String {
  parts.join(name_separator(compose))
}

///|
/// `<project>_<parts...>`.
pub fn format_name(compose : Compose, parts : Array[String]) -> String {
  let all : Array[String] = [compose.project_name]
  all.append(parts)
  join_name_parts(compose, all)
}

///|
/// A stable, short hash used for the `config-hash` label. Not cryptographic —
/// it only has to change when the service configuration changes.
pub fn simple_hash(s : String) -> String {
  let mut h : UInt64 = 14695981039346656037UL
  for c in s {
    h = h ^ c.to_int().to_uint64()
    h = h * 1099511628211UL
  }
  let digits = "0123456789abcdef".to_array()
  let out = StringBuilder()
  let mut shift = 60
  while shift >= 0 {
    let nibble = ((h >> shift) & 15UL).to_int()
    out.write_char(digits[nibble])
    shift -= 4
  }
  out.to_string()
}

///|
/// The `config_hash` of a service, used to decide whether a container is stale.
pub fn config_hash(compose : Compose, service : @yaml.Yaml) -> String {
  ignore(compose)
  simple_hash(y_dump(service))
}

///|
/// Build the environment used for interpolation: `.env` first, then the real
/// process environment on top (so the shell wins), then the `COMPOSE_*`
/// bookkeeping variables.
fn build_environ(dotenv : Map[String, String]) -> Map[String, String] {
  let environ : Map[String, String] = Map([])
  for entry in dotenv {
    environ[entry.0] = entry.1
  }
  for entry in @env.get_env_vars() {
    environ[entry.0] = entry.1
  }
  environ
}

///|
/// Read and parse an `env_file`, caching by path so a file shared by many
/// services is read and parsed once.
pub fn compose_env_file(
  compose : Compose,
  path : String,
) -> Map[String, String] {
  match compose.env_file_cache.get(path) {
    Some(cached) => cached
    None => {
      let parsed = dotenv_to_dict(path)
      compose.env_file_cache[path] = parsed
      parsed
    }
  }
}

///|
/// Normalize a project name to the character set Podman accepts.
fn normalize_project_name(name : String) -> String {
  let out = StringBuilder(size_hint=name.length())
  for c in name {
    let keep = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '_' ||
      c == '.'
    if keep {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Split a `COMPOSE_FILE`-style list on the platform separator (`:` here).
fn split_path_list(value : String) -> Array[String] {
  let out : Array[String] = []
  for part in value.split(":") {
    let s = part.to_owned()
    if s.length() > 0 {
      out.push(s)
    }
  }
  out
}

///|
/// Load `.env` files, later files overriding earlier ones.
fn load_env_files(
  paths : Array[String],
  base : String,
) -> Map[String, String] raise Error {
  let out : Map[String, String] = Map([])
  for path in paths {
    let full = path_abspath(base, path)
    if !@fs.path_exists(full) {
      raise fail("couldn't find env file: \{full}")
    }
    for entry in dotenv_to_dict(full) {
      out[entry.0] = entry.1
    }
  }
  out
}

///|
/// Find the compose files for this invocation.
fn resolve_files(
  requested : Array[String],
  early_dotenv : Map[String, String],
) -> Array[String] raise Error {
  if requested.length() > 0 {
    return requested
  }
  match @env.get_env_var("COMPOSE_FILE") {
    Some(value) if value.length() > 0 => return split_path_list(value)
    _ => ()
  }
  match early_dotenv.get("COMPOSE_FILE") {
    Some(value) if value.length() > 0 => return split_path_list(value)
    _ => ()
  }
  // Probe the working directory, then each parent, for the default names.
  let mut dir = current_dir()
  let mut depth = 0
  while depth < 10 {
    let found : Array[String] = []
    for name in default_compose_files {
      let candidate = path_join(dir, name)
      if @fs.path_exists(candidate) {
        found.push(candidate)
      }
    }
    if found.length() > 0 {
      return found
    }
    let parent = path_dirname(dir)
    if parent == dir {
      break
    }
    dir = parent
    depth += 1
  }
  raise fail(
    "no compose.yaml, compose.yml or docker-compose.yml found; pass one with -f",
  )
}

///|
/// Read a compose document from a path, or from standard input for `-`.
async fn read_document(path : String) -> String raise Error {
  if path == "-" {
    let data = @stdio.stdin.read_all() catch {
      e => raise fail("cannot read standard input: \{error_text(e)}")
    }
    return data.text() catch {
      e => raise fail("standard input is not valid text: \{error_text(e)}")
    }
  }
  @fs.read_file_to_string(path) catch {
    e => raise fail("cannot read \{path}: \{error_text(e)}")
  }
}

///|
/// Pre-merge normalization of one service: string shorthands become lists and
/// mappings, so later merges compare like with like.
fn normalize_service(service : Map[String, @yaml.Yaml]) -> Unit {
  match service.get("build") {
    Some(build) =>
      match build {
        @yaml.Yaml::String(_) => service["build"] = y_obj([("context", build)])
        @yaml.Yaml::Map(bm) =>
          match bm.get("args") {
            Some(args) =>
              match y_map(args) {
                Some(_) => bm["args"] = y_arr_v(y_list(args))
                None => ()
              }
            None => ()
          }
        _ => ()
      }
    None => ()
  }
  for key in ["env_file", "security_opt", "volumes"] {
    match service.get(key) {
      Some(value) =>
        match value {
          @yaml.Yaml::String(_) => service[key] = y_arr_v([value])
          _ => ()
        }
      None => ()
    }
  }
  for key in ["environment", "labels"] {
    match service.get(key) {
      Some(value) =>
        match value {
          @yaml.Yaml::Map(_) => ()
          _ => service[key] = y_map_v(y_dict(value))
        }
      None => ()
    }
  }
  match service.get("depends_on") {
    Some(value) => service["depends_on"] = normalize_depends(value)
    None => ()
  }
  match service.get("extends") {
    Some(value) =>
      match value {
        @yaml.Yaml::String(s) =>
          service["extends"] = y_obj([("service", y_str_v(s))])
        _ => ()
      }
    None => ()
  }
  match service.get("secrets") {
    Some(value) =>
      match value {
        @yaml.Yaml::String(_) => service["secrets"] = y_arr_v([value])
        _ => ()
      }
    None => ()
  }
}

///|
/// Normalize every service in a document.
fn normalize_document(doc : Map[String, @yaml.Yaml]) -> Unit {
  match doc.get("services") {
    Some(services) =>
      match y_map(services) {
        Some(service_map) =>
          for entry in service_map {
            let (_name, service) = entry
            match y_map(service) {
              Some(sm) => normalize_service(sm)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
}

///|
/// Resolve `build.context` to an absolute path, once the project directory is
/// known.
fn normalize_final(doc : Map[String, @yaml.Yaml], dirname : String) -> Unit {
  let service_map = match doc.get("services").bind(y_map) {
    Some(m) => m
    None => return
  }
  for entry in service_map {
    let sm = match y_map(entry.1) {
      Some(m) => m
      None => continue
    }
    let bm = match sm.get("build").bind(y_map) {
      Some(m) => m
      None => continue
    }
    let context = match bm.get("context") {
      Some(c) => y_str_or(c, ".")
      None => "."
    }
    if !is_git_url(context) {
      bm["context"] = y_str_v(path_abspath(dirname, context))
    }
  }
}

///|
/// Whether a build context is a remote git URL rather than a local directory.
pub fn is_git_url(path : String) -> Bool {
  for
    scheme in ["git://", "http://", "https://", "ssh://", "file://", "rsync://"] {
    if path.has_prefix(scheme) {
      return true
    }
  }
  false
}

///|
/// Filter services by profile, keeping the ones with no profile or one the
/// caller asked for.
fn resolve_profiles(
  services : Map[String, @yaml.Yaml],
  requested : Array[String],
) -> Map[String, @yaml.Yaml] {
  let wanted : Map[String, Unit] = Map([])
  for p in requested {
    wanted[p] = ()
  }
  let out : Map[String, @yaml.Yaml] = Map([])
  for entry in services {
    let (name, service) = entry
    let profiles = match y_get(service, "profiles") {
      Some(p) => y_list_str(p)
      None => []
    }
    if profiles.length() == 0 {
      out[name] = service
    } else {
      for p in profiles {
        if wanted.contains(p) {
          out[name] = service
          break
        }
      }
    }
  }
  out
}

///|
/// Transitive dependencies of every service, following `depends_on`.
fn compute_deps(
  services : Map[String, @yaml.Yaml],
) -> Map[String, Array[String]] {
  let direct : Map[String, Array[String]] = Map([])
  for entry in services {
    let (name, service) = entry
    let deps : Array[String] = []
    match y_get(service, "depends_on") {
      Some(dep) =>
        match y_map(dep) {
          Some(dm) =>
            for d in dm {
              deps.push(d.0)
            }
          None => ()
        }
      None => ()
    }
    direct[name] = deps
  }
  let result : Map[String, Array[String]] = Map([])
  for entry in services {
    let (name, _) = entry
    result[name] = transitive_deps(name, direct, Map([]))
  }
  result
}

///|
/// Depth-first transitive closure with a visited set, so a cycle terminates.
fn transitive_deps(
  name : String,
  direct : Map[String, Array[String]],
  seen : Map[String, Unit],
) -> Array[String] {
  let out : Array[String] = []
  let stack : Array[String] = [name]
  while stack.length() > 0 {
    let n = stack.pop().unwrap()
    for dep in direct.get(n).unwrap_or([]) {
      if !seen.contains(dep) {
        seen[dep] = ()
        out.push(dep)
        stack.push(dep)
      }
    }
  }
  out
}

///|
/// Parse the `x-podman` extension block and the `PODMAN_COMPOSE_*` environment
/// variables, with the environment taking precedence.
fn parse_x_podman(
  doc : Map[String, @yaml.Yaml],
  environ : Map[String, String],
) -> Map[String, @yaml.Yaml] {
  let out : Map[String, @yaml.Yaml] = Map([])
  match doc.get("x-podman") {
    Some(x) =>
      match y_map(x) {
        Some(xm) =>
          for entry in xm {
            out[entry.0] = entry.1
          }
        None => ()
      }
    None => ()
  }
  for entry in environ {
    let (k, v) = entry
    if k.has_prefix("PODMAN_COMPOSE_") {
      let key = ascii_lower(k[15:].to_owned())
      if key != "provider" && key != "warning_logs" {
        out[key] = y_str_v(v)
      }
    }
  }
  out
}

///|
/// The pod name, honouring `--in-pod`, `x-podman.in_pod`, and the default of
/// one pod per project.
pub fn resolve_pod_name(compose : Compose, cli_in_pod : String?) -> String? {
  let value : String? = match cli_in_pod {
    Some(v) => Some(v)
    None =>
      match compose.x_podman.get("in_pod") {
        Some(v) => y_str(v)
        None => Some("true")
      }
  }
  match value {
    Some(v) =>
      match y_bool(y_str_v(v)) {
        Some(true) => Some("pod_" + compose.project_name)
        Some(false) => None
        None => Some(v)
      }
    None => Some("pod_" + compose.project_name)
  }
}

///|
/// Extra arguments passed to `podman pod create`.
pub fn resolve_pod_args(
  compose : Compose,
  cli_pod_args : String?,
) -> Array[String] {
  match cli_pod_args {
    Some(args) =>
      if args.length() > 0 {
        shell_split(args)
      } else {
        default_pod_args(compose)
      }
    None => default_pod_args(compose)
  }
}

///|
/// The `pod_args` from `x-podman`, or the podman-compose defaults.
fn default_pod_args(compose : Compose) -> Array[String] {
  match compose.x_podman.get("pod_args") {
    Some(v) =>
      match v {
        @yaml.Yaml::Array(_) => y_list_str(v)
        _ => shell_split(y_str_or(v, ""))
      }
    None => ["--infra=false", "--share="]
  }
}

///|
/// Split a string the way a shell would, honouring single and double quotes.
pub fn shell_split(command : String) -> Array[String] {
  let parts : Array[String] = []
  let current = StringBuilder()
  let chars = command.to_array()
  let mut i = 0
  let mut in_quote = false
  let mut quote_char : Char = '"'
  let mut has_content = false
  while i < chars.length() {
    let c = chars[i]
    if in_quote {
      if c == quote_char {
        in_quote = false
      } else {
        current.write_char(c)
      }
      has_content = true
    } else if c == '"' || c == '\'' {
      in_quote = true
      quote_char = c
      has_content = true
    } else if c == ' ' || c == '\t' || c == '\n' {
      if has_content {
        parts.push(current.to_string())
        current.reset()
        has_content = false
      }
    } else {
      current.write_char(c)
      has_content = true
    }
    i += 1
  }
  if has_content {
    parts.push(current.to_string())
  }
  parts
}

///|
/// Load a project. This reads files (and possibly standard input), so it is
/// async; everything else about the model is synchronous.
pub async fn load_compose(g : GlobalOptions) -> Compose raise Error {
  let compose = new_compose()
  let cwd = current_dir()
  // `.env` is consulted before the file list, so `COMPOSE_FILE` can live there.
  let early_dotenv = if g.env_files.length() == 0 {
    dotenv_to_dict(path_join(cwd, ".env"))
  } else {
    load_env_files(g.env_files, cwd)
  }
  let files = resolve_files(g.files, early_dotenv)
  let first = files[0]
  let dirname = if first == "-" {
    cwd
  } else {
    path_dirname(path_abspath(cwd, first))
  }
  compose.dirname = dirname
  compose.files = files
  let dotenv = if g.env_files.length() == 0 {
    dotenv_to_dict(path_join(dirname, ".env"))
  } else {
    load_env_files(g.env_files, cwd)
  }
  let environ = build_environ(dotenv)
  // Parse every document up front so the project name can be read from the
  // first one before interpolation runs.
  let documents : Array[(String, @yaml.Yaml)] = []
  for file in files {
    if file != "-" && !@fs.path_exists(file) && !@fs.path_exists(abspath(file)) {
      raise fail("missing file: \{file}")
    }
    let text = read_document(file)
    let docs = @yaml.Yaml::load_from_string(text) catch {
      e => raise fail("\{file}: \{error_text(e)}")
    }
    if docs.length() == 0 {
      continue
    }
    documents.push((file, apply_merge_keys(docs[0])))
  }
  if documents.length() == 0 {
    raise fail("no compose documents found in \{files.join(", ")}")
  }
  // Project name: -p, then COMPOSE_PROJECT_NAME, then the file's `name`, then
  // the directory.
  let dir_basename = ascii_lower(path_basename(dirname))
  let raw_name : String = match g.project_name {
    Some(name) if name.length() > 0 => name
    _ =>
      match environ.get("COMPOSE_PROJECT_NAME") {
        Some(name) if name.length() > 0 => name
        _ =>
          match y_get(documents[0].1, "name") {
            Some(n) =>
              match y_str(n) {
                Some(s) => s
                None => dir_basename
              }
            None => dir_basename
          }
      }
  }
  let project_name = normalize_project_name(
    interp_str(raw_name, environ) catch {
      _ => raw_name
    },
  )
  if project_name.length() == 0 {
    raise fail("project name \"\{raw_name}\" normalizes to empty")
  }
  compose.project_name = project_name
  environ["COMPOSE_PROJECT_NAME"] = project_name
  environ["COMPOSE_PROJECT_DIR"] = dirname
  environ["COMPOSE_FILE"] = files.join(":")
  compose.environ = environ
  // Merge the documents.
  let merged : Map[String, @yaml.Yaml] = Map([])
  for doc in documents {
    let (_file, content) = doc
    match y_map(content) {
      Some(m) => {
        normalize_document(m)
        let substituted = rec_subs(y_map_v(m), environ)
        match y_map(substituted) {
          Some(sm) => rec_merge(merged, sm)
          None => ()
        }
      }
      None =>
        raise fail("compose file does not contain a top-level object: \{doc.0}")
    }
  }
  merged.remove("version")
  // Profiles and build-context normalization.
  let services = match y_map(merged.get("services").unwrap_or(y_null())) {
    Some(s) => s
    None => Map([])
  }
  let services = resolve_profiles(services, g.profiles)
  merged["services"] = y_map_v(services)
  normalize_final(merged, dirname)
  compose.services = services
  compose.merged_yaml = y_map_v(merged)
  compose.x_podman = parse_x_podman(merged, environ)
  compose.pod_args = resolve_pod_args(compose, g.pod_args)
  // Networks.
  let nets = match y_map(merged.get("networks").unwrap_or(y_null())) {
    Some(n) => n
    None => Map([])
  }
  let docker_compat = x_flag(compose, "docker_compose_compat")
  if docker_compat {
    if !nets.contains("default") {
      nets["default"] = y_null()
    }
    compose.default_net = Some("default")
  } else if nets.length() == 0 {
    nets["default"] = y_null()
    compose.default_net = Some("default")
  } else if nets.length() == 1 {
    for entry in nets {
      compose.default_net = Some(entry.0)
    }
  } else if nets.contains("default") {
    compose.default_net = Some("default")
  } else {
    compose.default_net = None
  }
  compose.networks = nets
  compose.vols = match y_map(merged.get("volumes").unwrap_or(y_null())) {
    Some(v) => v
    None => Map([])
  }
  compose.declared_secrets = match
    y_map(merged.get("secrets").unwrap_or(y_null())) {
    Some(s) => s
    None => Map([])
  }
  // Containers.
  let pod_name = resolve_pod_name(compose, g.in_pod)
  compose.pods = match pod_name {
    Some(name) => [name]
    None => []
  }
  let deps = compute_deps(services)
  compose.deps = deps
  let names_by_service : Map[String, Array[String]] = Map([])
  let containers : Array[@yaml.Yaml] = []
  let base_labels = compose_labels(compose)
  for entry in services {
    let (service_name, service) = entry
    let replicas = service_replicas(service)
    // The config hash depends only on the service, not on the replica number,
    // so compute it once instead of serializing the service per replica.
    let service_hash = config_hash(compose, service)
    let names : Array[String] = []
    for num in 1..<=replicas {
      let name0 = format_name(compose, [service_name, num.to_string()])
      let name = if num == 1 {
        match y_get(service, "container_name") {
          Some(cn) =>
            match y_str(cn) {
              Some(s) if s.length() > 0 => s
              _ => name0
            }
          None => name0
        }
      } else {
        name0
      }
      names.push(name)
      containers.push(
        make_container(
          compose, service_name, service, name, num, pod_name, deps, base_labels,
          service_hash,
        ),
      )
    }
    names_by_service[service_name] = names
  }
  compose.container_names_by_service = names_by_service
  // Create dependencies before the services that need them.
  containers.sort_by(fn(a, b) {
    let da = deps
      .get(y_str_or(y_get(a, "_service").unwrap_or(y_null()), ""))
      .unwrap_or([])
      .length()
    let db = deps
      .get(y_str_or(y_get(b, "_service").unwrap_or(y_null()), ""))
      .unwrap_or([])
      .length()
    da - db
  })
  compose.containers = containers
  let by_name : Map[String, @yaml.Yaml] = Map([])
  for c in containers {
    match y_get(c, "name") {
      Some(n) =>
        match y_str(n) {
          Some(s) => by_name[s] = c
          None => ()
        }
      None => ()
    }
  }
  compose.container_by_name = by_name
  compose
}

///|
/// How many containers a service wants. `scale` wins over `deploy.replicas`.
fn service_replicas(service : @yaml.Yaml) -> Int32 {
  match y_get(service, "scale") {
    Some(s) =>
      match y_int(s) {
        Some(n) if n > 0 => return n
        _ => ()
      }
    None => ()
  }
  match y_get(service, "deploy") {
    Some(deploy) =>
      match y_get(deploy, "replicas") {
        Some(r) =>
          match y_int(r) {
            Some(n) if n > 0 => n
            _ => 1
          }
        None => 1
      }
    None => 1
  }
}

///|
/// Expand one service into one container description: the service's own fields
/// plus the name, pod and labels the commands need.
fn make_container(
  compose : Compose,
  service_name : String,
  service : @yaml.Yaml,
  name : String,
  num : Int32,
  pod_name : String?,
  deps : Map[String, Array[String]],
  base_labels : Array[String],
  config_hash_value : String,
) -> @yaml.Yaml {
  let out : Map[String, @yaml.Yaml] = Map([])
  match y_map(service) {
    Some(sm) =>
      for entry in sm {
        out[entry.0] = y_clone(entry.1)
      }
    None => ()
  }
  match pod_name {
    Some(pod) => out["pod"] = y_str_v(pod)
    None => ()
  }
  out["name"] = y_str_v(name)
  out["num"] = y_int_v(num)
  out["service_name"] = y_str_v(service_name)
  out["_service"] = y_str_v(service_name)
  out["_project"] = y_str_v(compose.project_name)
  if !out.contains("image") {
    out["image"] = y_str_v(format_name(compose, [service_name]))
  }
  let labels = y_list(out.get("labels").unwrap_or(y_null()))
  for label in base_labels {
    labels.push(y_str_v(label))
  }
  labels.push(y_str_v("io.podman.compose.config-hash=" + config_hash_value))
  labels.push(y_str_v("com.docker.compose.container-number=" + num.to_string()))
  labels.push(y_str_v("io.podman.compose.service=" + service_name))
  labels.push(y_str_v("com.docker.compose.service=" + service_name))
  out["labels"] = y_arr_v(labels)
  let dep_names = deps.get(service_name).unwrap_or([])
  let dep_values : Array[@yaml.Yaml] = []
  for d in dep_names {
    dep_values.push(y_str_v(d))
  }
  out["_deps"] = y_arr_v(dep_values)
  y_map_v(out)
}
