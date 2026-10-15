///|
/// The single error type the library raises. Every user-facing failure — a
/// malformed compose file, a missing env var, a podman command that exits
/// non-zero — arrives here as a message the CLI prints verbatim.
pub(all) suberror PodCompError {
  PodCompError(String)
}

///|
/// Raise a `PodCompError` with a formatted message.
pub fn fail(message : String) -> PodCompError {
  PodCompError(message)
}

///|
/// Render any MoonBit error as a one-line message. A `PodCompError` already
/// carries a human sentence, so it is unwrapped rather than printed with its
/// constructor name attached.
pub fn error_text(error : Error) -> String {
  match error {
    PodCompError(message) => message
    _ => error.to_string()
  }
}
