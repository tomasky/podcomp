///|
/// podcomp executable entry point. All real work lives in `kupas/podcomp`.

///|
async fn main {
  @podcomp.main_cli() catch {
    e => {
      eprintln("podcomp: \{@podcomp.error_text(e)}")
      @sys.exit(1)
    }
  }
}
