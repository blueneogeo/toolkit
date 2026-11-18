@Composable
fun SignIn(message: String?) {
    val state = LocalAppState.current
    message?.let { ErrorLine(it) }
    Text(loc("auth.error_title"), color = Palette.feedInk)
    Text(state.auth.email)
}
