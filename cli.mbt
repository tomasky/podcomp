///|
/// The command line: parse the global options, parse the subcommand's options,
/// load the project, and dispatch.

///|
/// The argument list without the program name.
fn tail(args : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for i in 1..<args.length() {
    out.push(args[i])
  }
  out
}

///|
/// Whether a token names a value-taking global option.
fn is_global_value_flag(t : String) -> Bool {
  t == "-f" ||
  t == "--file" ||
  t == "-p" ||
  t == "--project-name" ||
  t == "--profile" ||
  t == "--env-file" ||
  t == "--podman-path" ||
  t == "--podman-args" ||
  t == "--in-pod" ||
  t == "--pod-args"
}

///|
/// Parse the global options up to the subcommand name. Returns the options, the
/// command, and the command's own arguments.
fn parse_global(
  tokens : Array[String],
) -> (GlobalOptions, String, Array[String]) raise Error {
  let g = new_global_options()
  let mut command = ""
  let rest : Array[String] = []
  let mut version_flag = false
  let mut help_flag = false
  let mut i = 0
  while i < tokens.length() {
    let t = tokens[i]
    if command.length() > 0 {
      rest.push(t)
      i += 1
      continue
    }
    if t == "--" {
      i += 1
      if i < tokens.length() {
        command = tokens[i]
        i += 1
      }
      continue
    }
    if t == "-v" || t == "--version" {
      version_flag = true
      i += 1
      continue
    }
    if t == "-h" || t == "--help" {
      help_flag = true
      i += 1
      continue
    }
    if t == "--dry-run" {
      g.dry_run = true
      i += 1
      continue
    }
    if t == "--verbose" {
      g.verbose = true
      i += 1
      continue
    }
    if t == "--no-ansi" {
      g.no_ansi = true
      i += 1
      continue
    }
    if t == "--no-cleanup" {
      g.no_cleanup = true
      i += 1
      continue
    }
    if t.has_prefix("--podman-") && t.has_suffix("-args") {
      // `--podman-<sub>-args VALUE` injects arguments into `podman <sub>`.
      let sub = t[9:t.length() - 5].to_owned()
      if i + 1 >= tokens.length() {
        raise fail("\{t} requires a value")
      }
      let extra = g.podman_cmd_args.get(sub).unwrap_or([])
      extra.push(tokens[i + 1])
      g.podman_cmd_args[sub] = extra
      i += 2
      continue
    }
    if t.has_prefix("--") {
      match split_long(t) {
        Some(pair) => {
          let (name, inline_value) = pair
          let value = match inline_value {
            Some(v) => v
            None => {
              if i + 1 >= tokens.length() {
                raise fail("\{name} requires a value")
              }
              i += 1
              tokens[i]
            }
          }
          match name {
            "--file" => g.files.push(value)
            "--project-name" => g.project_name = Some(value)
            "--profile" => g.profiles.push(value)
            "--env-file" => g.env_files.push(value)
            "--podman-path" => g.podman_path = value
            "--podman-args" => g.podman_args.push(value)
            "--in-pod" => g.in_pod = Some(value)
            "--pod-args" => g.pod_args = Some(value)
            _ => raise fail("unknown option: \{name} (try --help)")
          }
          i += 1
          continue
        }
        None => raise fail("unknown option: \{t} (try --help)")
      }
    }
    if t.has_prefix("-") && t.length() > 1 {
      // Short value-taking global options.
      let name = t
      if is_global_value_flag(name) {
        if i + 1 >= tokens.length() {
          raise fail("\{name} requires a value")
        }
        let value = tokens[i + 1]
        match name {
          "-f" => g.files.push(value)
          "-p" => g.project_name = Some(value)
          _ => ()
        }
        i += 2
        continue
      }
      raise fail("unknown option: \{t} (try --help)")
    }
    command = t
    i += 1
  }
  if command.length() == 0 {
    if version_flag {
      command = "version"
    } else if help_flag {
      command = "help"
    }
  }
  if help_flag {
    command = "help"
  }
  (g, command, rest)
}

///|
/// Split `--name=value` into `("--name", Some("value"))`, or `("--name", None)`.
fn split_long(t : String) -> (String, String?)? {
  match t.split_once("=") {
    Some(pair) => Some((pair.0.to_owned(), Some(pair.1.to_owned())))
    None => Some((t, None))
  }
}

///|
/// Parse the subcommand's own options.
fn parse_command(
  command : String,
  tokens : Array[String],
) -> CommandArgs raise Error {
  let args = new_command_args()
  let mut i = 0
  // For `run` and `exec`, everything after the service name belongs to the
  // command inside the container.
  let mut in_command = false
  while i < tokens.length() {
    let t = tokens[i]
    if in_command {
      args.cnt_command.push(t)
      i += 1
      continue
    }
    if t == "--" {
      i += 1
      in_command = true
      continue
    }
    let is_positional = !t.has_prefix("-") || t == "-"
    if is_positional {
      match command {
        "run" | "exec" =>
          if args.services.length() == 0 {
            args.services.push(t)
            in_command = true
            i += 1
            continue
          }
        "port" =>
          if args.services.length() == 0 {
            args.services.push(t)
          } else {
            match try_int_str(t) {
              Some(p) => args.private_port = p
              None => raise fail("private_port must be a number")
            }
          }
        _ => args.services.push(t)
      }
      i += 1
      continue
    }
    // Long options.
    if t.has_prefix("--") {
      let (name, inline_value) = match split_long(t) {
        Some(p) => p
        None => (t, None)
      }
      let needs_value = long_needs_value(name)
      let value : String = if needs_value {
        match inline_value {
          Some(v) => v
          None => {
            if i + 1 >= tokens.length() {
              raise fail("\{name} requires a value")
            }
            i += 1
            tokens[i]
          }
        }
      } else {
        inline_value.unwrap_or("")
      }
      apply_long(command, args, name, value)
      i += 1
      continue
    }
    // Short options.
    let needs_value = short_needs_value(command, t)
    let value : String = if needs_value {
      if i + 1 >= tokens.length() {
        raise fail("\{t} requires a value")
      }
      i += 1
      tokens[i]
    } else {
      ""
    }
    apply_short(command, args, t, value)
    i += 1
  }
  args
}

///|
fn long_needs_value(name : String) -> Bool {
  [
    "--name", "--entrypoint", "--env", "--label", "--user", "--publish", "--volume",
    "--workdir", "--timeout", "--tail", "--since", "--until", "--format", "--signal",
    "--index", "--protocol", "--rmi", "--pull", "--build-arg", "--exit-code-from",
    "--no-attach", "--scale", "--wait-timeout", "--pod-args", "--in-pod",
  ].contains(name)
}

///|
fn short_needs_value(command : String, t : String) -> Bool {
  match t {
    "-e" | "-u" | "-w" | "-p" | "-v" | "-s" | "-i" => true
    "-t" =>
      command == "logs" ||
      command == "up" ||
      command == "down" ||
      command == "stop" ||
      command == "restart"
    "-l" => command == "run"
    "-f" => false
    _ => false
  }
}

///|
fn apply_long(
  command : String,
  args : CommandArgs,
  name : String,
  value : String,
) -> Unit raise Error {
  match name {
    "--detach" => args.detach = true
    "--no-deps" => args.no_deps = true
    "--no-build" => args.no_build = true
    "--build" => args.build = true
    "--force-recreate" => args.force_recreate = true
    "--no-recreate" => args.no_recreate = true
    "--no-start" => args.no_start = true
    "--volumes" => args.volumes = true
    "--remove-orphans" => args.remove_orphans = true
    "--rmi" => args.rmi = Some(if value.length() == 0 { "all" } else { value })
    "--timeout" =>
      match try_int_str(value) {
        Some(t) => args.timeout = Some(t)
        None => raise fail("--timeout must be a number")
      }
    "--follow" => args.follow = true
    "--tail" => args.tail = Some(value)
    "--since" => args.since = Some(value)
    "--until" => args.until = Some(value)
    "--timestamps" => args.timestamps = true
    "--names" => args.names = true
    "--no-color" => args.no_color = true
    "--no-log-prefix" => args.no_log_prefix = true
    "--quiet" => args.quiet = true
    "--format" => args.format = Some(value)
    "--short" => args.short = true
    "--signal" => args.signal = Some(value)
    "--all" => args.all = true
    "--index" =>
      match try_int_str(value) {
        Some(n) => args.index = n
        None => raise fail("--index must be a number")
      }
    "--protocol" => args.protocol = value
    "--no-cache" => args.no_cache = true
    "--pull" =>
      args.pull = Some(if value.length() == 0 { "newer" } else { value })
    "--pull-always" => args.pull = Some("always")
    "--build-arg" => args.build_arg.push(value)
    "--quiet-pull" => args.quiet_pull = true
    "--wait" => args.wait = true
    "--wait-timeout" =>
      match try_int_str(value) {
        Some(t) => args.wait_timeout = Some(t)
        None => raise fail("--wait-timeout must be a number")
      }
    "--name" => args.name = Some(value)
    "--entrypoint" => args.entrypoint = Some(value)
    "--env" => args.env.push(value)
    "--label" => args.build_arg.push("--label=" + value)
    "--user" => args.user = Some(value)
    "--workdir" => args.workdir = Some(value)
    "--rm" => args.rm = true
    "--publish" => args.publish.push(value)
    "--service-ports" => args.service_ports = true
    "--volume" => args.volume.push(value)
    "--privileged" => args.privileged = true
    "--force-local" => args.force_local = true
    "--services" => args.services_flag = true
    "--no-normalize" => args.no_normalize = true
    "--abort-on-container-exit" => args.abort_on_container_exit = true
    "--abort-on-container-failure" => args.abort_on_container_failure = true
    "--exit-code-from" => args.exit_code_from = Some(value)
    "--no-attach" => args.no_attach.push(value)
    "--scale" => args.scale = Some(value)
    "--renew-anon-volumes" => args.renew_anon_volumes = true
    "--no-hosts" => args.no_hosts = true
    _ => raise fail("unknown option for \{command}: \{name}")
  }
}

///|
fn apply_short(
  command : String,
  args : CommandArgs,
  t : String,
  value : String,
) -> Unit raise Error {
  match t {
    "-d" => args.detach = true
    "-f" =>
      match command {
        "version" | "ps" | "stats" | "ls" => args.format = Some(value)
        "logs" => args.follow = true
        _ => ()
      }
    "-q" => args.quiet = true
    "-t" =>
      match command {
        "logs" => args.timestamps = true
        _ =>
          match try_int_str(value) {
            Some(n) => args.timeout = Some(n)
            None => raise fail("-t must be a number")
          }
      }
    "-l" =>
      match command {
        "run" => args.build_arg.push("--label=" + value)
        _ => ()
      }
    "-n" => args.names = true
    "-i" =>
      match command {
        "stats" =>
          match try_int_str(value) {
            Some(n) => args.index = n
            None => ()
          }
        _ => ()
      }
    "-e" => args.env.push(value)
    "-u" => args.user = Some(value)
    "-w" => args.workdir = Some(value)
    "-p" => args.publish.push(value)
    "-v" =>
      match command {
        "down" => args.volumes = true
        _ => args.volume.push(value)
      }
    "-T" => args.no_tty = true
    "-V" => args.renew_anon_volumes = true
    "-a" =>
      match command {
        "kill" => args.all = true
        _ => ()
      }
    "-s" => args.signal = Some(value)
    _ => raise fail("unknown option for \{command}: \{t}")
  }
}

///|
/// The `podcomp --help` text.
pub fn print_help() -> Unit {
  println("podcomp — run Compose files with Podman")
  println("")
  println(
    "Usage: podcomp [global options] COMMAND [command options] [services...]",
  )
  println("")
  println("Global options:")
  println("  -f, --file FILE          compose file (repeatable, '-' for stdin)")
  println("  -p, --project-name NAME  project name (default: directory name)")
  println("      --profile NAME       enable a profile (repeatable)")
  println("      --env-file FILE      alternate environment file (repeatable)")
  println("      --podman-path PATH   podman binary (default: podman)")
  println("      --podman-args ARGS   extra global arguments for podman")
  println("      --dry-run            print the commands without running them")
  println("      --in-pod true|false|NAME")
  println("  -v, --version            show the version")
  println("  -h, --help               show this help")
  println("")
  println("Commands:")
  println("  up        create and start the stack")
  println("  down      stop and remove the stack")
  println("  ps        list containers")
  println("  logs      show container logs")
  println("  start     start services")
  println("  stop      stop services")
  println("  restart   restart services")
  println("  kill      kill services")
  println("  rm        remove stopped containers")
  println("  pull      pull service images")
  println("  build     build service images")
  println("  images    list service images")
  println("  exec      run a command in a running container")
  println("  run       run a one-off command in a new container")
  println("  port      print the host port for a published port")
  println("  pause     pause services")
  println("  unpause   unpause services")
  println("  config    print the merged compose file")
  println("  version   show the version")
}

///|
/// The subcommands `dispatch` knows how to run.
fn is_known_command(command : String) -> Bool {
  [
    "config", "up", "down", "ps", "logs", "start", "stop", "restart", "kill", "rm",
    "pull", "build", "images", "exec", "run", "port", "pause", "unpause",
  ].contains(command)
}

///|
/// The entry point the executable calls.
pub async fn main_cli() -> Unit raise Error {
  let argv = tail(@env.args())
  let (g, command, rest) = parse_global(argv)
  if command.length() == 0 || command == "help" {
    print_help()
    return
  }
  if command != "version" && !is_known_command(command) {
    eprintln("podcomp: unknown command: \{command}")
    print_help()
    @sys.exit(1)
  }
  let cargs = parse_command(command, rest)
  let podman = new_podman(g)
  if command == "version" {
    cmd_version(podman, cargs)
    return
  }
  // Every other command needs a project.
  let compose = load_compose(g)
  let code = dispatch(command, compose, podman, cargs)
  if code != 0 {
    @sys.exit(code)
  }
}

///|
/// Run one command against a loaded project.
async fn dispatch(
  command : String,
  compose : Compose,
  podman : Podman,
  args : CommandArgs,
) -> Int raise Error {
  match command {
    "config" => {
      cmd_config(compose, args)
      0
    }
    "up" => cmd_up(compose, podman, args)
    "down" => cmd_down(compose, podman, args)
    "ps" => cmd_ps(compose, podman, args)
    "logs" => cmd_logs(compose, podman, args)
    "start" => cmd_start(compose, podman, args)
    "stop" => cmd_stop(compose, podman, args)
    "restart" => cmd_restart(compose, podman, args)
    "kill" => cmd_kill(compose, podman, args)
    "rm" => cmd_rm(compose, podman, args)
    "pull" => cmd_pull(compose, podman, args)
    "build" => cmd_build(compose, podman, args)
    "images" => cmd_images(compose, podman, args)
    "exec" => cmd_exec(compose, podman, args)
    "run" => cmd_run(compose, podman, args)
    "port" => cmd_port(compose, podman, args)
    "pause" => cmd_pause_unpause(compose, podman, args, "pause")
    "unpause" => cmd_pause_unpause(compose, podman, args, "unpause")
    _ => {
      eprintln("podcomp: unknown command: \{command}")
      print_help()
      1
    }
  }
}
