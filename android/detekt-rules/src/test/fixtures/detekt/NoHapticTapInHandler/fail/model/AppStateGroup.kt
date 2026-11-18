fun AppState.onGroupTapped(id: String) {
    Haptics.tap()
    ui.selectedGroup = id
}
