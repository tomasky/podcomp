///|
/// podcomp executable entry point. All real work lives in `kupas/podcomp`.

///|
async fn main {
  @lib.main_cli() catch {
    e => {
      eprintln("podcomp: \{@lib.error_text(e)}")
      @sys.exit(1)
    }
  }
}
