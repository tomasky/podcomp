///|
/// The subcommands. Each one is a thin translation from the loaded project to
/// a sequence of `podman` invocations.

///|
/// Services to skip: everything not named, unless it is a dependency (for `up`)
/// or a dependent (for `down`) of a named one.
fn get_excluded(
  compose : Compose,
  services : Array[String],
  with_deps : Bool,
  with_dependents : Bool,
) -> Map[String, Unit] {
  let excluded : Map[String, Unit] = Map([])
  if services.length() == 0 {
    return excluded
  }
  for entry in compose.services {
    excluded[entry.0] = ()
  }
  for s in services {
    if compose.services.contains(s) {
      if with_deps {
        for d in service_deps(compose, s) {
          excluded.remove(d)
        }
      }
      if with_dependents {
        for d in service_dependents(compose, s) {
          excluded.remove(d)
        }
      }
    }
    excluded.remove(s)
  }
  excluded
}

///|
/// The transitive dependencies recorded for a service.
fn service_deps(compose : Compose, name : String) -> Array[String] {
  compose.deps.get(name).unwrap_or([])
}

///|
/// Services that (transitively) depend on `name`.
fn service_dependents(compose : Compose, name : String) -> Array[String] {
  let out : Array[String] = []
  for entry in compose.services {
    if service_deps(compose, entry.0).contains(name) {
      out.push(entry.0)
    }
  }
  out
}

///|
/// Fail when a named service does not exist.
fn assert_services(
  compose : Compose,
  services : Array[String],
) -> Unit raise Error {
  for s in services {
    if !compose.services.contains(s) {
      raise fail("no such service: \{s}")
    }
  }
}

///|
/// The container names for a set of services, in service order.
fn container_names_for(
  compose : Compose,
  services : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for s in services {
    match compose.container_names_by_service.get(s) {
      Some(names) =>
        for n in names {
          out.push(n)
        }
      None => ()
    }
  }
  out
}

///|
/// Reverse a copy of an array.
fn reversed(a : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut i = a.length()
  while i > 0 {
    i -= 1
    out.push(a[i])
  }
  out
}

///|
/// `podcomp version`
pub async fn cmd_version(podman : Podman, args : CommandArgs) -> Unit {
  if args.short {
    println(version)
    return
  }
  if args.format is Some("json") {
    println("{\"version\":\"" + version + "\"}")
    return
  }
  println("podcomp version " + version)
  match podman_version(podman) {
    Some(v) => println("podman version " + v)
    None => ()
  }
}

///|
/// `podcomp config`
pub fn cmd_config(compose : Compose, args : CommandArgs) -> Unit {
  if args.services_flag {
    if !args.quiet {
      for entry in compose.services {
        println(entry.0)
      }
    }
    return
  }
  if !args.quiet {
    println(y_dump(compose.merged_yaml))
  }
}

///|
/// `podman network ls` filtered to this project.
async fn network_ls(compose : Compose, podman : Podman) -> Array[String] {
  let out = podman_output(podman, "network", [
    "ls",
    "--noheading",
    "--filter",
    "label=io.podman.compose.project=" + compose.project_name,
    "--format",
    "{{.Name}}",
  ]) catch {
    _ => return []
  }
  lines(out)
}

///|
/// `podman volume ls` filtered to this project.
async fn volume_ls(compose : Compose, podman : Podman) -> Array[String] {
  let out = podman_output(podman, "volume", [
    "ls",
    "--noheading",
    "--filter",
    "label=io.podman.compose.project=" + compose.project_name,
    "--format",
    "{{.Name}}",
  ]) catch {
    _ => return []
  }
  lines(out)
}

///|
/// Non-empty lines of some command output.
fn lines(text : String) -> Array[String] {
  let out : Array[String] = []
  for line in text.split("\n") {
    let s = line.trim().to_owned()
    if s.length() > 0 {
      out.push(s)
    }
  }
  out
}

///|
/// `podman pod exists`, then create the pod if missing.
async fn create_pods(compose : Compose, podman : Podman) -> Unit {
  for pod in compose.pods {
    match podman_try_output(podman, "pod", ["exists", pod]) {
      Some(_) => continue
      None => ()
    }
    let args : Array[String] = ["create", "--name=" + pod]
    args.append(compose.pod_args)
    ignore(podman_run(podman, "pod", args))
  }
}

///|
/// The containers of the named services, or every container when no service
/// is named.
fn containers_for(
  compose : Compose,
  services : Array[String],
) -> Array[@yaml.Yaml] {
  if services.length() == 0 {
    return compose.containers
  }
  let out : Array[@yaml.Yaml] = []
  for cnt in compose.containers {
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if services.contains(service) {
      out.push(cnt)
    }
  }
  out
}

///|
/// The distinct images used by a set of containers, in first-seen order.
fn unique_images(containers : Array[@yaml.Yaml]) -> Array[String] {
  let seen : Map[String, Unit] = Map([])
  let out : Array[String] = []
  for cnt in containers {
    match y_get(cnt, "image").bind(y_str) {
      Some(img) =>
        if img.length() > 0 && !seen.contains(img) {
          seen[img] = ()
          out.push(img)
        }
      None => ()
    }
  }
  out
}

///|
/// Pull the images a set of containers uses.
async fn pull_images(
  compose : Compose,
  podman : Podman,
  containers : Array[@yaml.Yaml],
) -> Int32 {
  ignore(compose)
  let mut status = 0
  for img in unique_images(containers) {
    let code = podman_run(podman, "pull", [img])
    if code != 0 {
      status = code
    }
  }
  status
}

///|
/// The `podman build` argument list for a container.
fn build_args_for(
  compose : Compose,
  cnt : @yaml.Yaml,
  args : CommandArgs,
) -> Array[String] {
  let out : Array[String] = []
  let build = y_get(cnt, "build").unwrap_or(y_null())
  let context = match y_get(build, "context") {
    Some(c) => y_str_or(c, ".")
    None => "."
  }
  let image = y_str_or(y_get(cnt, "image").unwrap_or(y_null()), "")
  let dockerfile : String? = match y_get(build, "dockerfile") {
    Some(d) => y_str(d)
    None => None
  }
  match dockerfile {
    Some(name) => {
      out.push("-f")
      out.push(path_join(context, name))
    }
    None =>
      for alt in ["Containerfile", "Dockerfile", "dockerfile"] {
        let candidate = path_join(context, alt)
        if @fs.path_exists(candidate) {
          out.push("-f")
          out.push(candidate)
          break
        }
      }
  }
  out.push("-t")
  out.push(image)
  match y_get(cnt, "platform") {
    Some(p) =>
      match y_str(p) {
        Some(s) => {
          out.push("--platform")
          out.push(s)
        }
        None => ()
      }
    None => ()
  }
  match y_get(build, "target") {
    Some(t) =>
      match y_str(t) {
        Some(s) => {
          out.push("--target")
          out.push(s)
        }
        None => ()
      }
    None => ()
  }
  for build_arg in y_list_str(y_get(build, "args").unwrap_or(y_null())) {
    out.push("--build-arg")
    out.push(build_arg)
  }
  for build_arg in args.build_arg {
    out.push("--build-arg")
    out.push(build_arg)
  }
  match y_get(build, "labels") {
    Some(labels) =>
      for label in y_env_list(labels) {
        out.push("--label")
        out.push(label)
      }
    None => ()
  }
  for cache in y_list_str(y_get(build, "cache_from").unwrap_or(y_null())) {
    out.push("--cache-from")
    out.push(cache)
  }
  for cache in y_list_str(y_get(build, "cache_to").unwrap_or(y_null())) {
    out.push("--cache-to")
    out.push(cache)
  }
  if args.no_cache {
    out.push("--no-cache")
  }
  match args.pull {
    Some(policy) => out.push("--pull=" + policy)
    None => ()
  }
  out.push(context)
  ignore(compose)
  out
}

///|
/// `podcomp build`
pub async fn cmd_build(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  assert_services(compose, args.services)
  do_build(compose, podman, args, args.services, false)
}

///|
/// Build the images of the named services (or all of them). `if_not_exists`
/// skips a service whose image is already present, which is what `up` wants
/// unless it was passed `--build`.
async fn do_build(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
  services : Array[String],
  if_not_exists : Bool,
) -> Int32 raise Error {
  let wanted : Map[String, Unit] = Map([])
  for s in services {
    wanted[s] = ()
  }
  let mut status = 0
  for cnt in compose.containers {
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if wanted.length() > 0 && !wanted.contains(service) {
      continue
    }
    match y_get(cnt, "build") {
      Some(build) =>
        match build {
          @yaml.Yaml::Null | @yaml.Yaml::BadValue => ()
          _ => {
            let image = y_str_or(y_get(cnt, "image").unwrap_or(y_null()), "")
            let mut skip = false
            if if_not_exists && image.length() > 0 {
              match
                podman_try_output(podman, "inspect", [
                  "-t", "image", "-f", "{{.Id}}", image,
                ]) {
                Some(_) => skip = true
                None => ()
              }
            }
            if !skip {
              let cargs = build_args_for(compose, cnt, args)
              let code = podman_run(podman, "build", cargs)
              if code != 0 {
                status = code
              }
            }
          }
        }
      None => ()
    }
  }
  status
}

///|
/// A container that already exists for this project, as reported by
/// `podman ps -a`.
priv struct ExistingContainer {
  service : String
  config_hash : String
  image_id : String
}

///|
/// Containers that already exist for this project, keyed by name.
///
/// The reference asks podman for JSON; a tab-separated format string carries
/// the same fields without pulling in a JSON dependency. When `ps` fails the
/// map is empty, which means "create everything" — the behaviour before this
/// check existed.
async fn existing_containers(
  compose : Compose,
  podman : Podman,
) -> Map[String, ExistingContainer] {
  let out : Map[String, ExistingContainer] = Map([])
  let format = "{{.Names}}\t{{.Label \"io.podman.compose.service\"}}\t{{.Label \"io.podman.compose.config-hash\"}}\t{{.ImageID}}"
  let text = podman_try_output(podman, "ps", [
    "--filter",
    "label=io.podman.compose.project=" + compose.project_name,
    "-a",
    "--format",
    format,
  ])
  match text {
    None => ()
    Some(raw) =>
      for line in raw.split("\n") {
        let fields = line.to_owned().split("\t").to_array()
        if fields.length() < 4 {
          continue
        }
        let name = fields[0].to_owned()
        if name.length() == 0 {
          continue
        }
        out[name] = {
          service: fields[1].to_owned(),
          config_hash: fields[2].to_owned(),
          image_id: fields[3].trim().to_owned(),
        }
      }
  }
  out
}

///|
/// The `podman stop` timeout for a container: `--timeout`, else the service's
/// `stop_grace_period`, else 10 seconds, as in the reference.
fn stop_timeout_args(cnt : @yaml.Yaml, args : CommandArgs) -> Array[String] {
  match args.timeout {
    Some(t) => ["-t", t.to_string()]
    None =>
      match y_get(cnt, "stop_grace_period").bind(y_str) {
        Some(s) =>
          match str_to_seconds(s) {
            Some(seconds) => ["-t", seconds.to_string()]
            None => ["-t", "10"]
          }
        None => ["-t", "10"]
      }
  }
}

///|
/// The service's `image`, when it has one.
fn service_image(compose : Compose, service : String) -> String? {
  match compose.services.get(service) {
    Some(s) => y_get(s, "image").bind(y_str)
    None => None
  }
}

///|
/// `podcomp up`
pub async fn cmd_up(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  assert_services(compose, args.services)
  let excluded = get_excluded(compose, args.services, true, false)
  if args.force_recreate && args.no_recreate {
    eprintln(
      "podcomp: cannot use --force-recreate and --no-recreate at the same time",
    )
    return 1
  }
  if !args.no_build {
    let build_services : Array[String] = []
    for cnt in compose.containers {
      let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
      if !excluded.contains(service) {
        match y_get(cnt, "build") {
          Some(build) =>
            match build {
              @yaml.Yaml::Null | @yaml.Yaml::BadValue => ()
              _ =>
                if !build_services.contains(service) {
                  build_services.push(service)
                }
            }
          None => ()
        }
      }
    }
    if build_services.length() > 0 {
      ignore(do_build(compose, podman, args, build_services, !args.build))
    }
  }
  // Pull before creating, but only on podman >= 5.6, which supports the pull
  // policy flag. Older podman pulls implicitly inside `create`.
  let can_prepull = match podman_version(podman) {
    Some(v) => version_at_least(v, "5.6.0")
    None => false
  }
  if can_prepull {
    let to_pull : Array[@yaml.Yaml] = []
    for cnt in compose.containers {
      let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
      if !excluded.contains(service) {
        to_pull.push(cnt)
      }
    }
    let pull_code = pull_images(compose, podman, to_pull)
    if pull_code != 0 {
      return pull_code
    }
  }
  // Containers that already exist are reused; the reference only recreates
  // them when asked to, when their configuration changed, or when their image
  // changed. Without this, a second `up` would fail with "the container name
  // ... is already in use" instead of starting the existing container.
  let existing = existing_containers(compose, podman)
  let recreate : Map[String, Unit] = Map([])
  if existing.length() > 0 && !args.no_recreate {
    // Local image ids, one `inspect` per distinct image reference.
    let image_ids : Map[String, String] = Map([])
    for entry in existing {
      let c = entry.1
      if excluded.contains(c.service) || !compose.services.contains(c.service) {
        continue
      }
      match service_image(compose, c.service) {
        Some(image) =>
          if !image_ids.contains(image) {
            match
              podman_try_output(podman, "inspect", [
                "-t", "image", "-f", "{{.Id}}", image,
              ]) {
              Some(id) => image_ids[image] = id.trim().to_owned()
              None => ()
            }
          }
        None => ()
      }
    }
    for entry in existing {
      let c = entry.1
      if excluded.contains(c.service) || !compose.services.contains(c.service) {
        continue
      }
      let force_this = args.force_recreate &&
        (args.services.length() == 0 || args.services.contains(c.service))
      let image_changed = match service_image(compose, c.service) {
        Some(image) =>
          match image_ids.get(image) {
            Some(local_id) => local_id.length() > 0 && local_id != c.image_id
            None => false
          }
        None => false
      }
      let hash_changed = match compose.services.get(c.service) {
        Some(service) => c.config_hash != config_hash(compose, service)
        None => false
      }
      if force_this || image_changed || hash_changed {
        recreate[c.service] = ()
        // A running dependent cannot stay attached to a container that is
        // about to be replaced, so recreate those too.
        for dep in service_dependents(compose, c.service) {
          recreate[dep] = ()
        }
      }
    }
  }
  if recreate.length() > 0 {
    let stale : Array[String] = []
    for cnt in compose.containers.rev() {
      let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
      let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
      if recreate.contains(service) &&
        !excluded.contains(service) &&
        existing.contains(name) {
        stale.push(name)
      }
    }
    for cnt in compose.containers.rev() {
      let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
      if stale.contains(name) {
        ignore(
          podman_run(podman, "stop", stop_timeout_args(cnt, args) + [name]),
        )
      }
    }
    for name in stale {
      ignore(podman_run(podman, "rm", [name]))
    }
  }
  create_pods(compose, podman)
  // Resolve the containers that take part once, then ensure the networks and
  // named volumes they share exist with one probe per distinct name.
  let targets : Array[@yaml.Yaml] = []
  for cnt in compose.containers {
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if !excluded.contains(service) {
      targets.push(cnt)
    }
  }
  assert_networks_and_volumes(compose, podman, targets)
  let mut status = 0
  for cnt in targets {
    let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if existing.contains(name) && !recreate.contains(service) {
      continue
    }
    let cargs = container_to_args(compose, cnt, false, args.no_deps)
    let code = podman_run(podman, "create", cargs)
    if code != 0 {
      status = code
    }
  }
  if args.no_start {
    return status
  }
  if args.detach || args.wait {
    for cnt in targets {
      let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
      let code = podman_run(podman, "start", [name])
      if code != 0 {
        status = code
      }
    }
    if args.wait {
      wait_for_running(compose, podman)
    }
    return status
  }
  // Attached: start every container with `-a` concurrently.
  let codes : Array[Int32] = []
  let names : Array[String] = []
  for cnt in targets {
    names.push(y_str_or(y_get(cnt, "name").unwrap_or(y_null()), ""))
  }
  @async.with_task_group(group => {
    for name in names {
      group.spawn_bg(no_wait=true, () => {
        let code = podman_run(podman, "start", ["-a", name])
        codes.push(code)
      })
    }
  })
  for code in codes {
    if code != 0 {
      status = code
    }
  }
  status
}

///|
/// `podman wait --condition=running` for every container that has no
/// healthcheck, then `healthy` for the rest.
async fn wait_for_running(compose : Compose, podman : Podman) -> Unit {
  let plain : Array[String] = []
  let healthy : Array[String] = []
  for cnt in compose.containers {
    let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
    match y_get(cnt, "healthcheck") {
      Some(_) => healthy.push(name)
      None => plain.push(name)
    }
  }
  if plain.length() > 0 {
    let cargs : Array[String] = ["--condition=running", "--ignore"]
    cargs.append(plain)
    ignore(podman_run(podman, "wait", cargs))
  }
  if healthy.length() > 0 {
    let cargs : Array[String] = ["--condition=healthy", "--ignore"]
    cargs.append(healthy)
    ignore(podman_run(podman, "wait", cargs))
  }
}

///|
/// `podcomp down`
pub async fn cmd_down(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 {
  let excluded = get_excluded(compose, args.services, false, true)
  let mut status = 0
  // Stop dependents before their dependencies, the way the reference reverses
  // the container list; then remove them all.
  let containers = compose.containers.rev()
  for cnt in containers {
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if excluded.contains(service) {
      continue
    }
    let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
    let code = podman_run(podman, "stop", stop_timeout_args(cnt, args) + [name])
    if code != 0 {
      status = code
    }
  }
  for cnt in containers {
    let service = y_str_or(y_get(cnt, "_service").unwrap_or(y_null()), "")
    if excluded.contains(service) {
      continue
    }
    let name = y_str_or(y_get(cnt, "name").unwrap_or(y_null()), "")
    ignore(podman_run(podman, "rm", [name]))
  }
  if args.volumes {
    for volume in volume_ls(compose, podman) {
      ignore(podman_run(podman, "volume", ["rm", volume]))
    }
  }
  if excluded.is_empty() {
    for pod in compose.pods {
      ignore(podman_run(podman, "pod", ["rm", pod]))
    }
    for network in network_ls(compose, podman) {
      ignore(podman_run(podman, "network", ["rm", network]))
    }
  }
  status
}

///|
/// `podcomp ps`
pub async fn cmd_ps(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 {
  let cargs : Array[String] = [
    "-a",
    "--filter",
    "label=io.podman.compose.project=" + compose.project_name,
  ]
  if args.quiet {
    cargs.push("--format")
    cargs.push("{{.ID}}")
  } else {
    match args.format {
      Some(f) => {
        cargs.push("--format")
        cargs.push(f)
      }
      None => ()
    }
  }
  podman_run(podman, "ps", cargs)
}

///|
/// `podcomp logs`
pub async fn cmd_logs(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let services = if args.services.length() == 0 {
    keys_of(compose.container_names_by_service)
  } else {
    args.services
  }
  assert_services(compose, services)
  let cargs : Array[String] = []
  if args.follow {
    cargs.push("-f")
  }
  if args.names {
    cargs.push("-n")
  }
  if !args.no_color {
    cargs.push("--color")
  }
  match args.since {
    Some(s) => {
      cargs.push("--since")
      cargs.push(s)
    }
    None => ()
  }
  match args.tail {
    Some(t) =>
      if t != "all" {
        cargs.push("--tail")
        cargs.push(t)
      }
    None => ()
  }
  if args.timestamps {
    cargs.push("-t")
  }
  match args.until {
    Some(u) => {
      cargs.push("--until")
      cargs.push(u)
    }
    None => ()
  }
  for name in container_names_for(compose, services) {
    cargs.push(name)
  }
  podman_run(podman, "logs", cargs)
}

///|
fn keys_of(m : Map[String, Array[String]]) -> Array[String] {
  let out : Array[String] = []
  for entry in m {
    out.push(entry.0)
  }
  out
}

///|
/// Start, stop or restart the named services (or all of them).
async fn transfer_service_status(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
  action : String,
) -> Int32 raise Error {
  let services = if args.services.length() == 0 {
    keys_of(compose.container_names_by_service)
  } else {
    args.services
  }
  assert_services(compose, services)
  let mut targets = container_names_for(compose, services)
  if action == "stop" || action == "restart" {
    targets = reversed(targets)
  }
  let mut status = 0
  for target in targets {
    let cargs : Array[String] = []
    if action != "start" {
      match args.timeout {
        Some(t) => {
          cargs.push("-t")
          cargs.push(t.to_string())
        }
        None => ()
      }
    }
    cargs.push(target)
    let code = podman_run(podman, action, cargs)
    if code != 0 {
      status = code
    }
  }
  status
}

///|
/// `podcomp start`
pub async fn cmd_start(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let status = transfer_service_status(compose, podman, args, "start")
  if args.wait {
    wait_for_running(compose, podman)
  }
  status
}

///|
/// `podcomp stop`
pub async fn cmd_stop(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  transfer_service_status(compose, podman, args, "stop")
}

///|
/// `podcomp restart`
pub async fn cmd_restart(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  transfer_service_status(compose, podman, args, "restart")
}

///|
/// `podcomp kill`
pub async fn cmd_kill(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  if args.services.length() == 0 && !args.all {
    raise fail(
      "you must provide at least one service name or use --all to kill all services",
    )
  }
  let services = if args.all {
    keys_of(compose.container_names_by_service)
  } else {
    args.services
  }
  assert_services(compose, services)
  let cargs : Array[String] = []
  match args.signal {
    Some(s) => {
      cargs.push("--signal")
      cargs.push(s)
    }
    None => ()
  }
  for name in container_names_for(compose, services) {
    cargs.push(name)
  }
  podman_run(podman, "kill", cargs)
}

///|
/// `podcomp pause` / `podcomp unpause`
pub async fn cmd_pause_unpause(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
  action : String,
) -> Int32 raise Error {
  let services = if args.services.length() == 0 {
    keys_of(compose.container_names_by_service)
  } else {
    args.services
  }
  assert_services(compose, services)
  podman_run(podman, action, container_names_for(compose, services))
}

///|
/// `podcomp pull`
pub async fn cmd_pull(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  assert_services(compose, args.services)
  pull_images(compose, podman, containers_for(compose, args.services))
}

///|
/// `podcomp rm`
pub async fn cmd_rm(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let services = if args.services.length() == 0 {
    keys_of(compose.container_names_by_service)
  } else {
    args.services
  }
  assert_services(compose, services)
  let mut status = 0
  for name in container_names_for(compose, services) {
    let code = podman_run(podman, "rm", [name])
    if code != 0 {
      status = code
    }
  }
  status
}

///|
/// `podcomp exec`
pub async fn cmd_exec(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let service = match first_of(args.services) {
    Some(s) => s
    None => raise fail("exec requires a service name")
  }
  assert_services(compose, [service])
  let names = compose.container_names_by_service.get(service).unwrap_or([])
  if args.index < 1 || args.index > names.length() {
    raise fail("no container for service \{service} at index \{args.index}")
  }
  let name = names[args.index - 1]
  let cargs : Array[String] = if args.detach {
    ["--detach"]
  } else {
    ["--interactive"]
  }
  if args.privileged {
    cargs.push("--privileged")
  }
  match args.user {
    Some(u) => {
      cargs.push("--user")
      cargs.push(u)
    }
    None => ()
  }
  match args.workdir {
    Some(w) => {
      cargs.push("--workdir")
      cargs.push(w)
    }
    None => ()
  }
  if !args.detach && !args.no_tty {
    cargs.push("--tty")
  }
  for e in args.env {
    cargs.push("--env")
    cargs.push(e)
  }
  cargs.push(name)
  cargs.append(args.cnt_command)
  podman_run(podman, "exec", cargs)
}

///|
/// `podcomp run`
pub async fn cmd_run(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let service = match first_of(args.services) {
    Some(s) => s
    None => raise fail("run requires a service name")
  }
  assert_services(compose, [service])
  create_pods(compose, podman)
  let names = compose.container_names_by_service.get(service).unwrap_or([])
  if names.length() == 0 {
    raise fail("no container for service \{service}")
  }
  let base = compose.container_by_name.get(names[0]).unwrap_or(y_null())
  // One-off containers get a fresh name and command.
  let sm = y_map(y_clone(base)).unwrap()
  let suffix = simple_hash(current_dir() + args.services.join(","))
  sm["name"] = y_str_v(format_name(compose, [service, "tmp" + suffix]))
  match args.entrypoint {
    Some(e) => sm["entrypoint"] = y_str_v(e)
    None => ()
  }
  match args.user {
    Some(u) => sm["user"] = y_str_v(u)
    None => ()
  }
  match args.workdir {
    Some(w) => sm["working_dir"] = y_str_v(w)
    None => ()
  }
  if args.cnt_command.length() > 0 {
    let values : Array[@yaml.Yaml] = []
    for part in args.cnt_command {
      values.push(y_str_v(part))
    }
    sm["command"] = y_arr_v(values)
  }
  sm["tty"] = y_bool_v(!args.no_tty)
  let cnt = y_map_v(sm)
  let cargs = container_to_args(compose, cnt, args.detach, args.no_deps)
  if !args.detach {
    // Interactive by default.
    let with_stdin : Array[String] = []
    with_stdin.push("-i")
    with_stdin.append(cargs)
    cargs.clear()
    cargs.append(with_stdin)
  }
  // NOTE: the reference does not create networks/volumes here either, so a
  // `run` against a project that was never brought up will fail in podman.
  podman_run(podman, "run", cargs)
}

///|
/// `podcomp images`
pub async fn cmd_images(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  assert_services(compose, args.services)
  let mut status = 0
  for img in unique_images(containers_for(compose, args.services)) {
    let cargs : Array[String] = []
    if args.quiet {
      cargs.push("--quiet")
    }
    cargs.push(img)
    let code = podman_run(podman, "images", cargs)
    if code != 0 {
      status = code
    }
  }
  status
}

///|
/// `podcomp port`
pub async fn cmd_port(
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int32 raise Error {
  let service = match first_of(args.services) {
    Some(s) => s
    None => raise fail("port requires a service name")
  }
  assert_services(compose, [service])
  let names = compose.container_names_by_service.get(service).unwrap_or([])
  if args.index < 1 || args.index > names.length() {
    raise fail("no container for service \{service} at index \{args.index}")
  }
  let name = names[args.index - 1]
  let output = podman_output(podman, "inspect", [name])
  let needle = args.private_port.to_string() + "/" + args.protocol
  // The inspect output is JSON; the port mapping is found by locating the
  // private port key and reading the HostPort that follows.
  match find_host_port(output, needle) {
    Some(port) => {
      println(port)
      0
    }
    None => raise fail("no published port \{needle} for \{service}")
  }
}

///|
/// A very small JSON walk: find `"<port>": [ ... "HostPort": "NNN" ... ]`.
fn find_host_port(text : String, needle : String) -> String? {
  let key = "\"" + needle + "\""
  match text.find(key) {
    Some(index) => {
      let rest = text[index:].to_owned()
      match rest.find("HostPort") {
        Some(hp) => {
          let tail = rest[hp:].to_owned()
          match tail.find("\"") {
            Some(_) => {
              let after = tail[9:].to_owned()
              match after.find("\"") {
                Some(open) => {
                  let value = after[open + 1:].to_owned()
                  match value.find("\"") {
                    Some(close) => Some(value[:close].to_owned())
                    None => None
                  }
                }
                None => None
              }
            }
            None => None
          }
        }
        None => None
      }
    }
    None => None
  }
}

///|
/// The first element of an array, if any.
fn first_of(a : Array[String]) -> String? {
  if a.length() == 0 {
    None
  } else {
    Some(a[0])
  }
}
