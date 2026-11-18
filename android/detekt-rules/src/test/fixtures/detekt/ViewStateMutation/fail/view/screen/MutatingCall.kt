@Composable
fun Feed() {
    val state = LocalAppState.current
    Button(onClick = { state.ui.pending.add("x") })
}
