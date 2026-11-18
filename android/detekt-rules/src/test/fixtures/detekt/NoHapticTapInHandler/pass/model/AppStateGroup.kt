fun AppState.onGroupTapped(id: String) {
    Haptics.press()
    ui.selectedGroup = id
}
