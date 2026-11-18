@Composable
fun Feed() {
    val state = LocalAppState.current
    val selected = state.ui.selectedTab == AppTab.People
    Button(onClick = { state.onTabSelected(AppTab.People) })
    Button(onClick = { state.ui.introPage = 2 }) // lint:allow view-state-mutation the pager owns the page index
}
