fun AppState.onTabSelected(tab: AppTab) {
    val state = this
    state.ui.selectedTab = tab
}
