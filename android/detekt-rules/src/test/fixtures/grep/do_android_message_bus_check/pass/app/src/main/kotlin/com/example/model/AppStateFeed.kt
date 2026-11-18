class FeedState {
    var lastLoadedAt by mutableStateOf<Instant?>(null)
    var scrollVersion by mutableIntStateOf(0) // lint:allow message-bus the list keys its scroll on it
}
