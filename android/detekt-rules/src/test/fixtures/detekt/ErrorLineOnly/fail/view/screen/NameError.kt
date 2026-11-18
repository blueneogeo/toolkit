@Composable
fun SignIn() {
    val state = LocalAppState.current
    Text(state.auth.error)
}
