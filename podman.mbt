///|
/// Running `podman`. Every command funnels through here so `--dry-run`,
/// `--podman-args` and per-subcommand argument injection are honoured in one
/// place.

///|
/// A configured podman invocation.
pub struct Podman {
  path : String
  dry_run : Bool
  verbose : Bool
  global_args : Array[String]
  cmd_args : Map[String, Array[String]]
}

///|
pub fn new_podman(g : GlobalOptions) -> Podman {
  {
    path: g.podman_path,
    dry_run: g.dry_run,
    verbose: g.verbose,
    global_args: g.podman_args,
    cmd_args: g.podman_cmd_args,
  }
}

///|
/// The arguments after the podman binary: global options, the subcommand, then
/// the command's configured options and the caller's own.
pub fn podman_argv(
  podman : Podman,
  cmd : String,
  args : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  out.append(podman.global_args)
  if cmd.length() > 0 {
    out.push(cmd)
  }
  let lookup = if cmd == "create" { "run" } else { cmd }
  match podman.cmd_args.get(lookup) {
    Some(extra) => out.append(extra)
    None => ()
  }
  out.append(args)
  out
}

///|
/// Print the command that would run, for `--dry-run` and `--verbose`.
fn log_command(podman : Podman, argv : Array[String]) -> Unit {
  if podman.dry_run || podman.verbose {
    let line = podman.path + " " + argv.join(" ")
    println(line)
  }
}

///|
/// Run podman, inheriting the terminal. Returns the exit code.
pub async fn podman_run(
  podman : Podman,
  cmd : String,
  args : Array[String],
) -> Int32 {
  let argv = podman_argv(podman, cmd, args)
  log_command(podman, argv)
  if podman.dry_run {
    return 0
  }
  @process.run(
    podman.path,
    argv,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  ) catch {
    e => {
      eprintln("podcomp: failed to run \{podman.path}: \{error_text(e)}")
      1
    }
  }
}

///|
/// Run podman and capture its standard output. Raises when the exit code is
/// non-zero, with the captured standard error as the message.
pub async fn podman_output(
  podman : Podman,
  cmd : String,
  args : Array[String],
) -> String raise Error {
  let argv = podman_argv(podman, cmd, args)
  log_command(podman, argv)
  if podman.dry_run {
    return ""
  }
  let (code, stdout, stderr) = @process.collect_output(podman.path, argv) catch {
    e => raise fail("failed to run \{podman.path}: \{error_text(e)}")
  }
  if code != 0 {
    let message = (stderr.text() catch { _ => "" }).trim().to_owned()
    if message.length() > 0 {
      raise fail(message)
    }
    raise fail("\{podman.path} \{cmd} exited with status \{code}")
  }
  stdout.text() catch {
    _ => ""
  }
}

///|
/// Run podman and capture its standard output, returning `None` when it fails.
/// Used for existence probes (`podman inspect`, `podman network exists`).
pub async fn podman_try_output(
  podman : Podman,
  cmd : String,
  args : Array[String],
) -> String? {
  let argv = podman_argv(podman, cmd, args)
  log_command(podman, argv)
  if podman.dry_run {
    return None
  }
  let (code, stdout, _) = @process.collect_output(podman.path, argv) catch {
    _ => return None
  }
  if code != 0 {
    None
  } else {
    Some(stdout.text() catch { _ => "" })
  }
}

///|
/// The podman version string, or `None` when podman is unavailable.
pub async fn podman_version(podman : Podman) -> String? {
  if podman.dry_run {
    return None
  }
  let (code, stdout, _) = @process.collect_output(podman.path, ["--version"]) catch {
    _ => return None
  }
  if code != 0 {
    return None
  }
  let text = (stdout.text() catch { _ => "" }).trim().to_owned()
  let parts = text.split(" ").to_array()
  if parts.length() == 0 {
    None
  } else {
    Some(parts[parts.length() - 1].to_owned())
  }
}

///|
/// Whether podman is on the path and runnable.
pub async fn podman_available(podman : Podman) -> Bool {
  match podman_version(podman) {
    Some(_) => true
    None => false
  }
}

///|
/// Whether a dotted version string is at least `want` (`"5.6.0"`).
pub fn version_at_least(have : String, want : String) -> Bool {
  let h = have.split(".").to_array()
  let w = want.split(".").to_array()
  let n = if h.length() < w.length() { h.length() } else { w.length() }
  for i in 0..<n {
    let a = try_int_str(h[i].to_owned()).unwrap_or(0)
    let b = try_int_str(w[i].to_owned()).unwrap_or(0)
    if a > b {
      return true
    }
    if a < b {
      return false
    }
  }
  h.length() >= w.length()
}
