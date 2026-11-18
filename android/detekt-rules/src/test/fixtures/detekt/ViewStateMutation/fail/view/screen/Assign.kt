@Composable
fun Feed() {
    val state = LocalAppState.current
    Button(onClick = { state.ui.selectedTab = AppTab.People })
}
