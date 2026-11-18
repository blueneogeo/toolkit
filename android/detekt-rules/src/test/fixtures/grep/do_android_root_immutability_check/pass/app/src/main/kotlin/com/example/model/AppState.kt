class AppState(
    val ui: UIState,
) {
    // a var on the root would be state
    val feed = FeedState()
}
